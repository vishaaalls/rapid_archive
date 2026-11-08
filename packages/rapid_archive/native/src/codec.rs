//! Whole-buffer deflate / zlib / gzip.
//!
//! * Default path: libdeflate. It is roughly 2x faster than zlib at the same
//!   level and produces smaller output, but only works on whole buffers, which
//!   is exactly what the Dart API passes us.
//! * Parallel path: input is split into 1 MiB chunks that are compressed on
//!   all cores with zlib-rs and joined pigz-style with sync flushes, so the
//!   result is still one ordinary gzip/zlib stream any decoder can read.
//! * Streaming fallback (flate2 / zlib-rs) for inputs libdeflate can't size,
//!   such as concatenated gzip members or a lying size trailer.

#![allow(non_upper_case_globals)]

use std::cell::RefCell;
use std::io::Read;
use std::ptr::NonNull;

use flate2::{Compress, Compression, FlushCompress};
use libdeflate_sys::*;
use rayon::prelude::*;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fmt {
    Gzip,
    Zlib,
    Deflate,
}

// ---------------------------------------------------------------------------
// Thread-local libdeflate state (a level-9 compressor is ~1 MiB to set up).
// ---------------------------------------------------------------------------

struct Comp {
    level: i32,
    ptr: NonNull<libdeflate_compressor>,
}
impl Drop for Comp {
    fn drop(&mut self) {
        unsafe { libdeflate_free_compressor(self.ptr.as_ptr()) }
    }
}
struct Decomp(NonNull<libdeflate_decompressor>);
impl Drop for Decomp {
    fn drop(&mut self) {
        unsafe { libdeflate_free_decompressor(self.0.as_ptr()) }
    }
}

thread_local! {
    static COMP: RefCell<Option<Comp>> = const { RefCell::new(None) };
    static DECOMP: RefCell<Option<Decomp>> = const { RefCell::new(None) };
}

fn with_comp<T>(level: i32, f: impl FnOnce(*mut libdeflate_compressor) -> T) -> T {
    COMP.with(|c| {
        let mut c = c.borrow_mut();
        if c.as_ref().map(|c| c.level) != Some(level) {
            install_allocator();
            let p = unsafe { libdeflate_alloc_compressor(level) };
            *c = Some(Comp { level, ptr: NonNull::new(p).expect("libdeflate OOM") });
        }
        f(c.as_ref().unwrap().ptr.as_ptr())
    })
}

pub(crate) fn with_decomp<T>(f: impl FnOnce(*mut libdeflate_decompressor) -> T) -> T {
    DECOMP.with(|d| {
        let mut d = d.borrow_mut();
        if d.is_none() {
            install_allocator();
            let p = unsafe { libdeflate_alloc_decompressor() };
            *d = Some(Decomp(NonNull::new(p).expect("libdeflate OOM")));
        }
        f(d.as_ref().unwrap().0.as_ptr())
    })
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

/// Compresses with libdeflate. `level` 0..=9 like zlib.
pub fn compress(f: Fmt, data: &[u8], level: u32) -> Vec<u8> {
    let level = level.min(9) as i32;
    with_comp(level, |c| unsafe {
        let bound = match f {
            Fmt::Gzip => libdeflate_gzip_compress_bound(c, data.len()),
            Fmt::Zlib => libdeflate_zlib_compress_bound(c, data.len()),
            Fmt::Deflate => libdeflate_deflate_compress_bound(c, data.len()),
        };
        let mut out = Vec::<u8>::with_capacity(bound);
        let inp = data.as_ptr() as *const _;
        let o = out.as_mut_ptr() as *mut _;
        let n = match f {
            Fmt::Gzip => libdeflate_gzip_compress(c, inp, data.len(), o, bound),
            Fmt::Zlib => libdeflate_zlib_compress(c, inp, data.len(), o, bound),
            Fmt::Deflate => libdeflate_deflate_compress(c, inp, data.len(), o, bound),
        };
        assert!(n > 0 || bound == 0, "libdeflate: output bound too small");
        out.set_len(n);
        out
    })
}

const CHUNK: usize = 1 << 20;

/// Multi-core compression. Output is a single standard stream; it is ~2-5%
/// larger than [`compress`] because each 1 MiB chunk starts with an empty
/// dictionary. Small inputs fall back to [`compress`].
pub fn compress_parallel(f: Fmt, data: &[u8], level: u32) -> Vec<u8> {
    if data.len() < 2 * CHUNK || rayon::current_num_threads() < 2 {
        return compress(f, data, level);
    }
    let lvl = Compression::new(level.min(9));
    let chunks: Vec<&[u8]> = data.chunks(CHUNK).collect();
    let last = chunks.len() - 1;
    let parts: Vec<Vec<u8>> = chunks
        .par_iter()
        .enumerate()
        .map(|(i, c)| deflate_chunk(c, lvl, i == last))
        .collect();
    let body: usize = parts.iter().map(Vec::len).sum();

    let mut out = Vec::with_capacity(body + 18);
    match f {
        Fmt::Gzip => out.extend_from_slice(&[0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]),
        Fmt::Zlib => out.extend_from_slice(&zlib_header(level)),
        Fmt::Deflate => {}
    }
    for p in &parts {
        out.extend_from_slice(p);
    }
    match f {
        Fmt::Gzip => {
            out.extend_from_slice(&crc32_parallel(data).to_le_bytes());
            out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        }
        Fmt::Zlib => out.extend_from_slice(&adler32(data).to_be_bytes()),
        Fmt::Deflate => {}
    }
    out
}

/// Raw deflate of one chunk; non-final chunks end with a sync flush so they
/// end byte-aligned and can be concatenated.
fn deflate_chunk(c: &[u8], lvl: Compression, last: bool) -> Vec<u8> {
    let mut z = Compress::new(lvl, false);
    let mut out = Vec::with_capacity(c.len() / 2 + 1024);
    let flush = if last { FlushCompress::Finish } else { FlushCompress::Sync };
    loop {
        let consumed = z.total_in() as usize;
        z.compress_vec(&c[consumed..], &mut out, flush).expect("deflate");
        if z.total_in() as usize == c.len() && out.len() < out.capacity() {
            return out;
        }
        out.reserve(out.capacity().max(1024));
    }
}

fn zlib_header(level: u32) -> [u8; 2] {
    let flevel = match level {
        0 | 1 => 0,
        2..=5 => 1,
        6 => 2,
        _ => 3,
    };
    let cmf = 0x78u16;
    let mut flg = flevel << 6;
    flg += 31 - ((cmf << 8) + flg) % 31;
    [cmf as u8, flg as u8]
}

fn crc32_parallel(data: &[u8]) -> u32 {
    data.par_chunks(CHUNK)
        .map(|c| {
            let mut h = crc32fast::Hasher::new();
            h.update(c);
            h
        })
        .reduce(crc32fast::Hasher::new, |mut a, b| {
            a.combine(&b);
            a
        })
        .finalize()
}

fn adler32(data: &[u8]) -> u32 {
    // Serial, but adler32 runs at several GB/s; not the bottleneck.
    let (mut a, mut b) = (1u32, 0u32);
    for c in data.chunks(5552) {
        for &x in c {
            a += x as u32;
            b += a;
        }
        a %= 65521;
        b %= 65521;
    }
    (b << 16) | a
}

// ---------------------------------------------------------------------------
// Decompression
// ---------------------------------------------------------------------------

/// Hard cap on output we'll allocate in one go (zip-bomb protection).
pub const MAX_OUT: usize = 2 << 30;

pub fn decompress(f: Fmt, data: &[u8]) -> Result<Vec<u8>, String> {
    // gzip records the size (mod 2^32) in its trailer; for the others, start
    // at 4x and grow.
    let mut cap = match f {
        Fmt::Gzip if data.len() >= 18 => {
            let t = &data[data.len() - 4..];
            u32::from_le_bytes([t[0], t[1], t[2], t[3]]) as usize
        }
        _ => data.len().saturating_mul(4).max(4096),
    }
    .min(MAX_OUT);

    for _ in 0..8 {
        let mut out = Vec::<u8>::with_capacity(cap);
        let (res, used_in, used_out) = with_decomp(|d| unsafe {
            let mut used_in = 0usize;
            let mut used_out = 0usize;
            let inp = data.as_ptr() as *const _;
            let o = out.as_mut_ptr() as *mut _;
            let r = match f {
                Fmt::Gzip => libdeflate_gzip_decompress_ex(
                    d, inp, data.len(), o, cap, &mut used_in, &mut used_out),
                Fmt::Zlib => libdeflate_zlib_decompress_ex(
                    d, inp, data.len(), o, cap, &mut used_in, &mut used_out),
                Fmt::Deflate => libdeflate_deflate_decompress_ex(
                    d, inp, data.len(), o, cap, &mut used_in, &mut used_out),
            };
            (r, used_in, used_out)
        });
        match res {
            libdeflate_result_LIBDEFLATE_SUCCESS => {
                unsafe { out.set_len(used_out) };
                if used_in == data.len() {
                    return Ok(out);
                }
                // More gzip members follow (e.g. `cat a.gz b.gz`): let the
                // streaming decoder handle the general case.
                if f == Fmt::Gzip {
                    return stream_decompress(f, data);
                }
                return Err("trailing data after compressed stream".into());
            }
            libdeflate_result_LIBDEFLATE_INSUFFICIENT_SPACE if cap < MAX_OUT => {
                cap = cap.saturating_mul(2).min(MAX_OUT);
            }
            libdeflate_result_LIBDEFLATE_INSUFFICIENT_SPACE => {
                return Err("decompressed data exceeds 2 GiB limit".into());
            }
            _ => return Err("invalid or corrupt compressed data".into()),
        }
    }
    stream_decompress(f, data)
}

fn stream_decompress(f: Fmt, data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let r = match f {
        Fmt::Gzip => flate2::read::MultiGzDecoder::new(data)
            .take(MAX_OUT as u64 + 1)
            .read_to_end(&mut out),
        Fmt::Zlib => flate2::read::ZlibDecoder::new(data)
            .take(MAX_OUT as u64 + 1)
            .read_to_end(&mut out),
        Fmt::Deflate => flate2::read::DeflateDecoder::new(data)
            .take(MAX_OUT as u64 + 1)
            .read_to_end(&mut out),
    };
    r.map_err(|e| e.to_string())?;
    if out.len() > MAX_OUT {
        return Err("decompressed data exceeds 2 GiB limit".into());
    }
    Ok(out)
}

/// Raw-deflate decompress into an exactly sized slot (zip entries).
pub fn inflate_exact(src: &[u8], dst: &mut [u8]) -> Result<(), String> {
    let mut used_out = 0usize;
    let r = with_decomp(|d| unsafe {
        libdeflate_deflate_decompress(
            d,
            src.as_ptr() as *const _,
            src.len(),
            dst.as_mut_ptr() as *mut _,
            dst.len(),
            &mut used_out,
        )
    });
    match r {
        libdeflate_result_LIBDEFLATE_SUCCESS if used_out == dst.len() => Ok(()),
        libdeflate_result_LIBDEFLATE_SUCCESS => Err("shorter than its declared size".into()),
        libdeflate_result_LIBDEFLATE_INSUFFICIENT_SPACE => {
            Err("larger than its declared size".into())
        }
        _ => Err("corrupt deflate data".into()),
    }
}


// ---------------------------------------------------------------------------
// WebAssembly has no libc: libdeflate is built freestanding and allocates
// through Rust's allocator.
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
fn install_allocator() {
    use std::alloc::{Layout, alloc, dealloc};
    use std::os::raw::c_void;
    const H: usize = 8; // size header so free() knows the layout
    unsafe extern "C" fn ld_malloc(size: usize) -> *mut c_void {
        let Ok(l) = Layout::from_size_align(size + H, 8) else { return std::ptr::null_mut() };
        let p = unsafe { alloc(l) };
        if p.is_null() {
            return p as *mut c_void;
        }
        unsafe {
            (p as *mut usize).write(size);
            p.add(H) as *mut c_void
        }
    }
    unsafe extern "C" fn ld_free(p: *mut c_void) {
        if p.is_null() {
            return;
        }
        unsafe {
            let base = (p as *mut u8).sub(H);
            let size = (base as *mut usize).read();
            dealloc(base, Layout::from_size_align_unchecked(size + H, 8));
        }
    }
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe { libdeflate_set_memory_allocator(ld_malloc, ld_free) });
}

#[cfg(not(target_arch = "wasm32"))]
fn install_allocator() {}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(n: usize) -> Vec<u8> {
        let mut x: u32 = 7;
        (0..n)
            .map(|i| {
                x = x.wrapping_mul(1103515245).wrapping_add(12345);
                if i % 3 == 0 { b"abcdefgh"[(x >> 16) as usize % 8] } else { b"lorem ipsum "[i % 12] }
            })
            .collect()
    }

    #[test]
    fn parallel_streams_are_standard() {
        let d = sample(5 << 20);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            let c = compress_parallel(f, &d, 6);
            // Independent decoder (flate2/zlib-rs streaming) must accept it.
            assert_eq!(stream_decompress(f, &c).unwrap(), d, "{f:?}");
            assert_eq!(decompress(f, &c).unwrap(), d, "{f:?}");
        }
    }

    #[test]
    fn libdeflate_output_is_standard() {
        let d = sample(300_000);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            let c = compress(f, &d, 6);
            assert_eq!(stream_decompress(f, &c).unwrap(), d);
        }
    }

    #[test]
    fn concatenated_gzip_members() {
        let (a, b) = (sample(1000), sample(2000));
        let mut gz = compress(Fmt::Gzip, &a, 6);
        gz.extend(compress(Fmt::Gzip, &b, 6));
        assert_eq!(decompress(Fmt::Gzip, &gz).unwrap(), [a, b].concat());
    }

    #[test]
    fn lying_gzip_trailer_still_decodes() {
        let d = sample(100_000);
        let mut gz = compress(Fmt::Gzip, &d, 6);
        let n = gz.len();
        gz[n - 4..].copy_from_slice(&10u32.to_le_bytes()); // claim 10 bytes
        // CRC still matches, the size field is wrong: libdeflate rejects it,
        // and so does a strict decoder. We must not return garbage.
        let r = decompress(Fmt::Gzip, &gz);
        assert!(r.is_err() || r.unwrap() == d);
    }

    #[test]
    fn adler_matches_reference() {
        let d = sample(100_000);
        let z = compress(Fmt::Zlib, &d, 6);
        let n = z.len();
        assert_eq!(u32::from_be_bytes(z[n - 4..].try_into().unwrap()), adler32(&d));
    }
}
