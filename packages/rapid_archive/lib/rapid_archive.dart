/// Drop-in, Rust-powered replacements for `package:archive`'s gzip, zlib and
/// zip codecs.
///
/// Migrate by changing one import:
///
/// ```dart
/// // import 'package:archive/archive.dart';
/// import 'package:rapid_archive/rapid_archive.dart';
/// ```
///
/// `Archive` and `ArchiveFile` are re-exported from `package:archive`, so
/// existing code keeps compiling.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, CompressionType;

import 'src/bindings.dart' as ffi;

export 'package:archive/archive.dart'
    show Archive, ArchiveFile, CompressionType;
export 'src/bindings.dart' show RapidArchiveException;

/// gzip compression. Same API as `package:archive`'s `GZipEncoder`.
class GZipEncoder {
  /// With [parallel], inputs of 2 MB or more are compressed on every CPU
  /// core. The output is still one standard gzip stream, 2 to 5% larger.
  final bool parallel;
  const GZipEncoder({this.parallel = false});

  /// [level] is 0 (store) to 9 (smallest); default 6.
  Uint8List encodeBytes(List<int> bytes, {int? level}) =>
      ffi.compress(ffi.StreamFormat.gzip, bytes, level ?? -1, parallel: parallel);

  List<int> encode(List<int> bytes, {int? level}) =>
      encodeBytes(bytes, level: level);
}

/// gzip decompression. Concatenated gzip members are decoded like `gunzip`.
class GZipDecoder {
  const GZipDecoder();

  /// The CRC is always verified, so [verify] is accepted only for API
  /// compatibility.
  Uint8List decodeBytes(List<int> bytes, {bool verify = false}) =>
      ffi.decompress(ffi.StreamFormat.gzip, bytes);
}

/// zlib (RFC 1950) compression.
class ZLibEncoder {
  /// See [GZipEncoder.parallel].
  final bool parallel;
  const ZLibEncoder({this.parallel = false});

  Uint8List encodeBytes(List<int> bytes, {int? level, bool raw = false}) =>
      ffi.compress(raw ? ffi.StreamFormat.deflate : ffi.StreamFormat.zlib,
          bytes, level ?? -1, parallel: parallel);

  List<int> encode(List<int> bytes, {int? level}) =>
      encodeBytes(bytes, level: level);
}

/// zlib (RFC 1950) decompression; `raw: true` for bare deflate.
class ZLibDecoder {
  const ZLibDecoder();

  Uint8List decodeBytes(List<int> bytes, {bool verify = false, bool raw = false}) =>
      ffi.decompress(raw ? ffi.StreamFormat.deflate : ffi.StreamFormat.zlib, bytes);
}

/// Builds zip files, compressing entries in parallel on every core.
class ZipEncoder {
  const ZipEncoder();

  /// [level] is 0 to 9 (default 6). Files whose `compression` is
  /// [CompressionType.none] are stored as-is.
  Uint8List encodeBytes(Archive archive, {int? level}) {
    final files = archive.files;
    final names = BytesBuilder(copy: false);
    final table = Uint64List(files.length * 5);
    var namesLen = 0;
    var blobLen = 0;
    final contents = <Uint8List>[];
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      var name = f.name;
      final isDir = !f.isFile;
      if (isDir && !name.endsWith('/')) name = '$name/';
      final n = utf8.encode(name);
      final data = isDir ? Uint8List(0) : f.content;
      final store = f.compression == CompressionType.none;
      table[i * 5] = namesLen;
      table[i * 5 + 1] = n.length;
      table[i * 5 + 2] = blobLen;
      table[i * 5 + 3] = data.length;
      table[i * 5 + 4] = (isDir ? 1 : 0) | (store ? 2 : 0);
      names.add(n);
      contents.add(data);
      namesLen += n.length;
      blobLen += data.length;
    }
    // One contiguous blob means one native call with no per-file overhead.
    // Skip the copy when there is a single file.
    final Uint8List blob;
    if (contents.length == 1) {
      blob = contents.first;
      table[2] = 0;
    } else {
      blob = Uint8List(blobLen);
      var off = 0;
      for (final c in contents) {
        blob.setRange(off, off + c.length, c);
        off += c.length;
      }
    }
    return ffi.zipEncode(
        names.takeBytes(), blob, table, files.length, level ?? -1);
  }

  List<int> encode(Archive archive, {int? level}) =>
      encodeBytes(archive, level: level);
}

/// Reads zip files. Every entry is extracted (in parallel) during
/// [decodeBytes]; each file's content is a zero-copy view into one native
/// buffer.
class ZipDecoder {
  const ZipDecoder();

  Archive decodeBytes(List<int> bytes, {bool verify = false}) {
    final raw = ffi.zipDecode(bytes);
    final archive = Archive();
    final t = raw.table;
    for (var i = 0; i < raw.count; i++) {
      final b = i * 5;
      final name = utf8.decode(Uint8List.sublistView(
          raw.names, t[b], t[b] + t[b + 1]));
      if (t[b + 4] & 1 == 1) {
        archive.add(ArchiveFile.directory(name));
      } else {
        archive.add(ArchiveFile.bytes(
            name, Uint8List.sublistView(raw.data, t[b + 2], t[b + 2] + t[b + 3])));
      }
    }
    return archive;
  }
}
