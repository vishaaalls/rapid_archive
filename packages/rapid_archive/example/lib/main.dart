// On-device benchmark: rapid_archive (Rust) vs archive (pure Dart).
// Runs each benchmark in a background isolate so the UI stays responsive.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:flutter/material.dart';
import 'package:rapid_archive/rapid_archive.dart' as rapid;

void main() => runApp(const BenchApp());

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'rapid_archive benchmark',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const BenchPage(),
      );
}

class Row3 {
  final String op;
  final double archiveMs;
  final double rapidMs;
  final bool ok;
  Row3(this.op, this.archiveMs, this.rapidMs, this.ok);
}

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});
  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  final rows = <Row3>[];
  bool busy = false;
  int mb = 32;
  String status = 'Tap Run to compare on this device.';

  Future<void> run() async {
    setState(() {
      busy = true;
      rows.clear();
      status = 'Running with $mb MB of JSON…';
    });
    try {
      final out = await Isolate.run(() => runAll(mb));
      setState(() {
        rows.addAll(out.map((m) => Row3(m['op'] as String,
            m['a'] as double, m['r'] as double, m['ok'] as bool)));
        status = 'Done. Median of 3 runs per step.';
      });
    } catch (e) {
      setState(() => status = 'Failed: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('rapid_archive benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            const Text('Input size: '),
            DropdownButton<int>(
              value: mb,
              items: [8, 32, 64, 128]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v MB')))
                  .toList(),
              onChanged: busy ? null : (v) => setState(() => mb = v!),
            ),
            const Spacer(),
            FilledButton(
                key: const Key('run'),
                onPressed: busy ? null : run,
                child: const Text('Run')),
          ]),
          const SizedBox(height: 8),
          Text(status, key: const Key('status')),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 12),
          for (final r in rows)
            Card(
              child: ListTile(
                title: Text(r.op),
                subtitle: Text('archive ${r.archiveMs.toStringAsFixed(0)} ms · '
                    'rapid_archive ${r.rapidMs.toStringAsFixed(0)} ms'
                    '${r.ok ? '' : ' · OUTPUT MISMATCH'}'),
                trailing: Text(
                    '${(r.archiveMs / r.rapidMs).toStringAsFixed(1)}×',
                    style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Benchmark logic (runs inside an isolate). Also printed to the console, so
// `flutter run` / integration logs show the numbers.

double _time(Object? Function() f) {
  f(); // warm-up
  final t = <double>[];
  for (var i = 0; i < 3; i++) {
    final sw = Stopwatch()..start();
    f();
    t.add(sw.elapsedMicroseconds / 1000);
  }
  t.sort();
  return t[1];
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _json(int bytes) {
  final r = Random(7);
  const cities = ['mumbai', 'pune', 'delhi', 'bengaluru', 'chennai'];
  final sb = StringBuffer();
  var id = 0;
  while (sb.length < bytes) {
    sb.write('{"id":${id++},"user":"user${r.nextInt(100000)}","city":"'
        '${cities[r.nextInt(cities.length)]}","amount":'
        '${(r.nextDouble() * 1000).toStringAsFixed(2)}}\n');
  }
  return Uint8List.fromList(utf8.encode(sb.toString()).sublist(0, bytes));
}

List<Map<String, Object>> runAll(int mb) {
  final data = _json(mb << 20);
  final out = <Map<String, Object>>[];
  void add(String op, double a, double r, bool ok) {
    out.add({'op': op, 'a': a, 'r': r, 'ok': ok});
    // ignore: avoid_print
    print('BENCH $op: archive ${a.toStringAsFixed(1)} ms, rapid '
        '${r.toStringAsFixed(1)} ms, ${(a / r).toStringAsFixed(1)}x, ok=$ok');
  }

  final refGz = ref.GZipEncoder().encodeBytes(data);
  final ourGz = const rapid.GZipEncoder().encodeBytes(data);
  add(
      'gzip compress',
      _time(() => ref.GZipEncoder().encodeBytes(data)),
      _time(() => const rapid.GZipEncoder().encodeBytes(data)),
      _same(ref.GZipDecoder().decodeBytes(ourGz), data));
  add(
      'gzip compress (parallel)',
      _time(() => ref.GZipEncoder().encodeBytes(data)),
      _time(() => const rapid.GZipEncoder(parallel: true).encodeBytes(data)),
      _same(ref.GZipDecoder().decodeBytes(
          const rapid.GZipEncoder(parallel: true).encodeBytes(data)), data));
  add(
      'gzip decompress',
      _time(() => ref.GZipDecoder().decodeBytes(refGz)),
      _time(() => const rapid.GZipDecoder().decodeBytes(refGz)),
      _same(const rapid.GZipDecoder().decodeBytes(refGz), data));

  // A zip of 16 KB JSON files.
  const each = 16 * 1024;
  final files = min(data.length ~/ each, 8000);
  final archive = ref.Archive();
  for (var i = 0; i < files; i++) {
    archive.add(ref.ArchiveFile.bytes('orders/day_$i.json',
        Uint8List.sublistView(data, i * each, i * each + each)));
  }
  final zip = ref.ZipEncoder().encodeBytes(archive);
  add(
      'zip create ($files files)',
      _time(() => ref.ZipEncoder().encodeBytes(archive)),
      _time(() => const rapid.ZipEncoder().encodeBytes(archive)),
      true);
  int readRef() {
    var n = 0;
    for (final f in ref.ZipDecoder().decodeBytes(zip).files) {
      n += f.content.length;
    }
    return n;
  }

  int readOurs() {
    var n = 0;
    for (final f in const rapid.ZipDecoder().decodeBytes(zip).files) {
      n += f.content.length;
    }
    return n;
  }

  add('zip extract ($files files)', _time(readRef), _time(readOurs),
      readRef() == readOurs());
  return out;
}
