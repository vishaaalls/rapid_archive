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
