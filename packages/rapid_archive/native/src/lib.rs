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
use std::collections::HashMap;
use std::sync::Mutex;
use std::ffi::c_char;
use rayon::prelude::*;

mod codec;
#[cfg(not(target_arch = "wasm32"))]
mod files;
mod stream;
mod zipread;
mod zipwrite;

use codec::Fmt;

// ---------------------------------------------------------------------------
// Owned buffers
// ---------------------------------------------------------------------------
//
// Results are Rust `Vec`s handed to Dart as-is (no copy). Dart's native
// finalizer only gives us back the pointer, so we remember each live
// buffer's length and capacity here and rebuild the Vec in `ra_free`.

static LIVE: Mutex<Option<HashMap<usize, (usize, usize, bool)>>> = Mutex::new(None);

/// Hands a Vec to the caller without copying it.
fn give(v: Vec<u8>) -> (*mut u8, usize) {
    let mut v = std::mem::ManuallyDrop::new(v);
    let (p, len, cap) = (v.as_mut_ptr(), v.len(), v.capacity());
    LIVE.lock().unwrap().get_or_insert_with(HashMap::new).insert(p as usize, (len, cap, false));
    (p, len)
}

/// Same as [`give`] for a `u64` table (keeps 8-byte alignment).
fn give_u64(v: Vec<u64>) -> *mut u64 {
    let mut v = std::mem::ManuallyDrop::new(v);
    let (p, len, cap) = (v.as_mut_ptr(), v.len(), v.capacity());
    LIVE.lock().unwrap().get_or_insert_with(HashMap::new).insert(p as usize, (len, cap, true));
    p
}

/// Allocates `len` bytes for the caller to fill with input (used by the
/// WebAssembly build, where JS must copy data into wasm memory first).
/// Release with `ra_input_free(ptr, len)`.
#[unsafe(no_mangle)]
pub extern "C" fn ra_input_alloc(len: usize) -> *mut u8 {
    let mut v = std::mem::ManuallyDrop::new(Vec::<u8>::with_capacity(len.max(1)));
    v.as_mut_ptr()
}

/// Frees a buffer from `ra_input_alloc`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_input_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(unsafe { Vec::from_raw_parts(p, 0, len.max(1)) });
    }
}

/// Frees a buffer returned by any `ra_*` function. Null is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_free(p: *mut u8) {
    if p.is_null() {
        return;
    }
    let entry = LIVE.lock().unwrap().as_mut().and_then(|m| m.remove(&(p as usize)));
    match entry {
        Some((len, cap, false)) => drop(unsafe { Vec::from_raw_parts(p, len, cap) }),
        Some((len, cap, true)) => drop(unsafe { Vec::from_raw_parts(p as *mut u64, len, cap) }),
        None => {}
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
    let (p, len) = give(v);
    unsafe {
        *out = p;
        *out_len = len;
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
    // read_unaligned: on WebAssembly the table arrives in a byte buffer.
    let table: Vec<u64> = (0..count * 5)
        .map(|i| unsafe { std::ptr::read_unaligned(table.add(i)) })
        .collect();
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
    let entries = zipread::read(data)?;
    let n = entries.len();

    // Pass 1: validate entries and lay out the output buffer.
    let mut names = Vec::new();
    let mut table = Vec::with_capacity(n * 5);
    let mut total: u64 = 0;
    let mut slots = Vec::with_capacity(n);
    let mut sizes = Vec::with_capacity(n);
    for e in &entries {
        let size = if e.dir { 0 } else { e.size };
        if !e.dir && size > 0 {
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
            if start.checked_add(csize).is_none_or(|end| end > data.len()) {
                return Err(format!("{}: data runs past end of archive", e.name));
            }
            slots.push(Some(Slot { start, csize, deflated, crc: e.crc }));
        } else {
            slots.push(None);
        }
        table.extend_from_slice(&[
            names.len() as u64,
            e.name.len() as u64,
            total,
            size,
            e.dir as u64,
        ]);
        names.extend_from_slice(e.name.as_bytes());
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
    // Zeroed allocation: large ones come straight from the OS as zero pages.
    let mut out_vec = vec![0u8; total];
    let out_slice: &mut [u8] = &mut out_vec;
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
    result?;

    let (out, _) = give(out_vec);
    let names_len = names.len();
    let (names_buf, _) = give(names);
    let table_buf = give_u64(table);
    Ok(RaZip {
        count: n,
        data: out,
        data_len: total,
        names: names_buf,
        names_len,
        table: table_buf,
    })
}

// ---------------------------------------------------------------------------
// Streaming (constant memory)
// ---------------------------------------------------------------------------

/// Opens a streaming encoder (`decode` = 0) or decoder (`decode` != 0) for
/// gzip (0), zlib (1) or raw deflate (2). `parallel` != 0 makes a multi-core
/// encoder. Returns null on a bad format. Release with `ra_stream_free`.
#[unsafe(no_mangle)]
pub extern "C" fn ra_stream_new(decode: i32, format: i32, level_: i32, parallel: i32) -> *mut stream::Codec {
    let Some(f) = fmt(format) else {
        set_err("unknown format");
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(stream::Codec::new(decode != 0, f, level(level_), parallel != 0)))
}

/// Feeds `len` bytes to a stream and returns the output that is ready (it can
/// be empty). With `finish` != 0 the stream is completed; a truncated
/// compressed stream is an error. The output is a view of a buffer the
/// stream owns: copy it before the next call on this stream, and do NOT
/// pass it to `ra_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_stream_push(
    h: *mut stream::Codec,
    data: *const u8,
    len: usize,
    finish: i32,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    let Some(c) = (unsafe { h.as_mut() }) else { return set_err("null stream") };
    match c.push(unsafe { slice(data, len) }, finish != 0) {
        Ok(v) => {
            unsafe {
                *out = v.as_ptr() as *mut u8;
                *out_len = v.len();
            }
            0
        }
        Err(e) => set_err(e),
    }
}

/// Releases a stream from `ra_stream_new`. Null is a no-op.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_stream_free(h: *mut stream::Codec) {
    if !h.is_null() {
        drop(unsafe { Box::from_raw(h) });
    }
}

// ---------------------------------------------------------------------------
// Files on disk (not on the web)
// ---------------------------------------------------------------------------

#[cfg(not(target_arch = "wasm32"))]
unsafe fn path<'a>(p: *const u8, len: usize) -> Result<&'a std::path::Path, String> {
    let s = std::str::from_utf8(unsafe { slice(p, len) }).map_err(|_| "path is not UTF-8")?;
    if s.is_empty() {
        return Err("empty path".into());
    }
    Ok(std::path::Path::new(s))
}

#[cfg(not(target_arch = "wasm32"))]
fn put_u64(out: *mut u64, v: u64) -> i32 {
    if !out.is_null() {
        unsafe { *out = v };
    }
    0
}

/// Compresses the file at `src` into `dst` with constant memory.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_compress_file(
    format: i32,
    src: *const u8,
    src_len: usize,
    dst: *const u8,
    dst_len: usize,
    level_: i32,
    parallel: i32,
) -> i32 {
    let Some(f) = fmt(format) else { return set_err("unknown format") };
    let r = (|| {
        let (s, d) = unsafe { (path(src, src_len)?, path(dst, dst_len)?) };
        files::compress_file(f, s, d, level(level_), parallel != 0)
    })();
    match r {
        Ok(()) => 0,
        Err(e) => set_err(e),
    }
}

/// Decompresses the file at `src` into `dst`; writes the output size to `out_n`.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_decompress_file(
    format: i32,
    src: *const u8,
    src_len: usize,
    dst: *const u8,
    dst_len: usize,
    out_n: *mut u64,
) -> i32 {
    let Some(f) = fmt(format) else { return set_err("unknown format") };
    let r = (|| {
        let (s, d) = unsafe { (path(src, src_len)?, path(dst, dst_len)?) };
        files::decompress_file(f, s, d)
    })();
    match r {
        Ok(n) => put_u64(out_n, n),
        Err(e) => set_err(e),
    }
}

/// Extracts the zip file at `zip` into the folder `dir`; writes the entry count to `out_count`.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_zip_extract_file(
    zip: *const u8,
    zip_len: usize,
    dir: *const u8,
    dir_len: usize,
    out_count: *mut u64,
) -> i32 {
    let r = (|| {
        let (z, d) = unsafe { (path(zip, zip_len)?, path(dir, dir_len)?) };
        files::extract_zip(z, d)
    })();
    match r {
        Ok(n) => put_u64(out_count, n),
        Err(e) => set_err(e),
    }
}

/// Zips the folder `dir` into the file `zip`; writes the entry count to `out_count`.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ra_zip_create_file(
    dir: *const u8,
    dir_len: usize,
    zip: *const u8,
    zip_len: usize,
    level_: i32,
    out_count: *mut u64,
) -> i32 {
    let r = (|| {
        let (d, z) = unsafe { (path(dir, dir_len)?, path(zip, zip_len)?) };
        files::zip_dir(d, z, level(level_))
    })();
    match r {
        Ok(n) => put_u64(out_count, n),
        Err(e) => set_err(e),
    }
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
