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

### MacBook Air M4 (10 cores), 256 MB inputs

| Operation | archive | rapid_archive | Speedup |
|---|---|---|---|
| gzip compress, JSON | 3357 ms | 1991 ms | **1.7x** (output 2% smaller) |
| gzip compress, JSON, `parallel: true` | 3463 ms | 371 ms | **9.3x** |
| gzip decompress, JSON | 323 ms | 189 ms | **1.7x** |
| gzip decompress, random | 52 ms | 14 ms | **3.7x** |
| zip create, 32,768 x 8 KB | 1216 ms | 299 ms | **4.1x** |
| zip extract all, 32,768 x 8 KB | 569 ms | 58 ms | **9.9x** |
| zip create, 8 x 64 MB | 1990 ms | 803 ms | **2.5x** |
| zip extract all, 8 x 64 MB | 702 ms | 145 ms | **4.9x** |

At 512 MB, parallel gzip compress was 9.1x faster (6.9 s down to 0.74 s).

### Linux x64 (4 cores), 16 MB inputs

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

### Try it on your own files

```sh
bash bench/compare.sh ~/Movies/clip.mov ~/Documents/SomeFolder ~/Downloads/thing.zip
```

A file is gzipped and gunzipped, a folder is zipped and then extracted, and a
`.zip` is extracted. Each result is checked byte for byte against the original
in both directions, and rapid_archive's outputs are written to `compare_out/`
so you can open them. Options: `--runs N`, `--level 0-9`.

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

## How the native library gets into your app

Released versions download a prebuilt library for your target from this
repo's GitHub Releases and check its SHA-256 against the hash shipped in
`hook/prebuilt.dart`, so app developers don't need Rust. Targets: Android
(arm64, armv7, x86_64), iOS (device, simulator arm64 and x86_64), macOS
(arm64, x86_64), Linux (x64, arm64) and Windows (x64, arm64). Web uses the
embedded WebAssembly build.

To build from source instead (needs Rust and `rustup target add <triple>`),
add to your app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    rapid_archive:
      from_source: true
```

Releasing: push a tag like `v0.1.0`. `.github/workflows/release.yml` builds
every target and attaches the binaries plus `SHA256SUMS` to the release. Then
run `dart run tool/update_prebuilt.dart v0.1.0` and commit `hook/prebuilt.dart`.

## Status

- Done: gzip, zlib and raw deflate; parallel gzip/zlib; zip create and extract;
  interop tests both ways against `package:archive`; zip-bomb and corruption
  checks; web via WebAssembly; tested on Android (emulator), iOS (simulator,
  device build) and macOS; prebuilt binaries via GitHub Actions.
- Not yet: testing on a physical phone, zip64 writing (over 4 GB or 65,535
  entries), streaming and file APIs, tar/bzip2/xz/zstd.
- Native library size: about 790 KB on linux x64, 668 KB on Android arm64.
