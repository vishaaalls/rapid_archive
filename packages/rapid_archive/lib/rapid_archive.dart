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

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, CompressionType;

import 'src/bindings.dart' as ffi;

export 'package:archive/archive.dart'
    show Archive, ArchiveFile, CompressionType;
export 'src/bindings.dart' show RapidArchiveException;

/// Prepares the library. On web this compiles the WebAssembly module, so call
/// and await it once at startup (for example in `main()`). On every other
/// platform it returns immediately.
Future<void> ensureRapidArchiveInitialized() => ffi.ensureInitialized();

/// Runs [input] through one native streaming codec with constant memory.
/// The native handle is released when the stream ends, fails or is
/// cancelled.
Stream<Uint8List> _pipe(Stream<List<int>> input, bool decode,
    ffi.StreamFormat f, int level, bool parallel) async* {
  final h = ffi.streamNew(decode, f, level, parallel);
  try {
    // Bound the work (and output) of each native call. Decoding uses small
    // steps because 64 KiB can inflate to many megabytes.
    final step = decode ? 1 << 16 : 1 << 22;
    await for (final event in input) {
      final b = ffi.asBytes(event);
      for (var o = 0; o < b.length; o += step) {
        final out = ffi.streamPush(
            h, Uint8List.sublistView(b, o, math.min(o + step, b.length)), false);
        if (out.isNotEmpty) yield out;
      }
    }
    final out = ffi.streamPush(h, Uint8List(0), true);
    if (out.isNotEmpty) yield out;
  } finally {
    ffi.streamFree(h);
  }
}

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

  /// Fastest gzip on every platform. On web it uses the browser's built-in
  /// CompressionStream (when [level] is left at the default), and natively
  /// it uses every CPU core.
  Future<Uint8List> encodeBytesAsync(List<int> bytes, {int? level}) =>
      ffi.compressAsync(ffi.StreamFormat.gzip, bytes, level ?? -1);

  /// Compresses a stream of any size with constant memory. The output is
  /// one standard gzip stream. With [parallel], each window of input
  /// (2 MiB per core) is compressed on every core.
  ///
  /// ```dart
  /// await File('big.log').openRead()
  ///     .transform(const GZipEncoder(parallel: true).transformer())
  ///     .pipe(File('big.log.gz').openWrite());
  /// ```
  Stream<Uint8List> encodeStream(Stream<List<int>> input, {int? level}) =>
      _pipe(input, false, ffi.StreamFormat.gzip, level ?? -1, parallel);

  /// [encodeStream] as a `StreamTransformer`, for `Stream.transform`.
  StreamTransformer<List<int>, List<int>> transformer({int? level}) =>
      StreamTransformer.fromBind(
          (s) => encodeStream(s, level: level).cast<List<int>>());
}

/// gzip decompression. Concatenated gzip members are decoded like `gunzip`.
class GZipDecoder {
  const GZipDecoder();

  /// The CRC is always verified, so [verify] is accepted only for API
  /// compatibility.
  Uint8List decodeBytes(List<int> bytes, {bool verify = false}) =>
      ffi.decompress(ffi.StreamFormat.gzip, bytes);

  /// Fastest gunzip on every platform (browser built-in on web).
  Future<Uint8List> decodeBytesAsync(List<int> bytes) =>
      ffi.decompressAsync(ffi.StreamFormat.gzip, bytes);

  /// Decompresses a gzip stream of any size with constant memory.
  /// Concatenated members are decoded like `gunzip`. A truncated or corrupt
  /// stream is an error.
  Stream<Uint8List> decodeStream(Stream<List<int>> input) =>
      _pipe(input, true, ffi.StreamFormat.gzip, 0, false);

  /// [decodeStream] as a `StreamTransformer`, for `Stream.transform`.
  StreamTransformer<List<int>, List<int>> transformer() =>
      StreamTransformer.fromBind((s) => decodeStream(s).cast<List<int>>());
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

  /// Compresses a stream of any size with constant memory. See
  /// [GZipEncoder.encodeStream].
  Stream<Uint8List> encodeStream(Stream<List<int>> input,
          {int? level, bool raw = false}) =>
      _pipe(input, false, raw ? ffi.StreamFormat.deflate : ffi.StreamFormat.zlib,
          level ?? -1, parallel);

  /// [encodeStream] as a `StreamTransformer`, for `Stream.transform`.
  StreamTransformer<List<int>, List<int>> transformer(
          {int? level, bool raw = false}) =>
      StreamTransformer.fromBind(
          (s) => encodeStream(s, level: level, raw: raw).cast<List<int>>());
}

/// zlib (RFC 1950) decompression; `raw: true` for bare deflate.
class ZLibDecoder {
  const ZLibDecoder();

  Uint8List decodeBytes(List<int> bytes, {bool verify = false, bool raw = false}) =>
      ffi.decompress(raw ? ffi.StreamFormat.deflate : ffi.StreamFormat.zlib, bytes);

  /// Decompresses a stream of any size with constant memory.
  Stream<Uint8List> decodeStream(Stream<List<int>> input, {bool raw = false}) =>
      _pipe(input, true, raw ? ffi.StreamFormat.deflate : ffi.StreamFormat.zlib,
          0, false);

  /// [decodeStream] as a `StreamTransformer`, for `Stream.transform`.
  StreamTransformer<List<int>, List<int>> transformer({bool raw = false}) =>
      StreamTransformer.fromBind(
          (s) => decodeStream(s, raw: raw).cast<List<int>>());
}

/// Builds zip files, compressing entries in parallel on every core.
class ZipEncoder {
  const ZipEncoder();

  /// [level] is 0 to 9 (default 6). Files whose `compression` is
  /// [CompressionType.none] are stored as-is.
  Uint8List encodeBytes(Archive archive, {int? level}) {
    final files = archive.files;
    final names = BytesBuilder(copy: false);
    final table = List<int>.filled(files.length * 5, 0);
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
