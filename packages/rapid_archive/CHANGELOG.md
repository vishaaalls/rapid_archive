## 0.2.2

- Fix: bytes returned by the encoders and decoders (gzip, zlib, raw
  deflate, zip, and the contents of a decoded zip) were Rust-owned memory
  freed by a native finalizer. Returned from `Isolate.run` or Flutter's
  `compute`, which hand results over without copying and then shut the
  worker isolate down, they arrived corrupted. They are now ordinary Dart
  `Uint8List`s: a memcpy (64 MB gunzip 48.5 to 51.3 ms, 64 MB zip extract
  11.8 to 14.8 ms on an Apple M4; compression unchanged). The native code is
  unchanged.

## 0.2.1

- Web: much faster when built with dart2wasm (bulk copies into and out of
  WebAssembly memory).

## 0.2.0

- Streaming with constant memory: `encodeStream`, `decodeStream` and
  `transformer()` on `GZipEncoder`, `GZipDecoder`, `ZLibEncoder` and
  `ZLibDecoder` (also on web). Parallel encoders use every core.
- New `package:rapid_archive/rapid_archive_io.dart` (not on web), like
  `archive_io.dart`: `gzipFile`, `gunzipFile`, `extractFileToDisk` and
  `ZipFileEncoder.zipDirectory`. Each runs in a background isolate.
- zip64: archives and entries over 4 GB, and more than 65,535 entries.
- `extractFileToDisk` checks every CRC and size and refuses "zip slip"
  entry names.

## 0.1.0

- gzip, zlib and raw deflate with libdeflate; parallel gzip/zlib.
- Zip create and extract, entries compressed and extracted in parallel.
- Web support through WebAssembly.
- Prebuilt native libraries for Android, iOS, macOS, Linux and Windows,
  downloaded and checksum-verified by the build hook.
