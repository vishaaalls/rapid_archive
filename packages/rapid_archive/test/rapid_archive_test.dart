import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart';
import 'package:test/test.dart';

Uint8List text(int n) {
  final s = utf8.encode('{"id":1,"name":"rapid archive","tags":["a","b"]}\n');
  return Uint8List.fromList(List.generate(n, (i) => s[i % s.length]));
}

void main() {
  test('gzip round trip and interop with package:archive', () {
    final d = text(200000);
    final ours = const GZipEncoder().encodeBytes(d);
    expect(ref.GZipDecoder().decodeBytes(ours), d);
    final theirs = ref.GZipEncoder().encodeBytes(d);
    expect(const GZipDecoder().decodeBytes(theirs), d);
    expect(const GZipDecoder().decodeBytes(ours), d);
  });

  test('parallel gzip/zlib is a standard stream package:archive can read', () {
    final d = text(6 << 20);
    final gz = const GZipEncoder(parallel: true).encodeBytes(d);
    expect(ref.GZipDecoder().decodeBytes(gz), d);
    expect(ref.GZipDecoderWeb().decodeBytes(gz), d);
    final z = const ZLibEncoder(parallel: true).encodeBytes(d);
    expect(ref.ZLibDecoder().decodeBytes(z), d);
  });

  test('concatenated gzip members decode like gunzip', () {
    final a = text(1000), b = text(3000);
    final both = [
      ...const GZipEncoder().encodeBytes(a),
      ...ref.GZipEncoder().encodeBytes(b)
    ];
    expect(const GZipDecoder().decodeBytes(both), [...a, ...b]);
  });

  test('zlib and raw deflate interop', () {
    final d = text(50000);
    expect(ref.ZLibDecoder().decodeBytes(const ZLibEncoder().encodeBytes(d)), d);
    expect(const ZLibDecoder().decodeBytes(ref.ZLibEncoder().encodeBytes(d)), d);
    expect(
        const ZLibDecoder()
            .decodeBytes(const ZLibEncoder().encodeBytes(d, raw: true), raw: true),
        d);
  });

  test('empty input and plain List<int>', () {
    expect(const GZipDecoder().decodeBytes(const GZipEncoder().encodeBytes([])),
        isEmpty);
    expect(const GZipDecoder().decodeBytes(const GZipEncoder().encode([1, 2, 3])),
        [1, 2, 3]);
  });

  test('zip interop both ways, dirs and stored files', () {
    final rnd = Random(1);
    final a = Archive()
      ..add(ArchiveFile.directory('docs'))
      ..add(ArchiveFile.bytes('docs/readme.txt', text(10000)))
      ..add(ArchiveFile.bytes('héllo/ünïcode.json', text(321)))
      ..add(ArchiveFile.bytes('empty.bin', Uint8List(0)))
      ..add(ArchiveFile.noCompress('photo.jpg', 2000,
          Uint8List.fromList(List.generate(2000, (_) => rnd.nextInt(256)))));

    final ours = const ZipEncoder().encodeBytes(a);
    final readByRef = ref.ZipDecoder().decodeBytes(ours);
    expect(readByRef.files.length, 5);
    expect(readByRef.findFile('docs/readme.txt')!.content, text(10000));
    expect(readByRef.findFile('héllo/ünïcode.json')!.content, text(321));
    expect(readByRef.findFile('photo.jpg')!.content, a[4].content);

    final theirs = ref.ZipEncoder().encodeBytes(a);
    final readByUs = const ZipDecoder().decodeBytes(theirs);
    expect(readByUs.files.map((f) => f.name),
        containsAll(['docs/readme.txt', 'héllo/ünïcode.json', 'photo.jpg']));
    expect(readByUs.findFile('docs/readme.txt')!.content, text(10000));
    expect(readByUs.files.first.isFile, isFalse);
  });

  test('corrupt data throws RapidArchiveException', () {
    final g = const GZipEncoder().encodeBytes(text(10000));
    g[g.length ~/ 2] ^= 0xff;
    expect(() => const GZipDecoder().decodeBytes(g),
        throwsA(isA<RapidArchiveException>()));
    expect(() => const ZipDecoder().decodeBytes([1, 2, 3, 4]),
        throwsA(isA<RapidArchiveException>()));
  });
}
