//! Minimal zip directory reader (no dependencies, works on every target
//! including WebAssembly). Reads the central directory, including zip64
//! records, and the local headers needed to locate each entry's data.

pub struct Entry {
    pub name: String,
    pub dir: bool,
    pub encrypted: bool,
    pub method: u16,
    pub crc: u32,
    pub csize: u64,
    pub size: u64,
    /// Offset of the entry's (compressed) data in the archive.
    pub data_start: u64,
}

fn u16_at(b: &[u8], i: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?))
}
fn u32_at(b: &[u8], i: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?))
}
fn u64_at(b: &[u8], i: usize) -> Option<u64> {
    Some(u64::from_le_bytes(b.get(i..i + 8)?.try_into().ok()?))
}

const BAD: &str = "not a zip file or the zip is corrupt";

pub fn read(data: &[u8]) -> Result<Vec<Entry>, String> {
    // End of central directory: 22 bytes + up to 65,535 bytes of comment.
    let min = data.len().saturating_sub(22 + 0xffff);
    let eocd = (min..=data.len().saturating_sub(22))
        .rev()
        .find(|&i| u32_at(data, i) == Some(0x0605_4b50))
        .ok_or(BAD)?;
    let mut count = u16_at(data, eocd + 10).ok_or(BAD)? as u64;
    let mut cd_off = u32_at(data, eocd + 16).ok_or(BAD)? as u64;

    // zip64: the locator sits right before the EOCD.
    if eocd >= 20 && u32_at(data, eocd - 20) == Some(0x0706_4b50) {
        let z = u64_at(data, eocd - 20 + 8).ok_or(BAD)? as usize;
        if u32_at(data, z) != Some(0x0606_4b50) {
            return Err(BAD.into());
        }
        count = u64_at(data, z + 32).ok_or(BAD)?;
        cd_off = u64_at(data, z + 48).ok_or(BAD)?;
    }
    // Every central header is at least 46 bytes: cap the count so a hostile
    // header can't make us reserve huge vectors.
    if count > (data.len() / 46) as u64 {
        return Err(BAD.into());
    }

    let mut entries = Vec::with_capacity(count as usize);
    let mut p = usize::try_from(cd_off).map_err(|_| BAD)?;
    for _ in 0..count {
        if u32_at(data, p) != Some(0x0201_4b50) {
            return Err(BAD.into());
        }
        let flags = u16_at(data, p + 8).ok_or(BAD)?;
        let method = u16_at(data, p + 10).ok_or(BAD)?;
        let crc = u32_at(data, p + 16).ok_or(BAD)?;
        let mut csize = u32_at(data, p + 20).ok_or(BAD)? as u64;
        let mut size = u32_at(data, p + 24).ok_or(BAD)? as u64;
        let nlen = u16_at(data, p + 28).ok_or(BAD)? as usize;
        let xlen = u16_at(data, p + 30).ok_or(BAD)? as usize;
        let clen = u16_at(data, p + 32).ok_or(BAD)? as usize;
        let mut local = u32_at(data, p + 42).ok_or(BAD)? as u64;
        let name_bytes = data.get(p + 46..p + 46 + nlen).ok_or(BAD)?;
        let extra = data.get(p + 46 + nlen..p + 46 + nlen + xlen).ok_or(BAD)?;

        // zip64 extended info: only the fields that overflowed, in order.
        let mut x = 0;
        while x + 4 <= extra.len() {
            let id = u16_at(extra, x).unwrap();
            let len = u16_at(extra, x + 2).unwrap() as usize;
            if id == 0x0001 {
                let mut q = x + 4;
                for field in [&mut size, &mut csize, &mut local] {
                    if *field == 0xffff_ffff {
                        *field = u64_at(extra, q).ok_or(BAD)?;
                        q += 8;
                    }
                }
            }
            x += 4 + len;
        }

        let name = String::from_utf8_lossy(name_bytes).into_owned();
        let dir = name.ends_with('/');

        // Local header: its own name/extra lengths can differ from the
        // central copy, so read them to find where the data starts.
        let l = usize::try_from(local).map_err(|_| BAD)?;
        if u32_at(data, l) != Some(0x0403_4b50) {
            return Err(format!("{name}: bad local header"));
        }
        let lnlen = u16_at(data, l + 26).ok_or(BAD)? as u64;
        let lxlen = u16_at(data, l + 28).ok_or(BAD)? as u64;

        entries.push(Entry {
            name,
            dir,
            encrypted: flags & 1 != 0,
            method,
            crc,
            csize,
            size,
            data_start: local + 30 + lnlen + lxlen,
        });
        p += 46 + nlen + xlen + clen;
    }
    Ok(entries)
}
