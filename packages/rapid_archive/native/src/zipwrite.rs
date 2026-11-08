//! Minimal, parallel zip writer.
//!
//! The `zip` crate writes entries one after another. Here every entry is
//! deflated on its own rayon task first, then the headers and payloads are
//! stitched together in one pass, so a zip with many files uses all cores.

use rayon::prelude::*;

pub struct Entry<'a> {
    pub name: &'a str,
    pub data: &'a [u8],
    pub dir: bool,
    /// Store without compression (for already-compressed files like JPEGs).
    pub store: bool,
}

struct Packed<'a> {
    method: u16,
    crc: u32,
    payload: std::borrow::Cow<'a, [u8]>,
}

// 1980-01-01 00:00, the zip epoch. Deterministic output by default.
const DOS_TIME: u16 = 0;
const DOS_DATE: u16 = (0 << 9) | (1 << 5) | 1;

fn pack<'a>(e: &Entry<'a>, lvl: u32) -> std::io::Result<Packed<'a>> {
    if e.dir || e.data.is_empty() {
        return Ok(Packed { method: 0, crc: 0, payload: std::borrow::Cow::Borrowed(&[]) });
    }
    let crc = crc32fast::hash(e.data);
    if !e.store && lvl > 0 {
        let c = crate::codec::compress(crate::codec::Fmt::Deflate, e.data, lvl);
        // Keep deflate only if it actually saved space.
        if c.len() < e.data.len() {
            return Ok(Packed { method: 8, crc, payload: std::borrow::Cow::Owned(c) });
        }
    }
    Ok(Packed { method: 0, crc, payload: std::borrow::Cow::Borrowed(e.data) })
}

pub fn write(entries: &[Entry<'_>], lvl: u32) -> Result<Vec<u8>, String> {
    if entries.len() > u16::MAX as usize {
        return Err("more than 65535 entries needs zip64, not supported yet".into());
    }
    let packed: Vec<Packed> = entries
        .par_iter()
        .map(|e| pack(e, lvl))
        .collect::<std::io::Result<_>>()
        .map_err(|e| e.to_string())?;

    let payload_total: usize = packed.iter().map(|p| p.payload.len()).sum();
    let names_total: usize = entries.iter().map(|e| e.name.len()).sum();
    let mut out = Vec::with_capacity(payload_total + names_total * 2 + entries.len() * 76 + 22);
    let mut offsets = Vec::with_capacity(entries.len());

    let too_big = || "archive larger than 4 GiB needs zip64, not supported yet".to_string();
    let u32_of = |n: usize| u32::try_from(n).map_err(|_| too_big());

    for (e, p) in entries.iter().zip(&packed) {
        offsets.push(u32_of(out.len())?);
        let name = e.name.as_bytes();
        let usize_ = if e.dir { 0 } else { e.data.len() };
        put32(&mut out, 0x0403_4b50);
        put16(&mut out, 20); // version needed
        put16(&mut out, 0x0800); // UTF-8 names
        put16(&mut out, p.method);
        put16(&mut out, DOS_TIME);
        put16(&mut out, DOS_DATE);
        put32(&mut out, p.crc);
        put32(&mut out, u32_of(p.payload.len())?);
        put32(&mut out, u32_of(usize_)?);
        put16(&mut out, name.len() as u16);
        put16(&mut out, 0); // extra
        out.extend_from_slice(name);
        out.extend_from_slice(&p.payload);
    }

    let cd_start = out.len();
    for ((e, p), off) in entries.iter().zip(&packed).zip(&offsets) {
        let name = e.name.as_bytes();
        let usize_ = if e.dir { 0 } else { e.data.len() };
        let ext_attr: u32 = if e.dir { (0o040755 << 16) | 0x10 } else { 0o100644 << 16 };
        put32(&mut out, 0x0201_4b50);
        put16(&mut out, (3 << 8) | 20); // made by: unix, spec 2.0
        put16(&mut out, 20);
        put16(&mut out, 0x0800);
        put16(&mut out, p.method);
        put16(&mut out, DOS_TIME);
        put16(&mut out, DOS_DATE);
        put32(&mut out, p.crc);
        put32(&mut out, p.payload.len() as u32);
        put32(&mut out, usize_ as u32);
        put16(&mut out, name.len() as u16);
        put16(&mut out, 0); // extra
        put16(&mut out, 0); // comment
        put16(&mut out, 0); // disk
        put16(&mut out, 0); // internal attrs
        put32(&mut out, ext_attr);
        put32(&mut out, *off);
        out.extend_from_slice(name);
    }
    let cd_len = out.len() - cd_start;

    put32(&mut out, 0x0605_4b50);
    put16(&mut out, 0);
    put16(&mut out, 0);
    put16(&mut out, entries.len() as u16);
    put16(&mut out, entries.len() as u16);
    put32(&mut out, u32_of(cd_len)?);
    put32(&mut out, u32_of(cd_start)?);
    put16(&mut out, 0);
    Ok(out)
}

fn put16(o: &mut Vec<u8>, v: u16) {
    o.extend_from_slice(&v.to_le_bytes());
}
fn put32(o: &mut Vec<u8>, v: u32) {
    o.extend_from_slice(&v.to_le_bytes());
}
