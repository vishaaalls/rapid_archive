//! rapid_archive: Rust core for fast gzip / zlib / zip in Dart and Flutter.
//!
//! The C ABI is deliberately small and allocation-friendly:
//! * Inputs are borrowed `(ptr, len)` pairs, so Dart can pass `Uint8List.address`
//!   from a leaf call with no copy.
//! * Outputs are single heap buffers owned by Rust. Dart wraps them with
//!   `Pointer.asTypedList(len, finalizer: ra_free)`, so results are zero-copy too.
//! * Every buffer we hand out carries an 8-byte length header in front of the
//!   pointer, so `ra_free(ptr)` needs only the pointer (that's the shape Dart's
//!   native finalizers require).

use std::cell::RefCell;
use std::ffi::c_char;
use rayon::prelude::*;

mod codec;
mod zipwrite;

use codec::Fmt;

// ---------------------------------------------------------------------------
// Owned buffers
// ---------------------------------------------------------------------------

const HDR: usize = 8;

/// Allocates `len` bytes (plus header) and returns a pointer to the payload.
/// The payload is zero-initialised.
fn alloc_buf(len: usize) -> *mut u8 {
    let mut b = vec![0u8; HDR + len].into_boxed_slice();
    b[..HDR].copy_from_slice(&(len as u64).to_le_bytes());
    let p = Box::into_raw(b) as *mut u8;
    unsafe { p.add(HDR) }
}

/// Copies bytes into an owned buffer. One memcpy; cheap next to compression.
fn vec_to_buf(v: &[u8]) -> *mut u8 {
    let p = alloc_buf(v.len());
    unsafe { std::ptr::copy_nonoverlapping(v.as_ptr(), p, v.len()) };
    p
}

/// Frees a buffer returned by any `ra_*` function. Null is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_free(p: *mut u8) {
    if p.is_null() {
        return;
    }
    unsafe {
        let base = p.sub(HDR);
        let mut hdr = [0u8; HDR];
        std::ptr::copy_nonoverlapping(base, hdr.as_mut_ptr(), HDR);
        let len = u64::from_le_bytes(hdr) as usize;
        let slice = std::ptr::slice_from_raw_parts_mut(base, HDR + len);
        drop(Box::from_raw(slice));
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERR: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

fn set_err(msg: impl std::fmt::Display) -> i32 {
    LAST_ERR.with(|e| {
        let mut e = e.borrow_mut();
        e.clear();
        e.extend_from_slice(msg.to_string().as_bytes());
        e.push(0);
    });
    -1
}

/// Returns the last error on this thread as a NUL-terminated UTF-8 string
/// (valid until the next failing call on the same thread).
#[unsafe(no_mangle)]
pub extern "C" fn ra_last_error() -> *const c_char {
    LAST_ERR.with(|e| {
        let e = e.borrow();
        if e.is_empty() { c"".as_ptr() } else { e.as_ptr() as *const c_char }
    })
}

unsafe fn slice<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(p, len) } }
}

fn level(l: i32) -> u32 {
    if l < 0 { 6 } else { l.clamp(0, 9) as u32 }
}

fn emit(out: *mut *mut u8, out_len: *mut usize, v: Vec<u8>) -> i32 {
    unsafe {
        *out_len = v.len();
        *out = vec_to_buf(&v);
    }
    0
}

// ---------------------------------------------------------------------------
// gzip / zlib / raw deflate
// ---------------------------------------------------------------------------

fn fmt(f: i32) -> Option<Fmt> {
    match f {
        0 => Some(Fmt::Gzip),
        1 => Some(Fmt::Zlib),
        2 => Some(Fmt::Deflate),
        _ => None,
    }
}

/// Compresses `data` as gzip (0), zlib (1) or raw deflate (2).
/// `level` is 0..=9, or -1 for the default (6). `parallel` != 0 uses every
/// core (inputs of 2 MiB or more) at a ~2-5% size cost.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_compress(
    format: i32,
    data: *const u8,
    len: usize,
    level: i32,
    parallel: i32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(f) = fmt(format) else { return set_err("unknown format") };
    let data = unsafe { slice(data, len) };
    let lvl = if level < 0 { 6 } else { level as u32 };
    let v = if parallel != 0 {
        codec::compress_parallel(f, data, lvl)
    } else {
        codec::compress(f, data, lvl)
    };
    emit(out, out_len, v)
}

/// Decompresses gzip (0), zlib (1) or raw deflate (2).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_decompress(
    format: i32,
    data: *const u8,
    len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(f) = fmt(format) else { return set_err("unknown format") };
    match codec::decompress(f, unsafe { slice(data, len) }) {
        Ok(v) => emit(out, out_len, v),
        Err(e) => set_err(e),
    }
}

// ---------------------------------------------------------------------------
// zip
// ---------------------------------------------------------------------------

/// Builds a zip archive. Entries are passed as one concatenated byte blob plus
/// a table of `u64`s, five per entry:
/// `[name_off, name_len, data_off, data_len, flags]` (offsets into `names` and
/// `blob`; flag bit 0 = directory, bit 1 = store without compression).
/// Entries are compressed in parallel on all cores.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_zip_encode(
    names: *const u8,
    names_len: usize,
    blob: *const u8,
    blob_len: usize,
    table: *const u64,
    count: usize,
    level_: i32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let names = unsafe { slice(names, names_len) };
    let blob = unsafe { slice(blob, blob_len) };
    let table = if count == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(table, count * 5) }
    };
    let mut entries = Vec::with_capacity(count);
    for row in table.chunks_exact(5) {
        let [no, nl, d_off, dl, flags] = [row[0], row[1], row[2], row[3], row[4]].map(|x| x as usize);
        let (Some(name), Some(data)) = (names.get(no..no + nl), blob.get(d_off..d_off + dl)) else {
            return set_err("zip entry table points outside its buffers");
        };
        let Ok(name) = std::str::from_utf8(name) else {
            return set_err("zip entry name is not valid UTF-8");
        };
        entries.push(zipwrite::Entry {
            name,
            data,
            dir: flags & 1 != 0,
            store: flags & 2 != 0,
        });
    }
    match zipwrite::write(&entries, level(level_)) {
        Ok(v) => emit(out, out_len, v),
        Err(e) => set_err(e),
    }
}

/// Result of `ra_zip_decode`. All three buffers are owned by the caller and
/// must be released with `ra_free` (Dart attaches finalizers to them).
#[repr(C)]
pub struct RaZip {
    pub count: usize,
    /// Every entry's bytes, back to back.
    pub data: *mut u8,
    pub data_len: usize,
    /// Every entry's UTF-8 name, back to back.
    pub names: *mut u8,
    pub names_len: usize,
    /// Five `u64`s per entry: `[name_off, name_len, data_off, data_len, flags]`
    /// (flag bit 0 = directory).
    pub table: *mut u64,
}

/// Opens a zip archive and extracts every entry, in parallel, into one
/// contiguous buffer. CRCs are verified.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_zip_decode(data: *const u8, len: usize, out: *mut RaZip) -> i32 {
    match zip_decode(unsafe { slice(data, len) }) {
        Ok(z) => {
            unsafe { *out = z };
            0
        }
        Err(e) => set_err(e),
    }
}

struct Slot {
    start: usize,
    csize: usize,
    deflated: bool,
    crc: u32,
}

fn zip_decode(data: &[u8]) -> Result<RaZip, String> {
    let mut archive =
        zip::ZipArchive::new(std::io::Cursor::new(data)).map_err(|e| e.to_string())?;
    let n = archive.len();

    // Pass 1: read the directory and local headers (no decompression).
    let mut names = Vec::new();
    let mut table = Vec::with_capacity(n * 5);
    let mut total: u64 = 0;
    let mut slots = Vec::with_capacity(n);
    let mut sizes = Vec::with_capacity(n);
    for i in 0..n {
        let f = archive.by_index_raw(i).map_err(|e| e.to_string())?;
        let name = f.name().map_err(|e| e.to_string())?.into_owned();
        let dir = f.is_dir();
        let size = if dir { 0 } else { f.size() };
        if !dir && size > 0 {
            if f.encrypted() {
                return Err(format!("{name}: encrypted entries are not supported"));
            }
            let deflated = match f.compression() {
                zip::CompressionMethod::Stored => false,
                m if m == zip::CompressionMethod::DEFLATE => true,
                m => return Err(format!("{name}: unsupported compression {m:?}")),
            };
            let start = f.data_start().ok_or("missing data offset")? as usize;
            let csize = f.compressed_size() as usize;
            if start.checked_add(csize).is_none_or(|end| end > data.len()) {
                return Err(format!("{name}: data runs past end of archive"));
            }
            slots.push(Some(Slot { start, csize, deflated, crc: f.crc32() }));
        } else {
            slots.push(None);
        }
        table.extend_from_slice(&[
            names.len() as u64,
            name.len() as u64,
            total,
            size,
            dir as u64,
        ]);
        names.extend_from_slice(name.as_bytes());
        sizes.push(size as usize);
        total = total.checked_add(size).ok_or("archive too large")?;
    }
    // Refuse zip bombs: more than 2 GiB, or more than 1024x the input.
    if total > codec::MAX_OUT as u64
        || total > (data.len() as u64).saturating_mul(1024).max(1 << 20)
    {
        return Err(format!("archive claims {total} uncompressed bytes; refusing"));
    }

    // Pass 2: inflate every entry straight into its place, in parallel.
    let total = total as usize;
    let out = alloc_buf(total);
    let out_slice: &mut [u8] = unsafe { std::slice::from_raw_parts_mut(out, total) };
    let mut work: Vec<(usize, &Slot, &mut [u8])> = Vec::with_capacity(n);
    let mut rest = out_slice;
    for (i, s) in sizes.iter().enumerate() {
        let (a, b) = rest.split_at_mut(*s);
        rest = b;
        if let Some(slot) = &slots[i] {
            work.push((i, slot, a));
        }
    }
    // Biggest entries first so one huge file doesn't start last.
    work.sort_unstable_by_key(|w| std::cmp::Reverse(w.2.len()));
    let result: Result<(), String> = work.into_par_iter().try_for_each(|(i, s, dst)| {
        let src = &data[s.start..s.start + s.csize];
        if s.deflated {
            codec::inflate_exact(src, dst).map_err(|e| format!("entry {i}: {e}"))?;
        } else if src.len() == dst.len() {
            dst.copy_from_slice(src);
        } else {
            return Err(format!("entry {i}: stored size mismatch"));
        }
        if crc32fast::hash(dst) != s.crc {
            return Err(format!("entry {i}: CRC mismatch"));
        }
        Ok(())
    });
    if let Err(e) = result {
        unsafe { ra_free(out) };
        return Err(e);
    }

    let names_buf = vec_to_buf(&names);
    let table_bytes: Vec<u8> = table.iter().flat_map(|x| x.to_le_bytes()).collect();
    let table_buf = vec_to_buf(&table_bytes) as *mut u64;
    Ok(RaZip {
        count: n,
        data: out,
        data_len: total,
        names: names_buf,
        names_len: names.len(),
        table: table_buf,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    fn sample(n: usize) -> Vec<u8> {
        (0..n).map(|i| b"the quick brown fox jumps over the lazy dog "[i % 44]).collect()
    }

    #[test]
    fn roundtrip_streams() {
        let d = sample(100_000);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            let c = codec::compress(f, &d, 6);
            assert!(c.len() < d.len() / 10);
            assert_eq!(codec::decompress(f, &c).unwrap(), d);
        }
    }

    #[test]
    fn zip_roundtrip_and_zip_crate_can_read_ours() {
        let a = sample(10_000);
        let b: Vec<u8> = (0..3000u32).map(|i| (i * 7919 % 251) as u8).collect();
        let entries = vec![
            zipwrite::Entry { name: "dir/", data: &[], dir: true, store: false },
            zipwrite::Entry { name: "dir/a.txt", data: &a, dir: false, store: false },
            zipwrite::Entry { name: "b.bin", data: &b, dir: false, store: true },
            zipwrite::Entry { name: "empty", data: &[], dir: false, store: false },
        ];
        let z = zipwrite::write(&entries, 6).unwrap();

        // Independent reader.
        let mut ar = zip::ZipArchive::new(std::io::Cursor::new(&z[..])).unwrap();
        assert_eq!(ar.len(), 4);
        let mut s = Vec::new();
        ar.by_name("dir/a.txt").unwrap().read_to_end(&mut s).unwrap();
        assert_eq!(s, a);

        // Our reader.
        let r = zip_decode(&z).unwrap();
        assert_eq!(r.count, 4);
        let table = unsafe { std::slice::from_raw_parts(r.table, 20) };
        let data = unsafe { std::slice::from_raw_parts(r.data, r.data_len) };
        let (off, len) = (table[5 + 2] as usize, table[5 + 3] as usize);
        assert_eq!(&data[off..off + len], &a[..]);
        assert_eq!(table[4], 1); // dir flag
        unsafe {
            ra_free(r.data);
            ra_free(r.names);
            ra_free(r.table as *mut u8);
        }
    }

    #[test]
    fn corrupt_zip_is_an_error() {
        let a = sample(10_000);
        let mut z = zipwrite::write(
            &[zipwrite::Entry { name: "a", data: &a, dir: false, store: false }],
            6,
        )
        .unwrap();
        z[40] ^= 0xff; // flip a byte inside the compressed data
        assert!(zip_decode(&z).is_err());
    }
}
