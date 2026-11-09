//! Streaming compression and decompression with constant memory.
//!
//! * [`ParDeflate`]: multi-core streaming deflate (the pigz method). Input is
//!   buffered into a window of 1 MiB chunks; each full window is compressed
//!   on all cores, and chunks end with a sync flush so they join into one
//!   standard stream. Memory stays at about two windows.
//! * [`Codec`]: one streaming encoder or decoder behind the C ABI handle
//!   (`ra_stream_*`). Single-core encoders use flate2 (zlib-rs), which keeps
//!   the dictionary across chunks for the best ratio.

use std::io::{self, Write};

use flate2::{Compress, Compression, FlushCompress};
use rayon::prelude::*;

use crate::codec::{self, Fmt, CHUNK};

/// Running Adler-32 (zlib trailer).
struct Adler {
    a: u32,
    b: u32,
}
impl Adler {
    fn new() -> Self {
        Adler { a: 1, b: 0 }
    }
    fn update(&mut self, data: &[u8]) {
        for c in data.chunks(5552) {
            for &x in c {
                self.a += x as u32;
                self.b += self.a;
            }
            self.a %= 65521;
            self.b %= 65521;
        }
    }
    fn finish(&self) -> u32 {
        (self.b << 16) | self.a
    }
}

/// One reusable deflate worker: its compressor state and output buffer are
/// kept between windows, so streaming allocates nothing per window.
struct Slot {
    z: Compress,
    out: Vec<u8>,
}

impl Slot {
    fn new(lvl: Compression) -> Self {
        Slot { z: Compress::new(lvl, false), out: Vec::new() }
    }

    /// Raw deflate of one chunk; non-final chunks end with a sync flush so
    /// they end byte-aligned and can be concatenated.
    fn run(&mut self, c: &[u8], last: bool) {
        self.z.reset();
        self.out.clear();
        let want = c.len() / 2 + 1024;
        if self.out.capacity() < want {
            self.out.reserve_exact(want);
        }
        let flush = if last { FlushCompress::Finish } else { FlushCompress::Sync };
        let base = self.z.total_in();
        loop {
            let consumed = (self.z.total_in() - base) as usize;
            self.z.compress_vec(&c[consumed..], &mut self.out, flush).expect("deflate");
            if (self.z.total_in() - base) as usize == c.len() && self.out.len() < self.out.capacity() {
                return;
            }
            self.out.reserve(self.out.capacity().max(1024));
        }
    }
}

pub struct ParDeflate {
    fmt: Fmt,
    level: u32,
    /// Input waiting to be compressed; never grows past `window`.
    buf: Vec<u8>,
    window: usize,
    slots: Vec<Slot>,
    header_done: bool,
    finished: bool,
    crc: crc32fast::Hasher,
    adler: Adler,
    len: u64,
}

impl ParDeflate {
    pub fn new(fmt: Fmt, level: u32) -> Self {
        let threads = rayon::current_num_threads().max(1);
        ParDeflate {
            fmt,
            level: level.min(9),
            buf: Vec::new(),
            window: CHUNK * (threads * 2).clamp(2, 64),
            slots: Vec::new(),
            header_done: false,
            finished: false,
            crc: crc32fast::Hasher::new(),
            adler: Adler::new(),
            len: 0,
        }
    }

    /// Compresses everything in `buf` on all cores, appends it to `out`
    /// and empties `buf` (keeping its memory).
    fn compress_buf(&mut self, final_tail: bool, out: &mut Vec<u8>) {
        let lvl = Compression::new(self.level);
        let n = self.buf.len().div_ceil(CHUNK).max(1);
        while self.slots.len() < n {
            self.slots.push(Slot::new(lvl));
        }
        let (buf, slots) = (&self.buf, &mut self.slots[..n]);
        slots.par_iter_mut().enumerate().for_each(|(i, s)| {
            let c = &buf[(i * CHUNK).min(buf.len())..((i + 1) * CHUNK).min(buf.len())];
            s.run(c, final_tail && i == n - 1);
        });
        out.reserve(slots.iter().map(|s| s.out.len()).sum());
        for s in slots.iter() {
            out.extend_from_slice(&s.out);
        }
        self.buf.clear();
    }

    /// Feeds `data` and appends whatever compressed bytes are ready to `out`.
    /// With `finish`, flushes everything and writes the trailer. Memory is
    /// fixed: one input window plus one output buffer per chunk, reused.
    pub fn push_into(&mut self, data: &[u8], finish: bool, out: &mut Vec<u8>) {
        if self.finished {
            return;
        }
        if !self.header_done {
            match self.fmt {
                Fmt::Gzip => out.extend_from_slice(&[0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]),
                Fmt::Zlib => out.extend_from_slice(&codec::zlib_header(self.level)),
                Fmt::Deflate => {}
            }
            self.header_done = true;
        }
        match self.fmt {
            Fmt::Gzip => self.crc.update(data),
            Fmt::Zlib => self.adler.update(data),
            Fmt::Deflate => {}
        }
        self.len += data.len() as u64;

        let mut data = data;
        while !data.is_empty() {
            let take = (self.window - self.buf.len()).min(data.len());
            let need = self.buf.len() + take;
            if self.buf.capacity() < need {
                // Grow once toward the window size, never past it.
                let target = need.max(self.buf.capacity() * 2).min(self.window);
                self.buf.reserve_exact(target - self.buf.len());
            }
            self.buf.extend_from_slice(&data[..take]);
            data = &data[take..];
            if self.buf.len() == self.window {
                self.compress_buf(false, out);
            }
        }
        if finish {
            self.compress_buf(true, out);
            match self.fmt {
                Fmt::Gzip => {
                    out.extend_from_slice(&self.crc.clone().finalize().to_le_bytes());
                    out.extend_from_slice(&(self.len as u32).to_le_bytes());
                }
                Fmt::Zlib => out.extend_from_slice(&self.adler.finish().to_be_bytes()),
                Fmt::Deflate => {}
            }
            self.finished = true;
            // Release the working memory now; the stream is done.
            self.buf = Vec::new();
            self.slots = Vec::new();
        }
    }

    /// Same as [`push_into`](Self::push_into), returning a new buffer.
    pub fn push(&mut self, data: &[u8], finish: bool) -> Vec<u8> {
        let mut out = Vec::new();
        self.push_into(data, finish, &mut out);
        out
    }
}

/// One streaming codec behind an `ra_stream_*` handle.
pub enum Codec {
    GzE(flate2::write::GzEncoder<Vec<u8>>),
    ZlE(flate2::write::ZlibEncoder<Vec<u8>>),
    DfE(flate2::write::DeflateEncoder<Vec<u8>>),
    Par(ParDeflate, Vec<u8>),
    GzD(flate2::write::MultiGzDecoder<Vec<u8>>),
    ZlD(flate2::write::ZlibDecoder<Vec<u8>>),
    DfD(flate2::write::DeflateDecoder<Vec<u8>>),
}

impl Codec {
    pub fn new(decode: bool, f: Fmt, level: u32, parallel: bool) -> Self {
        let lvl = Compression::new(level.min(9));
        match (decode, f, parallel) {
            (false, _, true) => Codec::Par(ParDeflate::new(f, level), Vec::new()),
            (false, Fmt::Gzip, _) => Codec::GzE(flate2::write::GzEncoder::new(Vec::new(), lvl)),
            (false, Fmt::Zlib, _) => Codec::ZlE(flate2::write::ZlibEncoder::new(Vec::new(), lvl)),
            (false, Fmt::Deflate, _) => Codec::DfE(flate2::write::DeflateEncoder::new(Vec::new(), lvl)),
            (true, Fmt::Gzip, _) => Codec::GzD(flate2::write::MultiGzDecoder::new(Vec::new())),
            (true, Fmt::Zlib, _) => Codec::ZlD(flate2::write::ZlibDecoder::new(Vec::new())),
            (true, Fmt::Deflate, _) => Codec::DfD(flate2::write::DeflateDecoder::new(Vec::new())),
        }
    }

    /// Feeds `data` and returns the output that is ready, as a view of a
    /// buffer the codec owns and reuses: it is valid until the next call.
    /// Reusing one buffer keeps streaming free of per-call allocations.
    /// With `finish`, the stream is completed; a truncated compressed
    /// stream is an error.
    pub fn push(&mut self, data: &[u8], finish: bool) -> io::Result<&[u8]> {
        macro_rules! run {
            ($w:expr) => {{
                $w.get_mut().clear();
                $w.write_all(data)?;
                if finish {
                    $w.try_finish()?;
                }
                Ok($w.get_ref().as_slice())
            }};
        }
        match self {
            Codec::Par(p, out) => {
                out.clear();
                p.push_into(data, finish, out);
                Ok(out.as_slice())
            }
            Codec::GzE(w) => run!(w),
            Codec::ZlE(w) => run!(w),
            Codec::DfE(w) => run!(w),
            Codec::GzD(w) => run!(w),
            Codec::ZlD(w) => run!(w),
            Codec::DfD(w) => run!(w),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(n: usize) -> Vec<u8> {
        (0..n).map(|i| ((i * 31) % 251) as u8 ^ ((i / 1000) as u8)).collect()
    }

    #[test]
    fn par_deflate_streams_are_standard() {
        let data = sample(9 * CHUNK + 12345);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            let mut p = ParDeflate::new(f, 6);
            let mut out = Vec::new();
            for piece in data.chunks(300_000) {
                out.extend(p.push(piece, false));
            }
            out.extend(p.push(&[], true));
            assert_eq!(codec::decompress(f, &out).unwrap(), data, "{f:?}");
        }
        // Empty input.
        let mut p = ParDeflate::new(Fmt::Gzip, 6);
        let out = p.push(&[], true);
        assert!(codec::decompress(Fmt::Gzip, &out).unwrap().is_empty());
    }

    #[test]
    fn codec_round_trip_in_pieces() {
        let data = sample(3 * CHUNK + 777);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            for parallel in [false, true] {
                let mut e = Codec::new(false, f, 6, parallel);
                let mut z = Vec::new();
                for piece in data.chunks(65_536) {
                    z.extend_from_slice(e.push(piece, false).unwrap());
                }
                z.extend_from_slice(e.push(&[], true).unwrap());
                let mut d = Codec::new(true, f, 0, false);
                let mut back = Vec::new();
                for piece in z.chunks(10_000) {
                    back.extend_from_slice(d.push(piece, false).unwrap());
                }
                back.extend_from_slice(d.push(&[], true).unwrap());
                assert_eq!(back, data, "{f:?} parallel={parallel}");
            }
        }
    }

    #[test]
    fn truncated_stream_is_an_error() {
        let data = sample(200_000);
        for f in [Fmt::Gzip, Fmt::Zlib, Fmt::Deflate] {
            let z = codec::compress(f, &data, 6);
            let mut d = Codec::new(true, f, 0, false);
            let r = d.push(&z[..z.len() / 2], true);
            assert!(r.is_err(), "{f:?} accepted a truncated stream");
        }
    }
}
