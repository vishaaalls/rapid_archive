//! File-to-file operations with flat memory use (native targets only).
//!
//! * gzip / zlib a file, or unpack one, streaming in 1 MiB pieces.
//! * Extract a zip file to a folder: the zip is memory-mapped (the OS pages
//!   it in on demand), entries are written in parallel, and big entries are
//!   inflated as a stream, so a 10 GB archive does not need 10 GB of RAM.
//! * Zip a folder: small files are read and deflated in parallel batches,
//!   big files are streamed through the multi-core deflater. zip64 records
//!   are added when the archive needs them.

use std::fs::{self, File};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};

use rayon::prelude::*;

use crate::codec::{self, Fmt};
use crate::stream::ParDeflate;
use crate::zipwrite::{self, ZipWriter};

/// Entries up to this size are inflated in memory with libdeflate (fastest);
/// bigger ones are streamed. Bounds memory at about threads x this.
const IN_MEMORY_ENTRY: u64 = 16 << 20;
/// Small-file batch limits when zipping a folder.
const BATCH_BYTES: u64 = 128 << 20;
const BATCH_FILES: usize = 4096;
const BUF: usize = 1 << 20;

fn err(path: &Path, e: impl std::fmt::Display) -> String {
    format!("{}: {e}", path.display())
}

// ---------------------------------------------------------------------------
// gzip / zlib files
// ---------------------------------------------------------------------------

pub fn compress_file(f: Fmt, src: &Path, dst: &Path, level: u32, parallel: bool) -> Result<(), String> {
    let mut r = BufReader::with_capacity(BUF, File::open(src).map_err(|e| err(src, e))?);
    let out = File::create(dst).map_err(|e| err(dst, e))?;
    let mut w = BufWriter::with_capacity(BUF, out);
    let mut buf = vec![0u8; BUF];
    let io = |e: io::Error| e.to_string();
    if parallel {
        let mut p = ParDeflate::new(f, level);
        let mut out = Vec::new();
        loop {
            let n = r.read(&mut buf).map_err(|e| err(src, e))?;
            p.push_into(&buf[..n], n == 0, &mut out);
            w.write_all(&out).map_err(|e| err(dst, e))?;
            out.clear();
            if n == 0 {
                break;
            }
        }
    } else {
        let lvl = flate2::Compression::new(level.min(9));
        match f {
            Fmt::Gzip => {
                let mut e = flate2::write::GzEncoder::new(&mut w, lvl);
                io::copy(&mut r, &mut e).map_err(io)?;
                e.try_finish().map_err(io)?;
            }
            Fmt::Zlib => {
                let mut e = flate2::write::ZlibEncoder::new(&mut w, lvl);
                io::copy(&mut r, &mut e).map_err(io)?;
                e.try_finish().map_err(io)?;
            }
            Fmt::Deflate => {
                let mut e = flate2::write::DeflateEncoder::new(&mut w, lvl);
                io::copy(&mut r, &mut e).map_err(io)?;
                e.try_finish().map_err(io)?;
            }
        }
    }
    w.flush().map_err(|e| err(dst, e))?;
    Ok(())
}

/// Returns the number of bytes written. CRC / Adler-32 are verified.
pub fn decompress_file(f: Fmt, src: &Path, dst: &Path) -> Result<u64, String> {
    let file = File::open(src).map_err(|e| err(src, e))?;
    let len = file.metadata().map_err(|e| err(src, e))?.len();
    let mut w = BufWriter::with_capacity(BUF, File::create(dst).map_err(|e| err(dst, e))?);

    // Fast path: a gzip file whose size trailer says the output is small
    // enough is unpacked in one libdeflate call.
    if f == Fmt::Gzip && (18..=(256 << 20)).contains(&len) {
        let map = unsafe { memmap2::Mmap::map(&file) }.map_err(|e| err(src, e))?;
        let isize = u32::from_le_bytes(map[map.len() - 4..].try_into().unwrap()) as u64;
        if isize <= (256 << 20) {
            let out = codec::decompress(f, &map).map_err(|e| err(src, e))?;
            w.write_all(&out).map_err(|e| err(dst, e))?;
            w.flush().map_err(|e| err(dst, e))?;
            return Ok(out.len() as u64);
        }
    }

    let r = BufReader::with_capacity(BUF, file);
    let n = match f {
        Fmt::Gzip => io::copy(&mut flate2::read::MultiGzDecoder::new(r), &mut w),
        Fmt::Zlib => io::copy(&mut flate2::read::ZlibDecoder::new(r), &mut w),
        Fmt::Deflate => io::copy(&mut flate2::read::DeflateDecoder::new(r), &mut w),
    }
    .map_err(|e| err(src, e))?;
    w.flush().map_err(|e| err(dst, e))?;
    Ok(n)
}

// ---------------------------------------------------------------------------
// Zip extract
// ---------------------------------------------------------------------------

/// Joins an entry name to `root`, refusing names that would escape it
/// ("zip slip"): absolute paths, drive letters and `..` components.
pub fn safe_join(root: &Path, name: &str) -> Result<PathBuf, String> {
    let name = name.replace('\\', "/");
    let rel = Path::new(&name);
    let mut out = root.to_path_buf();
    for c in rel.components() {
        match c {
            Component::Normal(p) => {
                let s = p.to_string_lossy();
                if s.contains(':') {
                    return Err(format!("{name}: unsafe entry name"));
                }
                out.push(p);
            }
            Component::CurDir => {}
            _ => return Err(format!("{name}: unsafe entry name (absolute path or ..)")),
        }
    }
    Ok(out)
}

struct Job<'a> {
    path: PathBuf,
    zip: &'a Path,
    start: u64,
    name: &'a str,
    data: &'a [u8],
    deflated: bool,
    size: u64,
    crc: u32,
}

fn write_entry(j: &Job) -> Result<(), String> {
    let mut w = BufWriter::with_capacity(BUF, File::create(&j.path).map_err(|e| err(&j.path, e))?);
    if j.size <= IN_MEMORY_ENTRY {
        if !j.deflated {
            if j.data.len() as u64 != j.size {
                return Err(format!("{}: stored size mismatch", j.name));
            }
            if crc32fast::hash(j.data) != j.crc {
                return Err(format!("{}: CRC mismatch", j.name));
            }
            w.write_all(j.data).map_err(|e| err(&j.path, e))?;
        } else {
            let mut buf = vec![0u8; j.size as usize];
            codec::inflate_exact(j.data, &mut buf).map_err(|e| format!("{}: {e}", j.name))?;
            if crc32fast::hash(&buf) != j.crc {
                return Err(format!("{}: CRC mismatch", j.name));
            }
            w.write_all(&buf).map_err(|e| err(&j.path, e))?;
        }
    } else {
        // Stream 1 MiB at a time, never more than the declared size. Read
        // through a file handle, not the memory map, so the pages of a
        // multi-GB entry do not stay mapped into the app's memory.
        let mut f = File::open(j.zip).map_err(|e| err(j.zip, e))?;
        f.seek(SeekFrom::Start(j.start)).map_err(|e| err(j.zip, e))?;
        let src = BufReader::with_capacity(BUF, f).take(j.data.len() as u64);
        let mut r: Box<dyn Read> = if j.deflated {
            Box::new(flate2::read::DeflateDecoder::new(src))
        } else {
            Box::new(src)
        };
        let mut h = crc32fast::Hasher::new();
        let mut buf = vec![0u8; BUF];
        let mut total = 0u64;
        loop {
            let n = r.read(&mut buf).map_err(|e| format!("{}: {e}", j.name))?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > j.size {
                return Err(format!("{}: more data than its declared size", j.name));
            }
            h.update(&buf[..n]);
            w.write_all(&buf[..n]).map_err(|e| err(&j.path, e))?;
        }
        if total != j.size {
            return Err(format!("{}: less data than its declared size", j.name));
        }
        if h.finalize() != j.crc {
            return Err(format!("{}: CRC mismatch", j.name));
        }
    }
    w.flush().map_err(|e| err(&j.path, e))
}

/// Extracts every entry of `zip` under `dir`. Returns the number of files.
pub fn extract_zip(zip: &Path, dir: &Path) -> Result<u64, String> {
    let file = File::open(zip).map_err(|e| err(zip, e))?;
    let map = unsafe { memmap2::Mmap::map(&file) }.map_err(|e| err(zip, e))?;
    let data: &[u8] = &map;
    let entries = crate::zipread::read(data)?;
    fs::create_dir_all(dir).map_err(|e| err(dir, e))?;

    let mut jobs = Vec::new();
    for e in &entries {
        let path = safe_join(dir, &e.name)?;
        if e.dir {
            fs::create_dir_all(&path).map_err(|x| err(&path, x))?;
            continue;
        }
        if e.encrypted {
            return Err(format!("{}: encrypted entries are not supported", e.name));
        }
        let deflated = match e.method {
            0 => false,
            8 => true,
            m => return Err(format!("{}: unsupported compression method {m}", e.name)),
        };
        let start = usize::try_from(e.data_start).map_err(|_| "archive too large")?;
        let csize = usize::try_from(e.csize).map_err(|_| "archive too large")?;
        let end = start.checked_add(csize).filter(|&x| x <= data.len()).ok_or(format!("{}: data runs past end of archive", e.name))?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|x| err(parent, x))?;
        }
        jobs.push(Job { path, zip, start: start as u64, name: &e.name, data: &data[start..end], deflated, size: e.size, crc: e.crc });
    }
    jobs.sort_unstable_by_key(|j| std::cmp::Reverse(j.size));
    jobs.par_iter().try_for_each(write_entry)?;
    Ok(jobs.len() as u64)
}

// ---------------------------------------------------------------------------
// Zip a folder
// ---------------------------------------------------------------------------

enum Item {
    Dir(String),
    File(String, PathBuf, u64),
}

fn walk(root: &Path, dir: &Path, prefix: &str, skip: Option<&Path>, out: &mut Vec<Item>) -> Result<(), String> {
    let mut list: Vec<_> = fs::read_dir(dir)
        .map_err(|e| err(dir, e))?
        .collect::<Result<_, _>>()
        .map_err(|e| err(dir, e))?;
    list.sort_by_key(|e| e.file_name());
    for e in list {
        let path = e.path();
        let name = format!("{prefix}{}", e.file_name().to_string_lossy());
        // Follow symlinks to files and folders, like `zip -r`.
        let meta = fs::metadata(&path).map_err(|x| err(&path, x))?;
        if meta.is_dir() {
            out.push(Item::Dir(format!("{name}/")));
            walk(root, &path, &format!("{name}/"), skip, out)?;
        } else if meta.is_file() {
            if skip.is_some_and(|s| fs::canonicalize(&path).ok().as_deref() == Some(s)) {
                continue; // the zip we are writing
            }
            out.push(Item::File(name, path, meta.len()));
        }
    }
    Ok(())
}

/// Zips the contents of `dir` (names relative to it) into `zip`. Returns
/// the number of files.
pub fn zip_dir(dir: &Path, zip: &Path, level: u32) -> Result<u64, String> {
    let level = level.min(9);
    let out = File::create(zip).map_err(|e| err(zip, e))?;
    let skip = fs::canonicalize(zip).ok();
    let mut items = Vec::new();
    walk(dir, dir, "", skip.as_deref(), &mut items)?;

    let mut z = ZipWriter::new(BufWriter::with_capacity(BUF, out));
    let io = |e: io::Error| err(zip, e);
    let mut batch: Vec<(String, PathBuf)> = Vec::new();
    let mut batch_bytes = 0u64;
    let mut files = 0u64;

    fn flush(z: &mut ZipWriter<BufWriter<File>>, batch: &mut Vec<(String, PathBuf)>, level: u32) -> Result<(), String> {
        let packed: Vec<(Vec<u8>, u16, u32, u64)> = batch
            .par_iter()
            .map(|(_, path)| {
                let data = fs::read(path).map_err(|e| err(path, e))?;
                let p = zipwrite::pack(&data, false, false, level);
                let (method, crc) = (p.method, p.crc);
                let payload = if method == 0 { data.clone() } else { p.payload.into_owned() };
                Ok((payload, method, crc, data.len() as u64))
            })
            .collect::<Result<_, String>>()?;
        for ((name, _), (payload, method, crc, size)) in batch.iter().zip(packed) {
            z.add_packed(name, false, method, crc, size, &payload).map_err(|e| e.to_string())?;
        }
        batch.clear();
        Ok(())
    }

    for item in items {
        match item {
            Item::Dir(name) => z.add_packed(&name, true, 0, 0, 0, &[]).map_err(io)?,
            Item::File(name, path, len) => {
                files += 1;
                if len > IN_MEMORY_ENTRY {
                    flush(&mut z, &mut batch, level)?;
                    batch_bytes = 0;
                    let mut r = BufReader::with_capacity(BUF, File::open(&path).map_err(|e| err(&path, e))?);
                    z.add_stream(&name, &mut r, len, level).map_err(|e| err(&path, e))?;
                } else {
                    batch_bytes += len;
                    batch.push((name, path));
                    if batch_bytes >= BATCH_BYTES || batch.len() >= BATCH_FILES {
                        flush(&mut z, &mut batch, level)?;
                        batch_bytes = 0;
                    }
                }
            }
        }
    }
    flush(&mut z, &mut batch, level)?;
    z.finish().map_err(io)?;
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("ra_test_{}_{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn safe_join_refuses_escapes() {
        let root = Path::new("/out");
        assert!(safe_join(root, "a/b.txt").is_ok());
        assert!(safe_join(root, "./a.txt").is_ok());
        for bad in ["../x", "a/../../x", "/etc/passwd", "a\\..\\..\\x", "C:/x"] {
            assert!(safe_join(root, bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn folder_round_trip_with_a_streamed_entry() {
        let src = tmp("src");
        fs::create_dir_all(src.join("sub/empty")).unwrap();
        fs::write(src.join("a.txt"), b"hello ".repeat(1000)).unwrap();
        fs::write(src.join("sub/b.bin"), (0..100_000u32).map(|i| (i % 7) as u8).collect::<Vec<_>>()).unwrap();
        // Bigger than IN_MEMORY_ENTRY: goes through add_stream and the
        // streaming extract path.
        let big: Vec<u8> = (0..(IN_MEMORY_ENTRY as usize + 3_000_000)).map(|i| ((i * 13) % 251) as u8).collect();
        fs::write(src.join("sub/big.bin"), &big).unwrap();

        let out = tmp("zip");
        let zip = out.join("t.zip");
        assert_eq!(zip_dir(&src, &zip, 6).unwrap(), 3);

        let dst = tmp("dst");
        assert_eq!(extract_zip(&zip, &dst).unwrap(), 3);
        assert_eq!(fs::read(dst.join("a.txt")).unwrap(), b"hello ".repeat(1000));
        assert_eq!(fs::read(dst.join("sub/big.bin")).unwrap(), big);
        assert!(dst.join("sub/empty").is_dir());

        // The zip crate agrees.
        let mut a = zip::ZipArchive::new(File::open(&zip).unwrap()).unwrap();
        let mut v = Vec::new();
        a.by_name("sub/big.bin").unwrap().read_to_end(&mut v).unwrap();
        assert_eq!(v, big);
        for p in [src, out, dst] {
            let _ = fs::remove_dir_all(p);
        }
    }

    #[test]
    fn gzip_file_round_trip() {
        let d = tmp("gz");
        let data: Vec<u8> = (0..5_000_000u32).map(|i| (i % 97) as u8).collect();
        fs::write(d.join("in"), &data).unwrap();
        for parallel in [false, true] {
            compress_file(Fmt::Gzip, &d.join("in"), &d.join("in.gz"), 6, parallel).unwrap();
            assert_eq!(decompress_file(Fmt::Gzip, &d.join("in.gz"), &d.join("out")).unwrap(), data.len() as u64);
            assert_eq!(fs::read(d.join("out")).unwrap(), data);
        }
        let _ = fs::remove_dir_all(d);
    }
}
