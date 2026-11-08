// Compare rapid_archive with package:archive on your own files.
//
//   bench/compare.sh <path> [<path> ...] [--runs N] [--level N]
//
// What each kind of path does:
//   a file        gzip it and gunzip it with both libraries
//   a folder      zip it, then extract that zip, with both libraries
//   a .zip file   extract it with both libraries
//
// Every result is checked byte for byte against the original, and the
// rapid_archive outputs are written to ./compare_out so you can open them.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart' as rapid;

var runs = 3;
int? level;
final outDir = Directory('compare_out');

double timeMs(void Function() f) {
  f(); // warm up
  final t = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    t.add(sw.elapsedMicroseconds / 1000);
  }
  t.sort();
  return t[runs ~/ 2];
}

String mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
String ms(double v) =>
    v >= 1000 ? '${(v / 1000).toStringAsFixed(2)} s' : '${v.toStringAsFixed(1)} ms';

void row(String op, double a, double b, [String note = '']) {
  stdout.writeln('  ${op.padRight(26)} archive ${ms(a).padLeft(10)}   '
      'rapid ${ms(b).padLeft(10)}   ${(a / b).toStringAsFixed(1).padLeft(5)}x faster'
      '${note.isEmpty ? '' : '   $note'}');
}

bool same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void check(bool ok, String what) {
  stdout.writeln('  ${ok ? 'OK  ' : 'FAIL'} $what');
  if (!ok) exitCode = 1;
}

String baseName(String p) =>
    p.replaceAll(RegExp(r'/+$'), '').split(Platform.pathSeparator).last;

void compareFile(File f) {
  final data = f.readAsBytesSync();
  stdout.writeln('\n${f.path}  (${mb(data.length)}, gzip)');

  final refGz = ref.GZipEncoder().encodeBytes(data, level: level);
  final ourGz = const rapid.GZipEncoder().encodeBytes(data, level: level);
  final parGz =
      const rapid.GZipEncoder(parallel: true).encodeBytes(data, level: level);
  row('gzip compress', timeMs(() => ref.GZipEncoder().encodeBytes(data, level: level)),
      timeMs(() => const rapid.GZipEncoder().encodeBytes(data, level: level)),
      'size ${mb(refGz.length)} vs ${mb(ourGz.length)}');
  row('gzip compress (parallel)',
      timeMs(() => ref.GZipEncoder().encodeBytes(data, level: level)),
      timeMs(() =>
          const rapid.GZipEncoder(parallel: true).encodeBytes(data, level: level)),
      'size ${mb(refGz.length)} vs ${mb(parGz.length)}');
  row('gzip decompress', timeMs(() => ref.GZipDecoder().decodeBytes(refGz)),
      timeMs(() => const rapid.GZipDecoder().decodeBytes(refGz)));

  check(same(const rapid.GZipDecoder().decodeBytes(refGz), data),
      'rapid_archive restores the original from archive\'s .gz');
  check(same(ref.GZipDecoder().decodeBytes(ourGz), data),
      'archive restores the original from rapid_archive\'s .gz');
  check(same(ref.GZipDecoder().decodeBytes(parGz), data),
      'archive restores the original from the parallel .gz');

  final out = File('${outDir.path}/${baseName(f.path)}.gz')..writeAsBytesSync(ourGz);
  stdout.writeln('  wrote ${out.path}');
}

void compareFolder(Directory d) {
  final root = d.absolute.path.replaceAll(RegExp(r'/+$'), '');
  final archive = ref.Archive();
  final originals = <String, Uint8List>{};
  var total = 0;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final name = e.absolute.path.substring(root.length + 1);
    if (name.split('/').any((p) => p.startsWith('.'))) continue; // skip hidden
    final bytes = e.readAsBytesSync();
    originals[name] = bytes;
    archive.add(ref.ArchiveFile.bytes(name, bytes));
    total += bytes.length;
  }
  stdout.writeln('\n${d.path}  (${originals.length} files, ${mb(total)}, zip)');
  if (originals.length > 65535) {
    stdout.writeln('  skipped: more than 65,535 files needs zip64 (not supported yet)');
    return;
  }

  final refZip = ref.ZipEncoder().encodeBytes(archive, level: level ?? 6);
  final ourZip = const rapid.ZipEncoder().encodeBytes(archive, level: level);
  row('zip create', timeMs(() => ref.ZipEncoder().encodeBytes(archive, level: level ?? 6)),
      timeMs(() => const rapid.ZipEncoder().encodeBytes(archive, level: level)),
      'size ${mb(refZip.length)} vs ${mb(ourZip.length)}');
  _extract(refZip, originals);

  check(_matches(ref.ZipDecoder().decodeBytes(ourZip), originals),
      'archive extracts rapid_archive\'s zip to the original files');
  check(_matches(const rapid.ZipDecoder().decodeBytes(refZip), originals),
      'rapid_archive extracts archive\'s zip to the original files');

  final out = File('${outDir.path}/${baseName(d.path)}.zip')..writeAsBytesSync(ourZip);
  stdout.writeln('  wrote ${out.path} (open it in Finder to check)');
}

void compareZip(File f) {
  final zip = f.readAsBytesSync();
  final reference = ref.ZipDecoder().decodeBytes(zip);
  final originals = <String, Uint8List>{
    for (final e in reference.files)
      if (e.isFile) e.name: e.content,
  };
  stdout.writeln('\n${f.path}  (${mb(zip.length)}, ${originals.length} files, '
      'extract)');
  _extract(zip, originals);
  check(_matches(const rapid.ZipDecoder().decodeBytes(zip), originals),
      'rapid_archive extracts the same files as archive');
}

void _extract(Uint8List zip, Map<String, Uint8List> originals) {
  int readAll(ref.Archive a) {
    var n = 0;
    for (final f in a.files) {
      n += f.content.length; // archive decodes lazily: force it
    }
    return n;
  }

  row('zip extract all', timeMs(() => readAll(ref.ZipDecoder().decodeBytes(zip))),
      timeMs(() => readAll(const rapid.ZipDecoder().decodeBytes(zip))));
}

bool _matches(ref.Archive a, Map<String, Uint8List> originals) {
  final got = {for (final f in a.files) if (f.isFile) f.name: f.content};
  if (got.length != originals.length) return false;
  for (final e in originals.entries) {
    final g = got[e.key];
    if (g == null || !same(g, e.value)) return false;
  }
  return true;
}

void main(List<String> args) {
  final paths = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--runs':
        runs = int.parse(args[++i]);
      case '--level':
        level = int.parse(args[++i]);
      default:
        paths.add(args[i]);
    }
  }
  if (paths.isEmpty) {
    stderr.writeln('usage: bench/compare.sh <file|folder|file.zip> ... '
        '[--runs N] [--level 0-9]');
    exit(64);
  }
  outDir.createSync(recursive: true);
  stdout.writeln('Median of $runs runs, level ${level ?? 6}, '
      '${Platform.numberOfProcessors} cores');
  for (final p in paths) {
    final type = FileSystemEntity.typeSync(p);
    try {
      if (type == FileSystemEntityType.directory) {
        compareFolder(Directory(p));
      } else if (type == FileSystemEntityType.file) {
        p.toLowerCase().endsWith('.zip') ? compareZip(File(p)) : compareFile(File(p));
      } else {
        stdout.writeln('\n$p: not found');
        exitCode = 1;
      }
    } on rapid.RapidArchiveException catch (e) {
      stdout.writeln('  rapid_archive could not handle this: ${e.message}');
      exitCode = 1;
    }
  }
}
