// WebAssembly bindings: the same Rust core, compiled for the browser.
//
// The wasm module is embedded in the package (wasm_bytes.g.dart), so web apps
// need no asset setup. Call `RapidArchive.ensureInitialized()` once at
// startup; it compiles the module asynchronously. If you forget, the first
// call compiles it synchronously, which browsers allow for a module this size
// but may block the page for a moment.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'common.dart';
import 'wasm_bytes.g.dart';

export 'common.dart';

@JS('WebAssembly.instantiate')
external JSPromise<JSObject> _instantiate(JSUint8Array bytes);

@JS('WebAssembly.Module')
extension type _Module._(JSObject _) implements JSObject {
  external factory _Module(JSUint8Array bytes);
}

@JS('WebAssembly.Instance')
extension type _Instance._(JSObject _) implements JSObject {
  external factory _Instance(_Module module);
  external JSObject get exports;
}

JSObject? _exports;
Future<void>? _loading;

Uint8List get _wasmBytes => base64Decode(rapidArchiveWasmBase64);

/// Compiles the WebAssembly module. Safe to call more than once.
Future<void> ensureInitialized() {
  if (_exports != null) return Future.value();
  return _loading ??= () async {
    final result = await _instantiate(_wasmBytes.toJS).toDart;
    _exports ??= (result['instance'] as _Instance).exports;
  }();
}

JSObject get _x {
  final e = _exports;
  if (e != null) return e;
  // Synchronous fallback for callers that skipped ensureInitialized().
  return _exports = _Instance(_Module(_wasmBytes.toJS)).exports;
}

int _call(String name, List<int> args) {
  final f = _x[name] as JSFunction;
  final r = switch (args.length) {
    1 => f.callAsFunction(null, args[0].toJS),
    2 => f.callAsFunction(null, args[0].toJS, args[1].toJS),
    3 => f.callAsFunction(null, args[0].toJS, args[1].toJS, args[2].toJS),
    _ => f.callAsFunctionVarArgs(null, [for (final a in args) a.toJS]),
  };
  return r == null ? 0 : (r as JSNumber).toDartInt;
}

extension on JSFunction {
  JSAny? callAsFunctionVarArgs(JSAny? thisArg, List<JSAny?> args) =>
      (this as JSObject).callMethodVarArgs('call'.toJS, [thisArg, ...args]);
}

/// Current view of wasm memory (re-read after any call: memory can grow).
ByteBuffer get _buf => ((_x['memory'] as JSObject)['buffer'] as JSArrayBuffer).toDart;
Uint8List get _mem => _buf.asUint8List();
ByteData get _view => _buf.asByteData();

/// Copies [data] into wasm memory. Release with [_release].
int _put(Uint8List data) {
  final p = _call('ra_input_alloc', [data.length]);
  _mem.setRange(p, p + data.length, data);
  return p;
}

void _release(int p, int len) => _call('ra_input_free', [p, len]);

int? _scratch;
int get _out => _scratch ??= _call('ra_input_alloc', [32]);

Never _fail() {
  final p = _call('ra_last_error', const []);
  final m = _mem;
  var end = p;
  while (m[end] != 0) {
    end++;
  }
  throw RapidArchiveException(utf8.decode(m.sublist(p, end)));
}

/// Copies a Rust-owned result out of wasm memory and frees it.
Uint8List _take(int ptr, int len) {
  final r = Uint8List.fromList(Uint8List.sublistView(_mem, ptr, ptr + len));
  _call('ra_free', [ptr]);
  return r;
}

Uint8List compress(StreamFormat f, List<int> data, int level,
    {bool parallel = false}) {
  final b = asBytes(data);
  final p = _put(b);
  final o = _out;
  final rc = _call('ra_compress', [f.index, p, b.length, level, 0, o, o + 4]);
  _release(p, b.length);
  if (rc != 0) _fail();
  final v = _view;
  return _take(v.getUint32(o, Endian.little), v.getUint32(o + 4, Endian.little));
}

Uint8List decompress(StreamFormat f, List<int> data) {
  final b = asBytes(data);
  final p = _put(b);
  final o = _out;
  final rc = _call('ra_decompress', [f.index, p, b.length, o, o + 4]);
  _release(p, b.length);
  if (rc != 0) _fail();
  final v = _view;
  return _take(v.getUint32(o, Endian.little), v.getUint32(o + 4, Endian.little));
}

Uint8List zipEncode(
    Uint8List names, Uint8List blob, List<int> table, int count, int level) {
  final np = _put(names);
  final bp = _put(blob);
  // Uint64List isn't available when compiled to JavaScript: write u64s by hand.
  final tb = Uint8List(table.length * 8);
  final tbv = ByteData.sublistView(tb);
  for (var i = 0; i < table.length; i++) {
    tbv.setUint32(i * 8, table[i] % 0x100000000, Endian.little);
    tbv.setUint32(i * 8 + 4, table[i] ~/ 0x100000000, Endian.little);
  }
  final tp = _put(tb);
  final o = _out;
  final rc = _call('ra_zip_encode',
      [np, names.length, bp, blob.length, tp, count, level, o, o + 4]);
  _release(np, names.length);
  _release(bp, blob.length);
  _release(tp, tb.length);
  if (rc != 0) _fail();
  final v = _view;
  return _take(v.getUint32(o, Endian.little), v.getUint32(o + 4, Endian.little));
}

/// Opens a streaming encoder or decoder; returns an opaque handle. (The
/// browser has one thread here, so `parallel` is ignored.)
int streamNew(bool decode, StreamFormat f, int level, bool parallel) {
  final h = _call('ra_stream_new', [decode ? 1 : 0, f.index, level, 0]);
  if (h == 0) _fail();
  return h;
}

/// Feeds [data] to the stream [h]; returns the output that is ready.
Uint8List streamPush(int h, Uint8List data, bool finish) {
  final p = _put(data);
  final o = _out;
  final rc = _call(
      'ra_stream_push', [h, p, data.length, finish ? 1 : 0, o, o + 4]);
  _release(p, data.length);
  if (rc != 0) _fail();
  // The output lives in a buffer the stream reuses: copy, never free.
  final v = _view;
  final ptr = v.getUint32(o, Endian.little);
  final len = v.getUint32(o + 4, Endian.little);
  return Uint8List.fromList(Uint8List.sublistView(_mem, ptr, ptr + len));
}

void streamFree(int h) => _call('ra_stream_free', [h]);

RawZip zipDecode(List<int> zip) {
  final b = asBytes(zip);
  final p = _put(b);
  final o = _out; // RaZip on wasm32: six 4-byte fields
  final rc = _call('ra_zip_decode', [p, b.length, o]);
  _release(p, b.length);
  if (rc != 0) _fail();
  final v = _view;
  final count = v.getUint32(o, Endian.little);
  final dataPtr = v.getUint32(o + 4, Endian.little);
  final dataLen = v.getUint32(o + 8, Endian.little);
  final namesPtr = v.getUint32(o + 12, Endian.little);
  final namesLen = v.getUint32(o + 16, Endian.little);
  final tablePtr = v.getUint32(o + 20, Endian.little);
  final table = List<int>.filled(count * 5, 0);
  final tv = _view;
  for (var i = 0; i < count * 5; i++) {
    table[i] = tv.getUint32(tablePtr + i * 8, Endian.little) +
        tv.getUint32(tablePtr + i * 8 + 4, Endian.little) * 0x100000000;
  }
  _call('ra_free', [tablePtr]);
  return RawZip(count, _take(dataPtr, dataLen), _take(namesPtr, namesLen), table);
}

// ---------------------------------------------------------------------------
// Async path: the browser's own CompressionStream / DecompressionStream.
// They run native code inside the browser, so for plain gzip/zlib on web
// they are as fast as or faster than WebAssembly. They can't take a
// compression level, so a custom level uses WebAssembly instead.
// ---------------------------------------------------------------------------

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSUint8Array> parts);
  external JSObject stream();
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSObject body);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('CompressionStream')
external JSFunction? get _compressionStream;
@JS('DecompressionStream')
external JSFunction? get _decompressionStream;

String _streamName(StreamFormat f) => switch (f) {
      StreamFormat.gzip => 'gzip',
      StreamFormat.zlib => 'deflate',
      StreamFormat.deflate => 'deflate-raw',
    };

Future<Uint8List> _viaStream(JSFunction ctor, StreamFormat f, Uint8List data) async {
  final transform = ctor.callAsConstructor<JSObject>(_streamName(f).toJS);
  final stream = _Blob([data.toJS].toJS)
      .stream()
      .callMethod<JSObject>('pipeThrough'.toJS, transform);
  final buf = await _Response(stream).arrayBuffer().toDart;
  return buf.toDart.asUint8List();
}

Future<Uint8List> compressAsync(StreamFormat f, List<int> data, int level) async {
  final ctor = _compressionStream;
  if (ctor != null && (level < 0 || level == 6)) {
    try {
      return await _viaStream(ctor, f, asBytes(data));
    } catch (_) {
      // Unsupported format in this browser: fall through to WebAssembly.
    }
  }
  return compress(f, data, level);
}

Future<Uint8List> decompressAsync(StreamFormat f, List<int> data) async {
  final ctor = _decompressionStream;
  if (ctor != null) {
    try {
      return await _viaStream(ctor, f, asBytes(data));
    } catch (_) {
      // Corrupt or unusual input (e.g. some multi-member gzip): let the
      // WebAssembly decoder handle it and produce a proper error.
    }
  }
  return decompress(f, data);
}
