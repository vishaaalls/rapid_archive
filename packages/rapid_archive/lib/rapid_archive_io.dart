/// File and folder helpers that work with constant memory, like
/// `package:archive`'s `archive_io.dart`. Not available on web.
///
/// ```dart
/// // import 'package:archive/archive_io.dart';
/// import 'package:rapid_archive/rapid_archive_io.dart';
///
/// await extractFileToDisk('photos.zip', 'out/photos');
/// await ZipFileEncoder().zipDirectory(Directory('out/photos'));
/// ```
///
/// Every function runs in a background isolate, so it never blocks the UI,
/// and the work itself runs on every CPU core where it can. Memory use does
/// not depend on the file size: zips over 4 GB (zip64) and gzip files of any
/// size are fine.
library;

import 'dart:io';
import 'dart:isolate';

import 'rapid_archive.dart';
import 'src/bindings_ffi.dart' show StreamFormat;
import 'src/files_ffi.dart' as files;

export 'rapid_archive.dart';

/// Compresses the file at [input] to the gzip file [output]. With
/// [parallel] (the default), it uses every core; the output is one standard
/// gzip stream.
Future<void> gzipFile(String input, String output,
    {int? level, bool parallel = true}) {
  final l = level ?? -1;
  return Isolate.run(
      () => files.compressFile(StreamFormat.gzip, input, output, l, parallel));
}

/// Decompresses the gzip file at [input] to [output]. Returns the number of
/// bytes written. Concatenated members are decoded like `gunzip`.
Future<int> gunzipFile(String input, String output) =>
    Isolate.run(() => files.decompressFile(StreamFormat.gzip, input, output));

/// Extracts the zip file at [inputPath] into the folder [outputPath]
/// (created if needed). Entries are written in parallel; large entries are
/// streamed. Every CRC is checked, and entries whose names would land outside
/// [outputPath] ("zip slip") are refused.
///
/// Unlike `package:archive`, only zip files are supported.
Future<void> extractFileToDisk(String inputPath, String outputPath) =>
    Isolate.run(() => files.extractZip(inputPath, outputPath));

/// Writes zip files from folders on disk.
///
/// Only [zipDirectory] from `package:archive`'s `ZipFileEncoder` is
/// provided. For other cases, build an `Archive` and use [ZipEncoder].
class ZipFileEncoder {
  /// Zips every file and folder in [dir] (names are relative to [dir];
  /// symbolic links are followed) to [filename], by default `<dir>.zip`.
  /// [level] is 0 to 9 (default 6). Small files are compressed in parallel
  /// batches and large files are streamed, so memory stays bounded.
  Future<void> zipDirectory(Directory dir, {String? filename, int? level}) {
    final d = dir.path;
    final z = filename ?? '$d.zip';
    final l = level ?? -1;
    return Isolate.run(() => files.zipDirectory(d, z, l));
  }

  /// Same as [zipDirectory].
  Future<void> zipDirectoryAsync(Directory dir, {String? filename, int? level}) =>
      zipDirectory(dir, filename: filename, level: level);
}
