// Types shared by the native (FFI) and web (WebAssembly) bindings.

import 'dart:typed_data';

/// Thrown when the Rust core rejects input (corrupt data, zip bomb, ...).
class RapidArchiveException implements Exception {
  final String message;
  RapidArchiveException(this.message);
  @override
  String toString() => 'RapidArchiveException: $message';
}

/// A `List<int>` has no native address, so copy it once if needed.
Uint8List asBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

/// Stream formats understood by the core (order matches the Rust side).
enum StreamFormat { gzip, zlib, deflate }

/// Raw result of decoding a zip: three GC-owned native buffers.
class RawZip {
  final int count;
  final Uint8List data;
  final Uint8List names;
  /// Five values per entry: name offset, name length, data offset, data
  /// length, flags (bit 0 = directory).
  final List<int> table;
  RawZip(this.count, this.data, this.names, this.table);
}
