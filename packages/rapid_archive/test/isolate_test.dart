@TestOn('vm')
library;

import 'dart:isolate';
import 'dart:typed_data';

import 'package:rapid_archive/rapid_archive.dart';
import 'package:test/test.dart';

// Results must survive being returned from Isolate.run (or Flutter's
// compute), which hands them over without copying and then shuts the
// worker isolate down, running its finalizers.

Uint8List _data() => Uint8List.fromList(
    List.generate(300000, (i) => (i * 31 + (i >> 7)) & 0xff));

Archive _archive() => Archive()
  ..add(ArchiveFile.bytes('a.bin', _data()))
  ..add(ArchiveFile.string('b.txt', 'hello ' * 5000));

void main() {
  final data = _data();

  test('gzip/zlib/deflate output survives Isolate.run', () async {
    final gz = await Isolate.run(() => const GZipEncoder().encodeBytes(_data()));
    final gzp = await Isolate.run(
        () => const GZipEncoder(parallel: true).encodeBytes(_data()));
    final zl = await Isolate.run(() => const ZLibEncoder().encodeBytes(_data()));
    final raw = await Isolate.run(
        () => const ZLibEncoder().encodeBytes(_data(), raw: true));
    // Give the GC a chance to reuse freed memory.
    for (var i = 0; i < 20; i++) {
      await Isolate.run(() => Uint8List(1 << 20).length);
    }
    expect(const GZipDecoder().decodeBytes(gz, verify: true), data);
    expect(const GZipDecoder().decodeBytes(gzp, verify: true), data);
    expect(const ZLibDecoder().decodeBytes(zl, verify: true), data);
    expect(const ZLibDecoder().decodeBytes(raw, raw: true), data);
  });

  test('decoded bytes survive Isolate.run', () async {
    final gz = const GZipEncoder().encodeBytes(data);
    final zl = const ZLibEncoder().encodeBytes(data);
    final a = await Isolate.run(() => const GZipDecoder().decodeBytes(gz));
    final b = await Isolate.run(() => const ZLibDecoder().decodeBytes(zl));
    for (var i = 0; i < 20; i++) {
      await Isolate.run(() => Uint8List(1 << 20).length);
    }
    expect(a, data);
    expect(b, data);
  });

  test('zip bytes and decoded archives survive Isolate.run', () async {
    final zip = await Isolate.run(() => const ZipEncoder().encodeBytes(_archive()));
    final ref = const ZipEncoder().encodeBytes(_archive());
    final decoded =
        await Isolate.run(() => const ZipDecoder().decodeBytes(ref));
    for (var i = 0; i < 20; i++) {
      await Isolate.run(() => Uint8List(1 << 20).length);
    }
    final back = const ZipDecoder().decodeBytes(zip, verify: true);
    expect(back.files.map((f) => f.name), ['a.bin', 'b.txt']);
    expect(back.files.first.content, data);
    expect(decoded.files.first.content, data);
    expect(String.fromCharCodes(decoded.files.last.content), 'hello ' * 5000);
  });
}
