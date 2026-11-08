# rapid_archive

Fast gzip, zlib and zip for Dart and Flutter, with a Rust core (libdeflate
and zlib-rs). It's a drop-in replacement for `package:archive`'s codecs.

```dart
// import 'package:archive/archive.dart';
import 'package:rapid_archive/rapid_archive.dart';

final gz = const GZipEncoder().encodeBytes(bytes);            // 1.7x faster, smaller output
final gzFast = const GZipEncoder(parallel: true).encodeBytes(bytes); // 5x, all cores
final zip = const ZipEncoder().encodeBytes(archive);          // entries compressed in parallel
final files = const ZipDecoder().decodeBytes(zipBytes).files; // parallel extract, CRC-checked
```

## Benchmarks

16 MB inputs on a 4-core x86_64 Linux box, Dart 3.13 AOT, median of 7 runs.
`package:archive` 4.6 already uses the C zlib inside `dart:io` on mobile and
desktop. Its pure-Dart path is what Flutter **web** runs.

| Operation | archive (native zlib) | archive (pure Dart / web) | rapid_archive | Speedup |
|---|---|---|---|---|
| gzip compress, JSON | 391 ms | 1011 ms | 228 ms | **1.7x** (output 2% smaller) |
| gzip compress, JSON, `parallel: true` | 424 ms | | 83 ms | **5.1x** (output 5% larger) |
| gzip decompress, JSON | 35 ms | 102 ms | 21 ms | **1.7x** |
| gzip compress, random | 370 ms | | 204 ms | **1.8x** |
| gzip decompress, random | 15 ms | | 6 ms | **2.5x** |
| zip create, 2000 x 8 KB | 193 ms | | 53 ms | **3.7x** |
| zip extract all, 2000 x 8 KB | 88 ms | | 14 ms | **6.1x** |
| zip create, 8 x 4 MB | 289 ms | | 156 ms | **1.9x** |
| zip extract all, 8 x 4 MB | 87 ms | | 19 ms | **4.5x** |

Phones have 6 to 8 cores, so the parallel numbers should scale further. They
still need measuring on real devices.

At 256 MB the gap holds or widens: gzip 2x (5.2x parallel), zip extract 5.7 to 6.8x
(see `bench/RESULTS-linux-x64-4core-256mb.txt`).

### Run it yourself (macOS / Linux)

```sh
curl https://sh.rustup.rs -sSf | sh     # Rust, once
brew install dart                       # or use the dart that ships with Flutter 3.38+
cd packages/rapid_archive
bench/run.sh --mb 512 --runs 3          # 512 MB inputs
bench/run.sh --mb 64 --file ~/Downloads/some-big-file.mov
```

Options: `--mb N` input size, `--runs N` timed runs (median), `--file PATH` add
one of your own files, `--pure` also time the pure-Dart (web) codec.
Memory use is about 6x `--mb`, so keep `--mb` at or below 1024 on a 16 GB machine.

## Status (proof of concept)

- Done: gzip, zlib and raw deflate; parallel gzip/zlib; zip create and extract;
  build hook for all native targets; interop tests both ways against
  `package:archive`; zip-bomb and corruption checks.
- Not yet: prebuilt binaries (right now app builds need a Rust toolchain),
  Android/iOS device testing, web (WASM), zip64 writing (over 4 GB or 65,535
  entries), streaming and file APIs, tar/bzip2/xz/zstd, and an
  `Isolate.run` helper for large inputs on the UI isolate.
- Native library size: about 790 KB on linux x64. Not yet measured for
  Android and iOS.
