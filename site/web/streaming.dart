// Streaming check: gzip a file of any size and unzip it again, chunk by
// chunk, with rapid_archive's encodeStream/decodeStream and with the
// browser's CompressionStream. The file is never loaded whole, so this works
// on files far bigger than the normal benchmark accepts. The round trip is
// verified with a byte count and an Adler-32 checksum of input and output.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:rapid_archive/rapid_archive.dart' as rapid;
import 'package:web/web.dart' as web;

class StreamResult {
  final String name;
  final int bytes;
  final double rapidMs;
  final int rapidZ;
  final bool rapidOk;
  final double? browserMs;
  final int? browserZ;
  final bool? browserOk;
  final int? peakHeap;
  StreamResult(this.name, this.bytes, this.rapidMs, this.rapidZ, this.rapidOk,
      {this.browserMs, this.browserZ, this.browserOk, this.peakHeap});

  Map<String, Object?> toJson() => {
        'name': name, 'bytes': bytes, 'rapidMs': rapidMs, 'rapidZ': rapidZ,
        'rapidOk': rapidOk, 'browserMs': browserMs, 'browserZ': browserZ,
        'browserOk': browserOk, 'peakHeap': peakHeap,
      };
  factory StreamResult.fromJson(Map<String, dynamic> j) => StreamResult(
        j['name'] as String, j['bytes'] as int, (j['rapidMs'] as num).toDouble(),
        j['rapidZ'] as int, j['rapidOk'] as bool,
        browserMs: (j['browserMs'] as num?)?.toDouble(),
        browserZ: j['browserZ'] as int?, browserOk: j['browserOk'] as bool?,
        peakHeap: j['peakHeap'] as int?,
      );
}

/// Adler-32, fast enough in JS not to dominate the timing.
class Adler {
  int a = 1, b = 0;
  void update(List<int> d) {
    var i = 0;
    final n = d.length;
    while (i < n) {
      final end = i + 3800 < n ? i + 3800 : n;
      var x = a, y = b;
      for (; i < end; i++) {
        x += d[i];
        y += x;
      }
      a = x % 65521;
      b = y % 65521;
    }
  }

  int get value => (b << 16) | a;
}

/// Reads a Blob as a stream of chunks without loading it whole.
Stream<List<int>> blobStream(web.Blob f) async* {
  final reader = f.stream().getReader() as web.ReadableStreamDefaultReader;
  while (true) {
    final r = await reader.read().toDart;
    if (r.done) break;
    yield (r.value as JSUint8Array).toDart;
  }
}

@JS('CompressionStream')
extension type _CS._(JSObject _) implements JSObject {
  external factory _CS(String format);
}

@JS('DecompressionStream')
extension type _DS._(JSObject _) implements JSObject {
  external factory _DS(String format);
}

/// JS heap in use, where the browser reports it (Chrome). Null elsewhere.
int? heapNow() {
  final perf = globalContext['performance'] as JSObject?;
  final mem = perf?['memory'] as JSObject?;
  final used = mem?['usedJSHeapSize'];
  return used is JSNumber ? used.toDartInt : null;
}

class StreamCheck {
  final void Function(String) onStatus;
  StreamCheck(this.onStatus);

  int? _peak;
  void _sample() {
    final h = heapNow();
    if (h != null && (_peak == null || h > _peak!)) _peak = h;
  }

  String _pct(int done, int total) =>
      total == 0 ? '' : ' ${(done * 100 / total).toStringAsFixed(0)}%';

  Future<StreamResult> run(web.File f) async {
    final total = f.size;
    final name = f.name;
    final inSum = Adler();

    // rapid_archive: file → encodeStream → decodeStream → checksum.
    var inN = 0, zN = 0, outN = 0;
    final outSum = Adler();
    var lastReport = 0;
    final src = blobStream(f).map((c) {
      inN += c.length;
      inSum.update(c);
      if (inN - lastReport >= 32 << 20) {
        lastReport = inN;
        _sample();
        onStatus('rapid_archive: streaming $name…${_pct(inN, total)}');
      }
      return c;
    });
    onStatus('rapid_archive: streaming $name…');
    final sw = Stopwatch()..start();
    final z = const rapid.GZipEncoder().encodeStream(src).map((c) {
      zN += c.length;
      return c;
    });
    await for (final c in const rapid.GZipDecoder().decodeStream(z)) {
      outN += c.length;
      outSum.update(c);
    }
    final rapidMs = sw.elapsedMicroseconds / 1000;
    _sample();
    final rapidOk = inN == total && outN == total && outSum.value == inSum.value;

    // Browser built-in: same round trip with CompressionStream.
    double? bMs;
    int? bZ;
    bool? bOk;
    try {
      onStatus('Browser built-in: streaming $name…');
      var bz = 0, bOut = 0;
      final bSum = Adler();
      final counter = JSObject();
      counter['transform'] = ((JSUint8Array chunk, JSObject ctrl) {
        bz += chunk.toDart.length;
        ctrl.callMethod('enqueue'.toJS, chunk);
      }).toJS;
      final sw2 = Stopwatch()..start();
      final s = f
          .stream()
          .pipeThrough(_CS('gzip') as web.ReadableWritablePair)
          .pipeThrough(web.TransformStream(counter) as web.ReadableWritablePair)
          .pipeThrough(_DS('gzip') as web.ReadableWritablePair);
      final reader = s.getReader() as web.ReadableStreamDefaultReader;
      var last = 0;
      while (true) {
        final r = await reader.read().toDart;
        if (r.done) break;
        final c = (r.value as JSUint8Array).toDart;
        bOut += c.length;
        bSum.update(c);
        if (bOut - last >= 32 << 20) {
          last = bOut;
          _sample();
          onStatus('Browser built-in: streaming $name…${_pct(bOut, total)}');
        }
      }
      bMs = sw2.elapsedMicroseconds / 1000;
      bZ = bz;
      bOk = bOut == total && bSum.value == inSum.value;
    } catch (_) {
      bMs = null; // no CompressionStream in this browser
    }
    return StreamResult(name, total, rapidMs, zN, rapidOk,
        browserMs: bMs, browserZ: bZ, browserOk: bOk, peakHeap: _peak);
  }
}
