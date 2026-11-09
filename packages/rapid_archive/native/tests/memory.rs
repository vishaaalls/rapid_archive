//! Peak live heap while streaming 256 MiB must not depend on the input size.
//! A counting allocator tracks live bytes; this file is its own test binary,
//! so no other test shares the counter.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

struct Counting;
static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
/// Allocations of 256 KiB or more. macOS keeps the pages of freed large
/// blocks, so a fresh large block per window adds up; buffers must be reused.
static LARGE: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            let now = LIVE.fetch_add(l.size(), Relaxed) + l.size();
            PEAK.fetch_max(now, Relaxed);
            if l.size() >= 256 * 1024 {
                LARGE.fetch_add(1, Relaxed);
            }
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) };
        LIVE.fetch_sub(l.size(), Relaxed);
    }
}

#[global_allocator]
static A: Counting = Counting;

const MIB: usize = 1 << 20;

/// Returns (peak extra live bytes, large allocations) while `f` runs.
fn measure(f: impl FnOnce()) -> (usize, usize) {
    let base = LIVE.load(Relaxed);
    PEAK.store(base, Relaxed);
    LARGE.store(0, Relaxed);
    f();
    (PEAK.load(Relaxed) - base, LARGE.load(Relaxed))
}

#[test]
fn streaming_memory_is_bounded() {
    let threads = rayon::current_num_threads();
    // Window (2 MiB per core, at most 64 MiB) + one output buffer per chunk
    // + compressor states + I/O buffers, with headroom.
    let limit = (4 * MIB * (threads * 2).clamp(2, 64)).max(64 * MIB);
    // Fixed buffers: about two per chunk slot plus I/O buffers. The stream
    // The old code made one per chunk, hundreds for this input.
    let large_limit = 4 * (threads * 2).clamp(2, 64) + 16;

    let dir = std::env::temp_dir().join(format!("ra_mem_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let src = dir.join("in.log");
    {
        use std::io::Write;
        let mut w = std::io::BufWriter::new(std::fs::File::create(&src).unwrap());
        let line: Vec<u8> = (0..100_000u32)
            .flat_map(|i| format!("line {i} ms={} path=/api/{}\n", i * 7 % 900, i * 31 % 99_999).into_bytes())
            .collect();
        let mut n = 0;
        while n < 256 * MIB {
            w.write_all(&line).unwrap();
            n += line.len();
        }
    }
    let s = src.to_str().unwrap().as_bytes();
    let gz = dir.join("out.gz");
    let g = gz.to_str().unwrap().as_bytes();
    let back = dir.join("back.log");
    let b = back.to_str().unwrap().as_bytes();

    let (peak, large) = measure(|| unsafe {
        assert_eq!(rapid_archive::ra_compress_file(0, s.as_ptr(), s.len(), g.as_ptr(), g.len(), 1, 1), 0);
    });
    println!("compress_file (parallel): peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "compress_file (parallel): {large} large allocations");
    assert!(peak < limit, "compress_file used {} MiB", peak / MIB);

    let (peak, large) = measure(|| unsafe {
        let mut n = 0u64;
        assert_eq!(rapid_archive::ra_decompress_file(0, g.as_ptr(), g.len(), b.as_ptr(), b.len(), &mut n), 0);
        assert_eq!(n, std::fs::metadata(&src).unwrap().len());
    });
    println!("decompress_file: peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "decompress_file: {large} large allocations");
    assert!(peak < limit, "decompress_file used {} MiB", peak / MIB);

    // The FFI stream encoder, fed 64 KiB at a time like a Dart file stream.
    let data = std::fs::read(&src).unwrap();
    let (peak, large) = measure(|| unsafe {
        let h = rapid_archive::ra_stream_new(0, 0, 1, 1);
        let (mut out, mut len) = (std::ptr::null_mut(), 0usize);
        for c in data.chunks(64 * 1024) {
            assert_eq!(rapid_archive::ra_stream_push(h, c.as_ptr(), c.len(), 0, &mut out, &mut len), 0);
        }
        assert_eq!(rapid_archive::ra_stream_push(h, std::ptr::null(), 0, 1, &mut out, &mut len), 0);
        rapid_archive::ra_stream_free(h);
    });
    println!("stream encoder (parallel): peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "stream encoder (parallel): {large} large allocations");
    assert!(peak < limit, "stream encoder used {} MiB", peak / MIB);

    // The FFI stream decoder, fed 64 KiB at a time.
    let z = std::fs::read(&gz).unwrap();
    let (peak, large) = measure(|| unsafe {
        let h = rapid_archive::ra_stream_new(1, 0, 0, 0);
        let (mut out, mut len) = (std::ptr::null_mut(), 0usize);
        let mut total = 0;
        for c in z.chunks(64 * 1024) {
            assert_eq!(rapid_archive::ra_stream_push(h, c.as_ptr(), c.len(), 0, &mut out, &mut len), 0);
            total += len;
        }
        assert_eq!(rapid_archive::ra_stream_push(h, std::ptr::null(), 0, 1, &mut out, &mut len), 0);
        total += len;
        rapid_archive::ra_stream_free(h);
        assert_eq!(total, data.len());
    });
    println!("stream decoder: peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "stream decoder: {large} large allocations");
    assert!(peak < limit, "stream decoder used {} MiB", peak / MIB);

    // Folder zipping with one big (streamed) file.
    let zd = dir.join("zipme");
    std::fs::create_dir_all(&zd).unwrap();
    std::fs::rename(&back, zd.join("big.log")).unwrap();
    let zp = dir.join("z.zip");
    let (zdb, zpb) = (zd.to_str().unwrap().as_bytes(), zp.to_str().unwrap().as_bytes());
    let (peak, large) = measure(|| unsafe {
        let mut n = 0u64;
        assert_eq!(rapid_archive::ra_zip_create_file(zdb.as_ptr(), zdb.len(), zpb.as_ptr(), zpb.len(), 1, &mut n), 0);
    });
    println!("zip_create_file: peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "zip_create_file: {large} large allocations");
    assert!(peak < limit, "zip_create_file used {} MiB", peak / MIB);

    let xd = dir.join("x");
    let xb = xd.to_str().unwrap().as_bytes();
    let (peak, large) = measure(|| unsafe {
        let mut n = 0u64;
        assert_eq!(rapid_archive::ra_zip_extract_file(zpb.as_ptr(), zpb.len(), xb.as_ptr(), xb.len(), &mut n), 0);
    });
    println!("zip_extract_file: peak {} MiB, {large} large allocations", peak / MIB);
    assert!(large <= large_limit, "zip_extract_file: {large} large allocations");
    assert!(peak < limit, "zip_extract_file used {} MiB", peak / MIB);
    assert_eq!(std::fs::read(xd.join("big.log")).unwrap(), data);

    std::fs::remove_dir_all(&dir).unwrap();
}
