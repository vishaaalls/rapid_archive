// Page UI. The benchmarks themselves run in a Web Worker (worker.dart), so
// the page stays responsive even while a 1 GB zip is being extracted.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:web/web.dart' as web;

import 'bench.dart' show Result, mb, maxBytes;
import 'streaming.dart' show StreamResult;

final results = <Result>[];
final streamResults = <StreamResult>[];
var runs = 3;
var busy = false;
web.Worker? worker;

web.Element $(String id) => web.document.getElementById(id)!;

void status(String msg, {bool error = false}) {
  final s = $('status');
  s.textContent = msg;
  s.className = error ? 'status error' : 'status';
}

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

void renderStream() {
  final sb = StringBuffer();
  for (final r in streamResults.reversed) {
    final slowest = [r.rapidMs, if (r.browserMs != null) r.browserMs!].reduce(max);
    String bar(String cls, String label, double v) => '''
      <div class="bar-row">
        <span class="bar-label">$label</span>
        <span class="bar-track"><span class="bar $cls" style="width:${(v / slowest * 100).clamp(1, 100).toStringAsFixed(1)}%"></span></span>
        <span class="bar-value">${ms(v)}<small>${rate(r.bytes, v)}</small></span>
      </div>''';
    final ok = r.rapidOk && (r.browserOk ?? true);
    final heap = r.peakHeap == null ? '' : ' Peak JavaScript heap during the run: ${mb(r.peakHeap!)}.';
    sb.write('''
    <article class="result">
      <header>
        <div>
          <h3>gzip stream round trip</h3>
          <p class="meta">${esc(r.name)} · ${mb(r.bytes)} · gzip output ${mb(r.rapidZ)}${r.browserZ == null ? '' : ' vs ${mb(r.browserZ!)} (browser)'}</p>
        </div>
        <div class="speedup win">
          <strong>${rate(r.bytes, r.rapidMs)}</strong>
          <span>rapid_archive, compress + decompress</span>
        </div>
      </header>
      ${bar('rapid', 'rapid_archive (Rust)', r.rapidMs)}
      ${r.browserMs == null ? '' : bar('browser', 'Browser built-in', r.browserMs!)}
      <p class="check ${ok ? 'ok' : 'fail'}">${ok ? 'Round trip verified: same ${r.bytes} bytes and the same Adler-32 checksum.' : 'Round trip mismatch: rapid ${r.rapidOk ? 'ok' : 'FAILED'}, browser ${r.browserOk == false ? 'FAILED' : 'ok'}'}$heap</p>
    </article>''');
  }
  $('stream-results').innerHTML = sb.toString().toJS;
}

void setButtons(bool on) {
  for (final id in ['pick', 'sample-json', 'sample-zip', 'clear', 'stream-pick']) {
    ($(id) as web.HTMLButtonElement).disabled = !on;
  }
}

void startWorker() {
  final w = web.Worker('worker.dart.js'.toJS);
  w.onmessage = ((web.MessageEvent e) {
    final m = jsonDecode((e.data as JSString).toDart) as Map<String, dynamic>;
    switch (m['type']) {
      case 'ready':
        if (!busy) {
          status('Ready. Drop a file, or try a sample.');
          setButtons(true);
        }
      case 'status':
        status(m['msg'] as String);
      case 'result':
        results.add(Result.fromJson(m['result'] as Map<String, dynamic>));
        render();
      case 'stream-result':
        streamResults.add(StreamResult.fromJson(m['result'] as Map<String, dynamic>));
        renderStream();
      case 'stream-done':
        finish('Streaming check done. The file was never loaded whole.');
      case 'done':
        finish('Done. Median of ${m['runs']} run${m['runs'] == 1 ? '' : 's'} per step.');
      case 'error':
        finish(m['msg'] as String, error: true);
    }
  }).toJS;
  w.onerror = ((web.Event e) {
    // A worker that runs out of memory dies; start a fresh one.
    worker?.terminate();
    finish('The benchmark stopped, most likely because the browser ran out of '
        'memory for this file. Try a smaller file.', error: true);
    startWorker();
  }).toJS;
  worker = w;
}

void begin() {
  busy = true;
  setButtons(false);
}

void finish(String msg, {bool error = false}) {
  busy = false;
  setButtons(true);
  status(msg, error: error);
}

void post(Map<String, Object?> m, [JSArrayBuffer? buf]) {
  final o = JSObject();
  m.forEach((k, v) => o[k] = v is String ? v.toJS : (v as int).toJS);
  if (buf != null) {
    o['buf'] = buf;
    worker!.postMessage(o, [buf].toJS); // transfer, no copy
  } else {
    worker!.postMessage(o);
  }
}

Future<void> readFile(web.File f) async {
  if (busy) return;
  begin();
  status('Reading ${f.name} (${mb(f.size)})…');
  // Rough early check: zips and gzip usually unpack to several times their size.
  if (f.size > maxBytes) {
    finish('${f.name} is ${mb(f.size)}. The browser benchmark handles up to '
        '${mb(maxBytes)} unpacked. Use bench/compare.sh on your Mac for bigger files.',
        error: true);
    return;
  }
  final buf = await f.arrayBuffer().toDart;
  post({'cmd': 'file', 'name': f.name, 'runs': runs}, buf);
}

void streamFile(web.File f) {
  if (busy) return;
  begin();
  status('Streaming ${f.name} (${mb(f.size)})…');
  final o = JSObject();
  o['cmd'] = 'stream'.toJS;
  o['runs'] = 1.toJS;
  o['file'] = f; // a File is sent by reference; it is read chunk by chunk
  worker!.postMessage(o);
}

void main() {
  status('Loading…');
  startWorker();

  final sInput = $('stream-file') as web.HTMLInputElement;
  $('stream-pick').addEventListener('click', ((web.Event _) => sInput.click()).toJS);
  sInput.addEventListener('change', ((web.Event _) {
    final f = sInput.files?.item(0);
    if (f != null) streamFile(f);
    sInput.value = '';
  }).toJS);
  final sDrop = $('stream-drop');
  sDrop.addEventListener('dragover', ((web.DragEvent e) {
    e.preventDefault();
    sDrop.classList.add('over');
  }).toJS);
  sDrop.addEventListener('dragleave', ((web.Event _) => sDrop.classList.remove('over')).toJS);
  sDrop.addEventListener('drop', ((web.DragEvent e) {
    e.preventDefault();
    sDrop.classList.remove('over');
    final f = e.dataTransfer?.files.item(0);
    if (f != null) streamFile(f);
  }).toJS);

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
    if (busy) return;
    begin();
    post({'cmd': 'sample-json', 'runs': runs});
  }).toJS);
  $('sample-zip').addEventListener('click', ((web.Event _) {
    if (busy) return;
    begin();
    post({'cmd': 'sample-zip', 'runs': runs});
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
