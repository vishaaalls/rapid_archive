// FFI bindings for the on-disk functions (native/src/files.rs). Native only.
//
// These calls do file I/O and can run for a long time, so they are not leaf
// calls. The public API runs them in a background isolate.
//
// The native library is registered under the bindings_ffi.dart asset id.
@DefaultAsset('package:rapid_archive/src/bindings_ffi.dart')
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings_ffi.dart';

@Native<Int32 Function(Int32, Pointer<Uint8>, Size, Pointer<Uint8>, Size, Int32, Int32)>()
external int ra_compress_file(int format, Pointer<Uint8> src, int srcLen,
    Pointer<Uint8> dst, int dstLen, int level, int parallel);

@Native<Int32 Function(Int32, Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint64>)>()
external int ra_decompress_file(int format, Pointer<Uint8> src, int srcLen,
    Pointer<Uint8> dst, int dstLen, Pointer<Uint64> outN);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint64>)>()
external int ra_zip_extract_file(Pointer<Uint8> zip, int zipLen,
    Pointer<Uint8> dir, int dirLen, Pointer<Uint64> outCount);

@Native<Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Int32, Pointer<Uint64>)>()
external int ra_zip_create_file(Pointer<Uint8> dir, int dirLen,
    Pointer<Uint8> zip, int zipLen, int level, Pointer<Uint64> outCount);

/// Calls [f] with two paths as UTF-8 native buffers and a u64 out-param, and
/// returns the out-param. Throws [RapidArchiveException] when [f] fails.
int _call2(String a, String b,
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint64>) f) {
  final ab = utf8.encode(a);
  final bb = utf8.encode(b);
  final pa = malloc<Uint8>(ab.length + 1);
  final pb = malloc<Uint8>(bb.length + 1);
  final n = calloc<Uint64>();
  try {
    pa.asTypedList(ab.length).setAll(0, ab);
    pb.asTypedList(bb.length).setAll(0, bb);
    if (f(pa, ab.length, pb, bb.length, n) != 0) {
      throw RapidArchiveException(ra_last_error().toDartString());
    }
    return n.value;
  } finally {
    malloc.free(pa);
    malloc.free(pb);
    calloc.free(n);
  }
}

void compressFile(StreamFormat f, String src, String dst, int level, bool parallel) =>
    _call2(src, dst, (a, al, b, bl, _) =>
        ra_compress_file(f.index, a, al, b, bl, level, parallel ? 1 : 0));

int decompressFile(StreamFormat f, String src, String dst) =>
    _call2(src, dst, (a, al, b, bl, n) => ra_decompress_file(f.index, a, al, b, bl, n));

int extractZip(String zip, String dir) => _call2(zip, dir, ra_zip_extract_file);

int zipDirectory(String dir, String zip, int level) =>
    _call2(dir, zip, (a, al, b, bl, n) => ra_zip_create_file(a, al, b, bl, level, n));
