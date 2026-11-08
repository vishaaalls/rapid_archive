# Benchmark site

Runs in the browser: package:archive (pure Dart → JS) vs rapid_archive (Rust → WebAssembly)
vs the browser's CompressionStream.

```sh
dart pub get
dart compile js -O2 web/main.dart -o build/main.dart.js
# serve web/index.html next to build/main.dart.js
```
