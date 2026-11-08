// Benchmark: rapid_archive (Rust) vs package:archive.
//
// package:archive on the Dart VM / Flutter mobile+desktop already uses the
// C zlib built into dart:io for deflate. Its pure-Dart codec (GZipEncoderWeb
// / GZipDecoderWeb) is what Flutter web runs, so it's measured too.
//
// Run: dart build cli -t bench/bench.dart && ./build/cli/<os>_<arch>/bundle/bin/bench
//
// Options:
//   --mb N       size of each test input in MB (default 16)
//   --runs N     timed runs per measurement, median reported (default 7)
//   --file PATH  also gzip/gunzip one of your own files
//   --pure       also time archive's pure-Dart (web) codec; slow on big inputs

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart' as rapid;

var runs = 7;

double timeMs(void Function() f) {
  f();
  f(); // warm up
  final t = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    f();
    t.add(sw.elapsedMicroseconds / 1000);
  }
  t.sort();
  return t[runs ~/ 2]; // median
}

Uint8List jsonLike(int bytes, Random r) {
  final words = ['alpha', 'beta', 'gamma', 'delta', 'user', 'order', 'status',
      'pending', 'shipped', 'price', 'qty', 'sku', 'warehouse', 'mumbai', 'pune'];
  final sb = StringBuffer();
  var id = 0;
  while (sb.length < bytes) {
    sb.write('{"id":${id++},"ts":${1700000000 + r.nextInt(99999999)},'
        '"${words[r.nextInt(words.length)]}":"${words[r.nextInt(words.length)]}'
        '-${r.nextInt(100000)}","amount":${r.nextDouble().toStringAsFixed(4)}}\n');
  }
  return Uint8List.fromList(utf8.encode(sb.toString()).sublist(0, bytes));
}

Uint8List random(int bytes, Random r) =>
    Uint8List.fromList(List.generate(bytes, (_) => r.nextInt(256)));

final rows = <List<String>>[];

void row(String op, String data, double refMs, double rapidMs,
    {double? pureDartMs}) {
  final speedup = refMs / rapidMs;
  rows.add([
    op,
    data,
    '${refMs.toStringAsFixed(1)} ms',
    pureDartMs == null ? '-' : '${pureDartMs.toStringAsFixed(1)} ms',
    '${rapidMs.toStringAsFixed(1)} ms',
    '${speedup.toStringAsFixed(1)}x',
    pureDartMs == null ? '-' : '${(pureDartMs / rapidMs).toStringAsFixed(0)}x',
  ]);
  stdout.writeln(rows.last.join(' | '));
}

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void main(List<String> args) {
  final size = int.parse(_opt(args, '--mb') ?? '16');
  runs = int.parse(_opt(args, '--runs') ?? '7');
  final file = _opt(args, '--file');
  final withPure = args.contains('--pure') || size <= 16;
  final r = Random(42);
  const mb = 1024 * 1024;
  stdout.writeln('Generating ${size} MB test inputs...');
  final text = jsonLike(size * mb, r);
  final noise = random(size * mb, r);

  stdout.writeln('op | data | archive (native zlib) | archive (pure Dart, = web) '
      '| rapid_archive | vs archive | vs pure Dart');

  final inputs = [('$size MB JSON', text), ('$size MB random', noise)];
  if (file != null) {
    final f = File(file).readAsBytesSync();
    inputs.add(('${file.split('/').last} (${f.length ~/ mb} MB)', f));
  }
  for (final (label, data) in inputs) {
    final refGz = ref.GZipEncoder().encodeBytes(data);
    final rapidGz = const rapid.GZipEncoder().encodeBytes(data);
    // Sanity: each side can read the other's output.
    assert(rapid.GZipDecoder().decodeBytes(refGz).length == data.length);

    final pure = withPure && label.contains('JSON')
        ? timeMs(() => ref.GZipEncoderWeb().encodeBytes(data))
        : null;
    row('gzip compress', label,
        timeMs(() => ref.GZipEncoder().encodeBytes(data)),
        timeMs(() => const rapid.GZipEncoder().encodeBytes(data)),
        pureDartMs: pure);
    final parGz = const rapid.GZipEncoder(parallel: true).encodeBytes(data);
    row('gzip compress (parallel)', label,
        timeMs(() => ref.GZipEncoder().encodeBytes(data)),
        timeMs(() => const rapid.GZipEncoder(parallel: true).encodeBytes(data)));
    stdout.writeln('   output size: archive ${refGz.length} B, rapid '
        '${rapidGz.length} B, rapid parallel ${parGz.length} B');

    final pureD = withPure && label.contains('JSON')
        ? timeMs(() => ref.GZipDecoderWeb().decodeBytes(refGz))
        : null;
    row('gzip decompress', label,
        timeMs(() => ref.GZipDecoder().decodeBytes(refGz)),
        timeMs(() => const rapid.GZipDecoder().decodeBytes(refGz)),
        pureDartMs: pureD);
  }

  // Zip: many small files (typical "zip a folder of JSON/logs/assets").
  for (final (label, n, size) in [
    // Capped below 65,535 entries: zip64 writing isn't supported yet.
    ('${min(size * 128, 60000)} files x 8 KB', min(size * 128, 60000), 8 * 1024),
    ('8 files x ${size ~/ 4} MB', 8, (size ~/ 4) * mb),
  ]) {
    final archive = ref.Archive();
    for (var i = 0; i < n; i++) {
      final off = r.nextInt(text.length - size);
      archive.add(ref.ArchiveFile.bytes(
          'data/file_$i.json', Uint8List.sublistView(text, off, off + size)));
    }
    final refZip = ref.ZipEncoder().encodeBytes(archive);
    row('zip create', label,
        timeMs(() => ref.ZipEncoder().encodeBytes(archive)),
        timeMs(() => const rapid.ZipEncoder().encodeBytes(archive)));

    // Extract everything (archive decodes lazily, so read every file).
    int readAllRef() {
      var t = 0;
      for (final f in ref.ZipDecoder().decodeBytes(refZip).files) {
        t += f.content.length;
      }
      return t;
    }

    int readAllRapid() {
      var t = 0;
      for (final f in const rapid.ZipDecoder().decodeBytes(refZip).files) {
        t += f.content.length;
      }
      return t;
    }

    if (readAllRef() != readAllRapid()) throw StateError('zip mismatch');
    row('zip extract all', label, timeMs(readAllRef), timeMs(readAllRapid));
  }

  stdout.writeln('\nCPU cores: ${Platform.numberOfProcessors}, '
      '${Platform.operatingSystem} ${Platform.version.split(' ').first}');
}
