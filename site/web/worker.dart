// Web Worker entry: runs benchmarks off the page's main thread.
//
// In:  {cmd: 'file', name, runs, buf: ArrayBuffer}  or  {cmd: 'sample-json'|'sample-zip', runs}
// Out: {type: 'status'|'result'|'done'|'error', ...}

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:rapid_archive/rapid_archive.dart' as rapid;
import 'package:web/web.dart' as web;

import 'bench.dart';

final scope = globalContext as web.DedicatedWorkerGlobalScope;

void send(Map<String, Object?> m) => scope.postMessage(jsonEncode(m).toJS);

Future<void> handle(JSObject msg) async {
  final cmd = (msg['cmd'] as JSString).toDart;
  final runs = (msg['runs'] as JSNumber).toDartInt;
  final bench = Bench(
    (s) => send({'type': 'status', 'msg': s}),
    (r) => send({'type': 'result', 'result': r.toJson()}),
    runs,
  );
  try {
    await rapid.ensureRapidArchiveInitialized();
    switch (cmd) {
      case 'file':
        final name = (msg['name'] as JSString).toDart;
        final data = (msg['buf'] as JSArrayBuffer).toDart.asUint8List();
        await bench.runOn(name, data);
      case 'sample-json':
        send({'type': 'status', 'msg': 'Generating 32 MB of JSON…'});
        await bench.runOn('sample orders.json', sampleJson(32 << 20));
      case 'sample-zip':
        send({'type': 'status', 'msg': 'Generating a zip of 2,000 JSON files…'});
        await bench.runOn('sample orders.zip', sampleZip(2000, 16 * 1024));
    }
    send({'type': 'done', 'runs': bench.runs});
  } on rapid.RapidArchiveException catch (e) {
    send({'type': 'error', 'msg': 'rapid_archive could not read this file: ${e.message}'});
  } on StateError catch (e) {
    send({'type': 'error', 'msg': e.message});
  } catch (e) {
    send({'type': 'error', 'msg': 'Benchmark failed: $e'});
  }
}

void main() {
  scope.onmessage = ((web.MessageEvent e) {
    handle(e.data as JSObject);
  }).toJS;
  send({'type': 'ready'});
}
