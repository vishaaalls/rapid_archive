// Browser benchmark: package:archive (pure Dart, compiled to JS) vs
// rapid_archive (Rust compiled to WebAssembly) vs the browser's own
// CompressionStream. Everything runs locally; no file leaves the page.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart' as rapid;
import 'package:web/web.dart' as web;

class Result {
  final String op;
  final String input;
  final int bytes; // bytes processed, for MB/s
  final double archiveMs;
  final double rapidMs;
  final double? browserMs;
  final bool ok;
  final String note;
  Result(this.op, this.input, this.bytes, this.archiveMs, this.rapidMs,
      {this.browserMs, this.ok = true, this.note = ''});
}

final results = <Result>[];
var runs = 3;
var busy = false;

web.Element $(String id) => web.document.getElementById(id)!;

void status(String msg, {bool error = false}) {
  final s = $('status');
  s.textContent = msg;
  s.className = error ? 'status error' : 'status';
}

Future<void> breathe() => Future.delayed(const Duration(milliseconds: 16));

Future<double> time(FutureOr<Object?> Function() f) async {
  await f(); // warm up
  final t = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    await f();
    t.add(sw.elapsedMicroseconds / 1000);
    await breathe();
  }
  t.sort();
  return t[t.length ~/ 2];
}

bool same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Browser built-in gzip (CompressionStream / DecompressionStream)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

Future<void> benchFile(String name, Uint8List data) async {
  status('gzip: compressing $name with each library…');
  await breathe();
  final refGz = ref.GZipEncoder().encodeBytes(data);
  final ourGz = const rapid.GZipEncoder().encodeBytes(data);
  final a = await time(() => ref.GZipEncoder().encodeBytes(data));
  final r = await time(() => const rapid.GZipEncoder().encodeBytes(data));
  final b = await time(() => browserGzip(data, compress: true));
  final roundTrip = same(ref.GZipDecoder().decodeBytes(ourGz), data) &&
      same(const rapid.GZipDecoder().decodeBytes(refGz), data);
  results.add(Result('gzip compress', name, data.length, a, r,
      browserMs: b,
      ok: roundTrip,
      note: 'output ${mb(refGz.length)} vs ${mb(ourGz.length)}'));
  render();
  await benchGunzip(name, refGz, expected: data);
}

Future<void> benchGunzip(String name, Uint8List gz, {Uint8List? expected}) async {
  status('gzip: decompressing $name…');
  await breathe();
  final want = expected ?? ref.GZipDecoder().decodeBytes(gz);
  final a = await time(() => ref.GZipDecoder().decodeBytes(gz));
  final r = await time(() => const rapid.GZipDecoder().decodeBytes(gz));
  double? b;
  try {
    b = await time(() => browserGzip(gz, compress: false));
  } catch (_) {
    b = null; // e.g. multi-member gzip in some browsers
  }
  final ok = same(const rapid.GZipDecoder().decodeBytes(gz), want);
  results.add(Result('gzip decompress', name, want.length, a, r,
      browserMs: b, ok: ok));
  render();
}

Future<void> benchZip(String name, Uint8List zip) async {
  status('zip: reading $name…');
  await breathe();
  final reference = ref.ZipDecoder().decodeBytes(zip);
  final files = <String, Uint8List>{
    for (final f in reference.files)
      if (f.isFile) f.name: f.content,
  };
  final total = files.values.fold<int>(0, (s, f) => s + f.length);

  int readAll(ref.Archive a) {
    var n = 0;
    for (final f in a.files) {
      n += f.content.length; // archive decodes lazily
    }
    return n;
  }

  status('zip: extracting ${files.length} files from $name…');
  await breathe();
  final a = await time(() => readAll(ref.ZipDecoder().decodeBytes(zip)));
  final r = await time(() => readAll(const rapid.ZipDecoder().decodeBytes(zip)));
  final ours = const rapid.ZipDecoder().decodeBytes(zip);
  var ok = true;
  var count = 0;
  for (final f in ours.files) {
    if (!f.isFile) continue;
    count++;
    final want = files[f.name];
    if (want == null || !same(want, f.content)) ok = false;
  }
  ok = ok && count == files.length;
  results.add(Result('zip extract', name, total, a, r,
      ok: ok, note: '${files.length} files, ${mb(total)} unpacked'));
  render();

  if (files.length > 65535) return;
  status('zip: re-zipping ${files.length} files…');
  await breathe();
  final archive = ref.Archive();
  files.forEach((n, d) => archive.add(ref.ArchiveFile.bytes(n, d)));
  final za = await time(() => ref.ZipEncoder().encodeBytes(archive));
  final zr = await time(() => const rapid.ZipEncoder().encodeBytes(archive));
  final ourZip = const rapid.ZipEncoder().encodeBytes(archive);
  final back = ref.ZipDecoder().decodeBytes(ourZip);
  final zipOk = back.files.where((f) => f.isFile).every(
      (f) => files[f.name] != null && same(files[f.name]!, f.content));
  results.add(Result('zip create', name, total, za, zr,
      ok: zipOk, note: '${files.length} files'));
  render();
}

Future<void> run(String name, Uint8List data) async {
  if (busy) return;
  busy = true;
  setButtons(false);
  try {
    final lower = name.toLowerCase();
    if (isZip(data) || lower.endsWith('.zip')) {
      await benchZip(name, data);
    } else if (isGzip(data) || lower.endsWith('.gz')) {
      await benchGunzip(name, data);
    } else {
      await benchFile(name, data);
    }
    status('Done. Median of $runs runs per step.');
  } on rapid.RapidArchiveException catch (e) {
    status('rapid_archive could not read $name: ${e.message}', error: true);
  } catch (e) {
    status('Could not benchmark $name: $e', error: true);
  } finally {
    busy = false;
    setButtons(true);
  }
}

bool isZip(Uint8List d) =>
    d.length > 4 && d[0] == 0x50 && d[1] == 0x4b && d[2] == 3 && d[3] == 4;
bool isGzip(Uint8List d) => d.length > 2 && d[0] == 0x1f && d[1] == 0x8b;

// ---------------------------------------------------------------------------
// Sample data
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

String mb(int b) => b >= 1048576
    ? '${(b / 1048576).toStringAsFixed(1)} MB'
    : '${(b / 1024).toStringAsFixed(0)} KB';
String ms(double v) =>
    v >= 1000 ? '${(v / 1000).toStringAsFixed(2)} s' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';
String rate(int bytes, double ms) =>
    '${(bytes / 1048576 / (ms / 1000)).toStringAsFixed(0)} MB/s';
String esc(String s) => const HtmlEscape().convert(s);

void render() {
  final list = $('results');
  if (results.isEmpty) return;
  $('example-note').toggleAttribute('hidden', true);
  final sb = StringBuffer();
  for (final r in results.reversed) {
    final slowest = [r.archiveMs, r.rapidMs, if (r.browserMs != null) r.browserMs!]
        .reduce(max);
    String bar(String cls, String label, double v) => '''
      <div class="bar-row">
        <span class="bar-label">$label</span>
        <span class="bar-track"><span class="bar $cls" style="width:${(v / slowest * 100).clamp(1, 100).toStringAsFixed(1)}%"></span></span>
        <span class="bar-value">${ms(v)}<small>${rate(r.bytes, v)}</small></span>
      </div>''';
    final speed = r.archiveMs / r.rapidMs;
    sb.write('''
    <article class="result">
      <header>
        <div>
          <h3>${esc(r.op)}</h3>
          <p class="meta">${esc(r.input)} · ${mb(r.bytes)}${r.note.isEmpty ? '' : ' · ${esc(r.note)}'}</p>
        </div>
        <div class="speedup ${speed >= 1 ? 'win' : 'loss'}">
          <strong>${speed.toStringAsFixed(1)}×</strong>
          <span>${speed >= 1 ? 'faster than archive' : 'slower than archive'}</span>
        </div>
      </header>
      ${bar('archive', 'archive (Dart)', r.archiveMs)}
      ${bar('rapid', 'rapid_archive (Rust)', r.rapidMs)}
      ${r.browserMs == null ? '' : bar('browser', 'Browser built-in', r.browserMs!)}
      <p class="check ${r.ok ? 'ok' : 'fail'}">${r.ok ? 'Output verified byte for byte' : 'Output mismatch: results differ'}</p>
    </article>''');
  }
  list.innerHTML = sb.toString().toJS;
}

void setButtons(bool on) {
  for (final id in ['pick', 'sample-json', 'sample-zip', 'clear']) {
    ($(id) as web.HTMLButtonElement).disabled = !on;
  }
}

Future<void> runSampleJson() async {
  if (busy) return;
  status('Generating 32 MB of JSON…');
  await breathe();
  await run('sample orders.json', sampleJson(32 << 20));
}

Future<void> runSampleZip() async {
  if (busy) return;
  status('Generating a zip of 2,000 JSON files…');
  await breathe();
  await run('sample orders.zip', sampleZip(2000, 16 * 1024));
}

Future<void> readFile(web.File f) async {
  status('Reading ${f.name} (${mb(f.size)})…');
  final buf = await f.arrayBuffer().toDart;
  await run(f.name, buf.toDart.asUint8List());
}

Future<void> main() async {
  status('Loading the WebAssembly module…');
  try {
    await rapid.ensureRapidArchiveInitialized();
  } catch (e) {
    status('This browser could not load WebAssembly: $e', error: true);
    return;
  }
  status('Ready. Drop a file, or try a sample.');
  setButtons(true);

  final input = $('file') as web.HTMLInputElement;
  $('pick').addEventListener('click', ((web.Event _) => input.click()).toJS);
  input.addEventListener('change', ((web.Event _) {
    final f = input.files?.item(0);
    if (f != null) readFile(f);
    input.value = '';
  }).toJS);

  ($('runs') as web.HTMLSelectElement).addEventListener('change', ((web.Event e) {
    runs = int.parse(($('runs') as web.HTMLSelectElement).value);
  }).toJS);

  $('sample-json').addEventListener('click', ((web.Event _) {
    runSampleJson();
  }).toJS);
  $('sample-zip').addEventListener('click', ((web.Event _) {
    runSampleZip();
  }).toJS);
  $('clear').addEventListener('click', ((web.Event _) {
    results.clear();
    $('results').innerHTML = ''.toJS;
    status('Cleared. Drop a file, or try a sample.');
  }).toJS);

  final drop = $('drop');
  drop.addEventListener('dragover', ((web.DragEvent e) {
    e.preventDefault();
    drop.classList.add('over');
  }).toJS);
  drop.addEventListener('dragleave', ((web.Event _) => drop.classList.remove('over')).toJS);
  drop.addEventListener('drop', ((web.DragEvent e) {
    e.preventDefault();
    drop.classList.remove('over');
    final f = e.dataTransfer?.files.item(0);
    if (f != null) readFile(f);
  }).toJS);
}
