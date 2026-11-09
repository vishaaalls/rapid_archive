import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive.dart';
import 'package:test/test.dart';

Uint8List text(int n) {
  final s = utf8.encode('{"id":1,"name":"rapid archive","tags":["a","b"]}\n');
  return Uint8List.fromList(List.generate(n, (i) => s[i % s.length] ^ (i >> 12 & 7)));
}

/// Splits [b] into a stream of pieces of [size] bytes.
Stream<List<int>> pieces(Uint8List b, int size) async* {
  for (var o = 0; o < b.length; o += size) {
    yield Uint8List.sublistView(b, o, o + size > b.length ? b.length : o + size);
  }
}

Future<Uint8List> collect(Stream<List<int>> s) async {
  final b = BytesBuilder(copy: false);
  await for (final c in s) {
    b.add(c);
  }
  return b.takeBytes();
}

void main() {
  setUpAll(ensureRapidArchiveInitialized);

  final data = text(5 * 1024 * 1024 + 123);

  for (final parallel in [false, true]) {
    test('gzip stream round trip (parallel: $parallel), archive can read it',
        () async {
      final z = await collect(
          GZipEncoder(parallel: parallel).encodeStream(pieces(data, 100000)));
      expect(const ref.GZipDecoder().decodeBytes(z), data);
      final back = await collect(
          const GZipDecoder().decodeStream(pieces(z, 7777)));
      expect(back, data);
    });

    test('zlib and raw deflate streams (parallel: $parallel)', () async {
      final e = ZLibEncoder(parallel: parallel);
      final z = await collect(e.encodeStream(pieces(data, 65536)));
      expect(const ref.ZLibDecoder().decodeBytes(z), data);
      expect(await collect(const ZLibDecoder().decodeStream(pieces(z, 5000))),
          data);
      final r = await collect(e.encodeStream(pieces(data, 65536), raw: true));
      expect(const ZLibDecoder().decodeBytes(r, raw: true), data);
      expect(
          await collect(
              const ZLibDecoder().decodeStream(pieces(r, 3000), raw: true)),
          data);
    });
  }

  test('transformers and an empty stream', () async {
    final z = await collect(Stream<List<int>>.value(utf8.encode('hello'))
        .transform(const GZipEncoder().transformer()));
    expect(utf8.decode(const GZipDecoder().decodeBytes(z)), 'hello');
    final back = await collect(
        Stream<List<int>>.value(z).transform(const GZipDecoder().transformer()));
    expect(utf8.decode(back), 'hello');
    final empty = await collect(const GZipEncoder().encodeStream(const Stream.empty()));
    expect(const GZipDecoder().decodeBytes(empty), isEmpty);
  });

  test('truncated or corrupt stream throws', () async {
    final z = const GZipEncoder().encodeBytes(data);
    expect(
        collect(const GZipDecoder().decodeStream(pieces(
            Uint8List.sublistView(z, 0, z.length ~/ 2), 4096))),
        throwsA(isA<RapidArchiveException>()));
    expect(collect(const GZipDecoder().decodeStream(Stream.value([1, 2, 3, 4]))),
        throwsA(isA<RapidArchiveException>()));
  });

  test('cancelling a stream midway is safe', () async {
    final s = const GZipEncoder().encodeStream(pieces(data, 1 << 20));
    final first = await s.first; // cancels after one event
    expect(first, isNotEmpty);
  });
}
