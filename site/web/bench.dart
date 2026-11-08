// Benchmark logic, shared by the worker. No DOM access here: it runs inside
// a Web Worker so the page stays responsive even on huge inputs.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart' as rapid;
import 'package:web/web.dart' as web;

/// Largest unpacked size the browser benchmark accepts. Both libraries keep
/// everything in memory, and a browser tab has a few GB at most.
const maxBytes = 1024 * 1024 * 1024;

/// Above this, each step runs once with no warm-up.
const bigBytes = 256 * 1024 * 1024;

class Result {
  final String op;
  final String input;
  final int bytes;
  final double archiveMs;
  final double rapidMs;
  final double? browserMs;
  final bool ok;
  final String note;
  Result(this.op, this.input, this.bytes, this.archiveMs, this.rapidMs,
      {this.browserMs, this.ok = true, this.note = ''});

  Map<String, Object?> toJson() => {
        'op': op, 'input': input, 'bytes': bytes, 'archiveMs': archiveMs,
        'rapidMs': rapidMs, 'browserMs': browserMs, 'ok': ok, 'note': note,
      };
  factory Result.fromJson(Map<String, dynamic> j) => Result(
        j['op'] as String, j['input'] as String, j['bytes'] as int,
        (j['archiveMs'] as num).toDouble(), (j['rapidMs'] as num).toDouble(),
        browserMs: (j['browserMs'] as num?)?.toDouble(),
        ok: j['ok'] as bool, note: j['note'] as String,
      );
}

class Bench {
  final void Function(String msg) onStatus;
  final void Function(Result r) onResult;
  int runs;
  bool _warm = true;
  Bench(this.onStatus, this.onResult, this.runs);

  Future<void> _breathe() => Future.delayed(Duration.zero);

  Future<double> _time(FutureOr<Object?> Function() f) async {
    if (_warm) await f();
    final t = <double>[];
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await f();
      t.add(sw.elapsedMicroseconds / 1000);
      await _breathe();
    }
    t.sort();
    return t[t.length ~/ 2];
  }

  void _sizeGuard(int bytes, String what) {
    if (bytes > maxBytes) {
      throw StateError('$what is ${mb(bytes)} unpacked. The browser benchmark '
          'is limited to ${mb(maxBytes)} because everything is held in memory. '
          'Try a smaller file, or run bench/compare.sh on your Mac for big ones.');
    }
    if (bytes > bigBytes) {
      runs = 1;
      _warm = false;
      onStatus('Large input (${mb(bytes)}): running each step once, no warm-up.');
    }
  }

  Future<void> runOn(String name, Uint8List data) async {
    final lower = name.toLowerCase();
    if (isZip(data) || lower.endsWith('.zip')) {
      await _zip(name, data);
    } else if (isGzip(data) || lower.endsWith('.gz')) {
      final size = data.length >= 4
          ? ByteData.sublistView(data, data.length - 4).getUint32(0, Endian.little)
          : 0;
      _sizeGuard(max(size, data.length), name);
      await _gunzip(name, data);
    } else {
      _sizeGuard(data.length, name);
      await _file(name, data);
    }
  }

  Future<void> _file(String name, Uint8List data) async {
    onStatus('gzip: compressing $name with each library…');
    await _breathe();
    final refGz = ref.GZipEncoder().encodeBytes(data);
    final ourGz = const rapid.GZipEncoder().encodeBytes(data);
    final a = await _time(() => ref.GZipEncoder().encodeBytes(data));
    onStatus('gzip: rapid_archive compressing $name…');
    final r = await _time(() => const rapid.GZipEncoder().encodeBytes(data));
    onStatus('gzip: browser built-in compressing $name…');
    final b = await _time(() => browserGzip(data, compress: true));
    final roundTrip = same(ref.GZipDecoder().decodeBytes(ourGz), data) &&
        same(const rapid.GZipDecoder().decodeBytes(refGz), data);
    onResult(Result('gzip compress', name, data.length, a, r,
        browserMs: b,
        ok: roundTrip,
        note: 'output ${mb(refGz.length)} vs ${mb(ourGz.length)}'));
    await _gunzip(name, refGz, expected: data);
  }

  Future<void> _gunzip(String name, Uint8List gz, {Uint8List? expected}) async {
    onStatus('gzip: decompressing $name with archive…');
    await _breathe();
    final want = expected ?? ref.GZipDecoder().decodeBytes(gz);
    final a = await _time(() => ref.GZipDecoder().decodeBytes(gz));
    onStatus('gzip: decompressing $name with rapid_archive…');
    final r = await _time(() => const rapid.GZipDecoder().decodeBytes(gz));
    double? b;
    try {
      onStatus('gzip: decompressing $name with the browser built-in…');
      b = await _time(() => browserGzip(gz, compress: false));
    } catch (_) {
      b = null;
    }
    final ok = same(const rapid.GZipDecoder().decodeBytes(gz), want);
    onResult(Result('gzip decompress', name, want.length, a, r,
        browserMs: b, ok: ok));
  }

  Future<void> _zip(String name, Uint8List zip) async {
    onStatus('zip: reading the directory of $name…');
    await _breathe();
    // archive decodes lazily, so this only reads the directory.
    final reference = ref.ZipDecoder().decodeBytes(zip);
    final entries = reference.files.where((f) => f.isFile).toList();
    final total = entries.fold<int>(0, (s, f) => s + f.size);
    _sizeGuard(total, name);

    int readAll(ref.Archive a) {
      var n = 0;
      for (final f in a.files) {
        n += f.content.length;
        f.clear(); // drop each file's bytes once counted, to save memory
      }
      return n;
    }

    onStatus('zip: archive extracting ${entries.length} files (${mb(total)})…');
    await _breathe();
    final a = await _time(() => readAll(ref.ZipDecoder().decodeBytes(zip)));
    onStatus('zip: rapid_archive extracting ${entries.length} files…');
    await _breathe();
    final r = await _time(() {
      var n = 0;
      for (final f in const rapid.ZipDecoder().decodeBytes(zip).files) {
        n += f.content.length;
      }
      return n;
    });

    onStatus('zip: verifying every file byte for byte…');
    await _breathe();
    final ours = const rapid.ZipDecoder().decodeBytes(zip);
    final mine = {for (final f in ours.files) if (f.isFile) f.name: f.content};
    var ok = mine.length == entries.length;
    for (final f in ref.ZipDecoder().decodeBytes(zip).files) {
      if (!f.isFile) continue;
      final got = mine[f.name];
      if (got == null || !same(got, f.content)) {
        ok = false;
        break;
      }
      f.clear();
    }
    onResult(Result('zip extract', name, total, a, r,
        ok: ok, note: '${entries.length} files, ${mb(total)} unpacked'));

    if (entries.length > 65535 || total > bigBytes) {
      if (total > bigBytes) {
        onStatus('Skipped re-zipping: over ${mb(bigBytes)} would need too much memory.');
      }
      return;
    }
    onStatus('zip: re-zipping ${entries.length} files…');
    await _breathe();
    final archive = ref.Archive();
    mine.forEach((n, d) => archive.add(ref.ArchiveFile.bytes(n, d)));
    final za = await _time(() => ref.ZipEncoder().encodeBytes(archive));
    final zr = await _time(() => const rapid.ZipEncoder().encodeBytes(archive));
    final back = ref.ZipDecoder().decodeBytes(const rapid.ZipEncoder().encodeBytes(archive));
    final zipOk = back.files.where((f) => f.isFile).every(
        (f) => mine[f.name] != null && same(mine[f.name]!, f.content));
    onResult(Result('zip create', name, total, za, zr,
        ok: zipOk, note: '${entries.length} files'));
  }
}

bool isZip(Uint8List d) =>
    d.length > 4 && d[0] == 0x50 && d[1] == 0x4b && d[2] == 3 && d[3] == 4;
bool isGzip(Uint8List d) => d.length > 2 && d[0] == 0x1f && d[1] == 0x8b;

bool same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String mb(int b) => b >= 1048576
    ? '${(b / 1048576).toStringAsFixed(b >= 10485760 ? 0 : 1)} MB'
    : '${(b / 1024).toStringAsFixed(0)} KB';

@JS('CompressionStream')
extension type _CS._(JSObject _) implements JSObject {
  external factory _CS(String format);
}

@JS('DecompressionStream')
extension type _DS._(JSObject _) implements JSObject {
  external factory _DS(String format);
}

Future<Uint8List> browserGzip(Uint8List data, {required bool compress}) async {
  final blob = web.Blob([data.toJS].toJS);
  final stream = blob.stream().pipeThrough(
      (compress ? _CS('gzip') : _DS('gzip')) as web.ReadableWritablePair);
  final buf = await web.Response(stream).arrayBuffer().toDart;
  return buf.toDart.asUint8List();
}

Uint8List sampleJson(int bytes) {
  final r = Random(7);
  const cities = ['mumbai', 'pune', 'delhi', 'bengaluru', 'chennai', 'kolkata'];
  final sb = StringBuffer();
  var id = 0;
  while (sb.length < bytes) {
    sb.write('{"id":${id++},"user":"user${r.nextInt(100000)}","city":"'
        '${cities[r.nextInt(cities.length)]}","amount":'
        '${(r.nextDouble() * 1000).toStringAsFixed(2)},"ts":'
        '${1700000000 + r.nextInt(100000000)}}\n');
  }
  return Uint8List.fromList(utf8.encode(sb.toString()).sublist(0, bytes));
}

Uint8List sampleZip(int files, int each) {
  final pool = sampleJson(files * each + each);
  final a = ref.Archive();
  for (var i = 0; i < files; i++) {
    a.add(ref.ArchiveFile.bytes('orders/day_$i.json',
        Uint8List.sublistView(pool, i * each, i * each + each)));
  }
  return const rapid.ZipEncoder().encodeBytes(a);
}
