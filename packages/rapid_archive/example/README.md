# rapid_archive example

An on-device benchmark comparing `rapid_archive` (Rust) with `archive` (pure Dart)
for gzip and zip. It runs on Android, iOS, macOS and other Flutter platforms.

```sh
cd packages/rapid_archive/example
flutter run --release                            # pick a simulator, emulator or device
```

Benchmark numbers only mean something in `--release` (or `--profile`) mode.
The build needs Rust with the target for your device, for example
`rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios x86_64-apple-darwin`
(`flutter build ios --simulator` and macOS release builds also build an x86_64 slice).

To run the benchmark without tapping, pass `--dart-define=AUTORUN=true` (and optionally
`--dart-define=MB=128`); results are printed as `BENCH ...` lines.
