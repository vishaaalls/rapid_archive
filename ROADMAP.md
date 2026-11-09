# rapid_archive: path to a published package

Status today: one Dart package with the same API on every platform. It passes
the same tests natively (macOS, Linux) and in Chrome (WebAssembly).

| Platform | How it runs | Status |
|---|---|---|
| Android, iOS | Rust (libdeflate) via dart:ffi, prebuilt or built by `hook/build.dart` | Emulator/simulator tested; physical phone next |
| macOS, Linux, Windows | same | macOS and Linux tested |
| Web | Same Rust core compiled to WebAssembly (zlib-rs), embedded in the package | Tested in Chrome: 4 to 6x faster than `archive` |

## 1. Android and iOS (done on emulator and simulator, 2026-11-08)
- Android: `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android`,
  point cargo at the NDK linkers, build an example Flutter app, run tests on an emulator and a phone.
- iOS: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`, static linking (already chosen
  by the hook), test on the simulator and a device, and measure the app-size cost.
- Add `example/`, a Flutter app that runs the benchmark on the phone itself.

## 2. Prebuilt binaries (done: v0.1.0, 12 targets)
- GitHub Actions builds the library for every target on each tagged release and uploads the
  binaries plus SHA-256 checksums to the GitHub Release.
- `hook/build.dart` downloads the matching binary and verifies its checksum. It builds with cargo
  only when Rust is installed and no download fits, or when a contributor forces it.

## 3. Big files (done 2026-11-09)
- `encodeStream` / `decodeStream` / `transformer()` on the gzip and zlib classes (web too).
- `rapid_archive_io.dart`: `gzipFile`, `gunzipFile`, `extractFileToDisk`,
  `ZipFileEncoder.zipDirectory`, each in a background isolate.
- zip64 writing (archives or entries over 4 GB, more than 65,535 entries).
- Checked on 2.5 GB and 5 GB files: memory stays flat, about 50 MB above the Dart VM's own use.

## 4. Web extras
- Multi-threaded WebAssembly when the page is cross-origin isolated (COOP/COEP headers).
- Optionally ship the .wasm as a separate asset instead of embedding it (smaller JS bundle).

## 5. Publish
- Remove `publish_to: none`, then add a LICENSE (MIT), a CHANGELOG, API docs and pub.dev topics.
- `dart pub publish --dry-run`, then publish from Vishal's pub.dev account. (The name
  `rapid_archive` was free on 2026-11-08.)
- Host the benchmark site on GitHub Pages from `site/`.

Needs from Vishal: a GitHub repo (CI, releases, Pages) and a pub.dev account.
