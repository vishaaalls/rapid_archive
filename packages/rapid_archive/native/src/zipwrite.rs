//! Zip writer with zip64 support.
//!
//! [`ZipWriter`] writes to any `Write + Seek` target: a `Cursor<Vec<u8>>` for
//! the in-memory API, or a file for `zip_directory`. Entries can be added
//! already compressed (the parallel path: [`write`] deflates every entry on
//! its own rayon task first) or streamed from a reader, which keeps memory
//! flat for files of any size.
//!
//! zip64 records are written only when they are needed: more than 65,535
//! entries, or a size or offset of 4 GiB or more. Small archives stay plain
//! zip 2.0, which every tool can read.

use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};

use rayon::prelude::*;

pub struct Entry<'a> {
    pub name: &'a str,
    pub data: &'a [u8],
    pub dir: bool,
    /// Store without compression (for already-compressed files like JPEGs).
    pub store: bool,
}

// 1980-01-01 00:00, the zip epoch. Deterministic output by default.
const DOS_TIME: u16 = 0;
const DOS_DATE: u16 = (1 << 5) | 1;
const MAX32: u64 = 0xffff_ffff;
/// A streamed entry whose size is at least this gets a zip64 local header
/// up front: its compressed size is unknown until it is written, and could
/// pass 4 GiB if the data does not compress.
#[cfg_attr(target_arch = "wasm32", allow(dead_code))]
const STREAM_ZIP64_AT: u64 = 0xf000_0000;

struct CdEntry {
    name: Vec<u8>,
    dir: bool,
    method: u16,
    crc: u32,
    csize: u64,
    size: u64,
    offset: u64,
}

pub struct ZipWriter<W: Write + Seek> {
    w: W,
    pos: u64,
    cd: Vec<CdEntry>,
    #[cfg(test)]
    pub force_zip64: bool,
}

impl<W: Write + Seek> ZipWriter<W> {
    pub fn new(w: W) -> Self {
        ZipWriter {
            w,
            pos: 0,
            cd: Vec::new(),
            #[cfg(test)]
            force_zip64: false,
        }
    }

    fn zip64(&self) -> bool {
        #[cfg(test)]
        if self.force_zip64 {
            return true;
        }
        false
    }

    fn put(&mut self, b: &[u8]) -> io::Result<()> {
        self.w.write_all(b)?;
        self.pos += b.len() as u64;
        Ok(())
    }

    /// Writes a local header. With `z64`, sizes go in a zip64 extra field.
    fn local_header(&mut self, name: &[u8], method: u16, crc: u32, csize: u64, size: u64, z64: bool) -> io::Result<()> {
        let mut h = Vec::with_capacity(30 + name.len() + 20);
        h.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        h.extend_from_slice(&(if z64 { 45u16 } else { 20 }).to_le_bytes());
        h.extend_from_slice(&0x0800u16.to_le_bytes()); // UTF-8 names
        h.extend_from_slice(&method.to_le_bytes());
        h.extend_from_slice(&DOS_TIME.to_le_bytes());
        h.extend_from_slice(&DOS_DATE.to_le_bytes());
        h.extend_from_slice(&crc.to_le_bytes());
        let (c32, s32) = if z64 { (MAX32 as u32, MAX32 as u32) } else { (csize as u32, size as u32) };
        h.extend_from_slice(&c32.to_le_bytes());
        h.extend_from_slice(&s32.to_le_bytes());
        h.extend_from_slice(&(name.len() as u16).to_le_bytes());
        h.extend_from_slice(&(if z64 { 20u16 } else { 0 }).to_le_bytes());
        h.extend_from_slice(name);
        if z64 {
            h.extend_from_slice(&1u16.to_le_bytes());
            h.extend_from_slice(&16u16.to_le_bytes());
            h.extend_from_slice(&size.to_le_bytes());
            h.extend_from_slice(&csize.to_le_bytes());
        }
        self.put(&h)
    }

    fn check_name(name: &str) -> io::Result<()> {
        if name.len() > u16::MAX as usize {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "zip entry name longer than 65,535 bytes"));
        }
        Ok(())
    }

    /// Adds an entry whose payload is already compressed (`method` 8) or
    /// stored (`method` 0). `size` is the uncompressed size.
    pub fn add_packed(&mut self, name: &str, dir: bool, method: u16, crc: u32, size: u64, payload: &[u8]) -> io::Result<()> {
        Self::check_name(name)?;
        let offset = self.pos;
        let csize = payload.len() as u64;
        let z64 = self.zip64() || size >= MAX32 || csize >= MAX32;
        self.local_header(name.as_bytes(), method, crc, csize, size, z64)?;
        self.put(payload)?;
        self.cd.push(CdEntry { name: name.as_bytes().to_vec(), dir, method, crc, csize, size, offset });
        Ok(())
    }

    /// Streams an entry from `r`, deflating it (or storing it when `level`
    /// is 0) with constant memory, then seeks back to fill in its CRC and
    /// sizes. `size_hint` decides whether the local header reserves zip64
    /// fields.
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    pub fn add_stream(&mut self, name: &str, r: &mut dyn Read, size_hint: u64, level: u32) -> io::Result<()> {
        Self::check_name(name)?;
        let offset = self.pos;
        let method = if level == 0 { 0 } else { 8 };
        let z64 = self.zip64() || size_hint >= STREAM_ZIP64_AT;
        self.local_header(name.as_bytes(), method, 0, 0, 0, z64)?;
        let start = self.pos;

        let mut crc = crc32fast::Hasher::new();
        let mut size = 0u64;
        let mut buf = vec![0u8; 1 << 20];
        if method == 0 {
            loop {
                let n = r.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                crc.update(&buf[..n]);
                size += n as u64;
                self.put(&buf[..n])?;
            }
        } else {
            let mut deflater = crate::stream::ParDeflate::new(crate::codec::Fmt::Deflate, level);
            let mut out = Vec::new();
            loop {
                let n = r.read(&mut buf)?;
                crc.update(&buf[..n]);
                size += n as u64;
                deflater.push_into(&buf[..n], n == 0, &mut out);
                self.put(&out)?;
                out.clear();
                if n == 0 {
                    break;
                }
            }
        }
        let csize = self.pos - start;
        let crc = crc.finalize();
        if !z64 && (size >= MAX32 || csize >= MAX32) {
            return Err(io::Error::other(format!("{name}: grew past 4 GiB while it was being zipped")));
        }

        // Patch CRC and sizes into the local header.
        let end = self.pos;
        self.w.seek(SeekFrom::Start(offset + 14))?;
        self.w.write_all(&crc.to_le_bytes())?;
        if z64 {
            let extra = offset + 30 + name.len() as u64 + 4;
            self.w.seek(SeekFrom::Start(extra))?;
            self.w.write_all(&size.to_le_bytes())?;
            self.w.write_all(&csize.to_le_bytes())?;
        } else {
            self.w.write_all(&(csize as u32).to_le_bytes())?;
            self.w.write_all(&(size as u32).to_le_bytes())?;
        }
        self.w.seek(SeekFrom::Start(end))?;

        self.cd.push(CdEntry { name: name.as_bytes().to_vec(), dir: false, method, crc, csize, size, offset });
        Ok(())
    }

    /// Writes the central directory and end records, and returns the target.
    pub fn finish(mut self) -> io::Result<W> {
        let cd_start = self.pos;
        let cd = std::mem::take(&mut self.cd);
        let force = self.zip64();
        for e in &cd {
            let mut extra = Vec::new();
            let size32 = if force || e.size >= MAX32 {
                extra.extend_from_slice(&e.size.to_le_bytes());
                MAX32
            } else {
                e.size
            };
            let csize32 = if force || e.csize >= MAX32 {
                extra.extend_from_slice(&e.csize.to_le_bytes());
                MAX32
            } else {
                e.csize
            };
            let off32 = if force || e.offset >= MAX32 {
                extra.extend_from_slice(&e.offset.to_le_bytes());
                MAX32
            } else {
                e.offset
            };
            let z64 = !extra.is_empty();
            let ver: u16 = if z64 { 45 } else { 20 };
            let ext_attr: u32 = if e.dir { (0o040755 << 16) | 0x10 } else { 0o100644 << 16 };
            let mut h = Vec::with_capacity(46 + e.name.len() + 28);
            h.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            h.extend_from_slice(&((3u16 << 8) | ver).to_le_bytes()); // made by: unix
            h.extend_from_slice(&ver.to_le_bytes());
            h.extend_from_slice(&0x0800u16.to_le_bytes());
            h.extend_from_slice(&e.method.to_le_bytes());
            h.extend_from_slice(&DOS_TIME.to_le_bytes());
            h.extend_from_slice(&DOS_DATE.to_le_bytes());
            h.extend_from_slice(&e.crc.to_le_bytes());
            h.extend_from_slice(&(csize32 as u32).to_le_bytes());
            h.extend_from_slice(&(size32 as u32).to_le_bytes());
            h.extend_from_slice(&(e.name.len() as u16).to_le_bytes());
            h.extend_from_slice(&(if z64 { extra.len() as u16 + 4 } else { 0 }).to_le_bytes());
            h.extend_from_slice(&0u16.to_le_bytes()); // comment
            h.extend_from_slice(&0u16.to_le_bytes()); // disk
            h.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
            h.extend_from_slice(&ext_attr.to_le_bytes());
            h.extend_from_slice(&(off32 as u32).to_le_bytes());
            h.extend_from_slice(&e.name);
            if z64 {
                h.extend_from_slice(&1u16.to_le_bytes());
                h.extend_from_slice(&(extra.len() as u16).to_le_bytes());
                h.extend_from_slice(&extra);
            }
            self.put(&h)?;
        }
        let cd_len = self.pos - cd_start;
        let count = cd.len() as u64;

        let need64 = force || count >= 0xffff || cd_len >= MAX32 || cd_start >= MAX32;
        if need64 {
            let eocd64 = self.pos;
            let mut z = Vec::with_capacity(76);
            z.extend_from_slice(&0x0606_4b50u32.to_le_bytes());
            z.extend_from_slice(&44u64.to_le_bytes()); // size of the rest of this record
            z.extend_from_slice(&((3u16 << 8) | 45).to_le_bytes());
            z.extend_from_slice(&45u16.to_le_bytes());
            z.extend_from_slice(&0u32.to_le_bytes());
            z.extend_from_slice(&0u32.to_le_bytes());
            z.extend_from_slice(&count.to_le_bytes());
            z.extend_from_slice(&count.to_le_bytes());
            z.extend_from_slice(&cd_len.to_le_bytes());
            z.extend_from_slice(&cd_start.to_le_bytes());
            // Locator.
            z.extend_from_slice(&0x0706_4b50u32.to_le_bytes());
            z.extend_from_slice(&0u32.to_le_bytes());
            z.extend_from_slice(&eocd64.to_le_bytes());
            z.extend_from_slice(&1u32.to_le_bytes());
            self.put(&z)?;
        }
        let mut e = Vec::with_capacity(22);
        let n16 = if need64 { 0xffff } else { count as u16 };
        e.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        e.extend_from_slice(&0u16.to_le_bytes());
        e.extend_from_slice(&0u16.to_le_bytes());
        e.extend_from_slice(&n16.to_le_bytes());
        e.extend_from_slice(&n16.to_le_bytes());
        e.extend_from_slice(&(if need64 { MAX32 as u32 } else { cd_len as u32 }).to_le_bytes());
        e.extend_from_slice(&(if need64 { MAX32 as u32 } else { cd_start as u32 }).to_le_bytes());
        e.extend_from_slice(&0u16.to_le_bytes());
        self.put(&e)?;
        self.w.flush()?;
        Ok(self.w)
    }
}

/// A compressed (or stored) entry, ready to be written.
pub struct Packed<'a> {
    pub method: u16,
    pub crc: u32,
    pub payload: std::borrow::Cow<'a, [u8]>,
}

/// Compresses one entry; keeps deflate only if it saves space.
pub fn pack(data: &[u8], dir: bool, store: bool, lvl: u32) -> Packed<'_> {
    if dir || data.is_empty() {
        return Packed { method: 0, crc: 0, payload: std::borrow::Cow::Borrowed(&[]) };
    }
    let crc = crc32fast::hash(data);
    if !store && lvl > 0 {
        let c = crate::codec::compress(crate::codec::Fmt::Deflate, data, lvl);
        if c.len() < data.len() {
            return Packed { method: 8, crc, payload: std::borrow::Cow::Owned(c) };
        }
    }
    Packed { method: 0, crc, payload: std::borrow::Cow::Borrowed(data) }
}

/// In-memory zip: every entry is deflated on its own core, then written in
/// order.
pub fn write(entries: &[Entry<'_>], lvl: u32) -> Result<Vec<u8>, String> {
    let packed: Vec<Packed> = entries.par_iter().map(|e| pack(e.data, e.dir, e.store, lvl)).collect();
    let payload_total: usize = packed.iter().map(|p| p.payload.len()).sum();
    let names_total: usize = entries.iter().map(|e| e.name.len()).sum();
    let cap = payload_total + names_total * 2 + entries.len() * 100 + 100;
    let mut z = ZipWriter::new(Cursor::new(Vec::with_capacity(cap)));
    for (e, p) in entries.iter().zip(&packed) {
        let size = if e.dir { 0 } else { e.data.len() as u64 };
        z.add_packed(e.name, e.dir, p.method, p.crc, size, &p.payload).map_err(|e| e.to_string())?;
    }
    Ok(z.finish().map_err(|e| e.to_string())?.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forced_zip64_reads_back() {
        let mut z = ZipWriter::new(Cursor::new(Vec::new()));
        z.force_zip64 = true;
        let data = b"hello hello hello hello".repeat(100);
        let p = pack(&data, false, false, 6);
        z.add_packed("a.txt", false, p.method, p.crc, data.len() as u64, &p.payload).unwrap();
        let mut r: &[u8] = &data;
        z.add_stream("b.txt", &mut r, data.len() as u64, 6).unwrap();
        let out = z.finish().unwrap().into_inner();
        // Our reader.
        let entries = crate::zipread::read(&out).unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().all(|e| e.size == data.len() as u64));
        // The zip crate.
        let mut a = zip::ZipArchive::new(Cursor::new(&out)).unwrap();
        for i in 0..2 {
            let mut f = a.by_index(i).unwrap();
            let mut v = Vec::new();
            f.read_to_end(&mut v).unwrap();
            assert_eq!(v, data);
        }
    }

    #[test]
    fn more_than_65535_entries() {
        let names: Vec<String> = (0..70_000).map(|i| format!("f{i}")).collect();
        let entries: Vec<Entry> = names.iter().map(|n| Entry { name: n, data: b"x", dir: false, store: false }).collect();
        let out = write(&entries, 6).unwrap();
        assert_eq!(crate::zipread::read(&out).unwrap().len(), 70_000);
        let a = zip::ZipArchive::new(Cursor::new(&out)).unwrap();
        assert_eq!(a.len(), 70_000);
    }
}
