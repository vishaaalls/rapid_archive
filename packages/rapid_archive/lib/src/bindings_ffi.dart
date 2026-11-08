// Low-level FFI bindings to the Rust core (native/src/lib.rs).
//
// The library is built and bundled by hook/build.dart, and these `@Native`
// functions resolve to it automatically on every platform.
//
// Calls that take a Dart buffer are *leaf* calls, which lets us pass
// `Uint8List.address` straight to Rust with no copy. Outputs come back as
// Rust-owned buffers wrapped with `asTypedList(finalizer: ra_free)`, so they
// are zero-copy as well and freed by the GC.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'common.dart';

export 'common.dart';

@Native<Int32 Function(Int32, Pointer<Uint8>, Size, Int32, Int32,
    Pointer<Pointer<Uint8>>, Pointer<Size>)>(isLeaf: true)
external int ra_compress(int format, Pointer<Uint8> data, int len, int level,
    int parallel, Pointer<Pointer<Uint8>> out, Pointer<Size> outLen);

@Native<Int32 Function(
    Int32, Pointer<Uint8>, Size, Pointer<Pointer<Uint8>>, Pointer<Size>)>(isLeaf: true)
external int ra_decompress(int format, Pointer<Uint8> data, int len,
    Pointer<Pointer<Uint8>> out, Pointer<Size> outLen);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size,
    Pointer<Uint64>, Size, Int32, Pointer<Pointer<Uint8>>, Pointer<Size>)>(isLeaf: true)
external int ra_zip_encode(
    Pointer<Uint8> names,
    int namesLen,
    Pointer<Uint8> blob,
    int blobLen,
    Pointer<Uint64> table,
    int count,
    int level,
    Pointer<Pointer<Uint8>> out,
    Pointer<Size> outLen);

final class RaZip extends Struct {
  @Size()
  external int count;
  external Pointer<Uint8> data;
  @Size()
  external int dataLen;
  external Pointer<Uint8> names;
  @Size()
  external int namesLen;
  external Pointer<Uint64> table;
}

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<RaZip>)>(isLeaf: true)
external int ra_zip_decode(Pointer<Uint8> data, int len, Pointer<RaZip> out);

@Native<Pointer<Utf8> Function()>(isLeaf: true)
external Pointer<Utf8> ra_last_error();

@Native<Void Function(Pointer<Uint8>)>(isLeaf: true)
external void ra_free(Pointer<Uint8> p);

final Pointer<NativeFinalizerFunction> _free =
    Native.addressOf<NativeFunction<Void Function(Pointer<Uint8>)>>(ra_free)
        .cast();

/// Nothing to load on native platforms; the library is linked in.
Future<void> ensureInitialized() async {}

// Scratch out-params, allocated once per isolate. Calls are synchronous, so
// they are never shared between two calls in flight.
final Pointer<Pointer<Uint8>> _outPtr = calloc<Pointer<Uint8>>();
final Pointer<Size> _outLen = calloc<Size>();
final Pointer<RaZip> _zipOut = calloc<RaZip>();


Never _fail() => throw RapidArchiveException(ra_last_error().toDartString());


Uint8List _owned(Pointer<Uint8> p, int len) {
  if (len == 0) {
    ra_free(p);
    return Uint8List(0);
  }
  return p.asTypedList(len, finalizer: _free);
}


Uint8List compress(StreamFormat f, List<int> data, int level,
    {bool parallel = false}) {
  final b = asBytes(data);
  if (ra_compress(f.index, b.address, b.length, level, parallel ? 1 : 0,
          _outPtr, _outLen) !=
      0) {
    _fail();
  }
  return _owned(_outPtr.value, _outLen.value);
}

Uint8List decompress(StreamFormat f, List<int> data) {
  final b = asBytes(data);
  if (ra_decompress(f.index, b.address, b.length, _outPtr, _outLen) != 0) {
    _fail();
  }
  return _owned(_outPtr.value, _outLen.value);
}

Uint8List zipEncode(
    Uint8List names, Uint8List blob, List<int> table, int count, int level) {
  final t = table is Uint64List ? table : Uint64List.fromList(table);
  if (ra_zip_encode(names.address, names.length, blob.address, blob.length,
          t.address, count, level, _outPtr, _outLen) !=
      0) {
    _fail();
  }
  return _owned(_outPtr.value, _outLen.value);
}


RawZip zipDecode(List<int> zip) {
  final b = asBytes(zip);
  if (ra_zip_decode(b.address, b.length, _zipOut) != 0) _fail();
  final r = _zipOut.ref;
  final Uint64List table;
  if (r.count == 0) {
    ra_free(r.table.cast());
    table = Uint64List(0);
  } else {
    table = r.table.asTypedList(r.count * 5, finalizer: _free);
  }
  return RawZip(r.count, _owned(r.data, r.dataLen),
      _owned(r.names, r.namesLen), table);
}
