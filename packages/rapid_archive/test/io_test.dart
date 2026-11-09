@TestOn('vm')
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' as ref;
import 'package:rapid_archive/rapid_archive_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rapid_io_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Uint8List bytes(int n, int seed) {
    final r = Random(seed);
    // Half random, half repetitive: compressible but not trivial.
    return Uint8List.fromList(
        List.generate(n, (i) => i.isEven ? r.nextInt(256) : i & 0xff));
  }

  test('gzipFile / gunzipFile round trip; archive reads ours', () async {
    final src = File('${tmp.path}/a.bin')..writeAsBytesSync(bytes(3 << 20, 1));
    await gzipFile(src.path, '${tmp.path}/a.gz');
    final gz = File('${tmp.path}/a.gz').readAsBytesSync();
    expect(const ref.GZipDecoder().decodeBytes(gz), src.readAsBytesSync());
    final n = await gunzipFile('${tmp.path}/a.gz', '${tmp.path}/b.bin');
    expect(n, src.lengthSync());
    expect(File('${tmp.path}/b.bin').readAsBytesSync(), src.readAsBytesSync());
  });

  test('stream transformers pipe straight into a file', () async {
    final src = File('${tmp.path}/a.bin')..writeAsBytesSync(bytes(3 << 20, 3));
    await src.openRead()
        .transform(const GZipEncoder(parallel: true).transformer())
        .pipe(File('${tmp.path}/a.gz').openWrite());
    await File('${tmp.path}/a.gz').openRead()
        .transform(const GZipDecoder().transformer())
        .pipe(File('${tmp.path}/b.bin').openWrite());
    expect(File('${tmp.path}/b.bin').readAsBytesSync(), src.readAsBytesSync());
  });

  test('zipDirectory / extractFileToDisk round trip, with a big entry',
      () async {
    final dir = Directory('${tmp.path}/in')..createSync();
    Directory('${dir.path}/sub/empty').createSync(recursive: true);
    File('${dir.path}/small.txt').writeAsStringSync('hello');
    File('${dir.path}/sub/big.bin').writeAsBytesSync(bytes(20 << 20, 2));
    for (var i = 0; i < 50; i++) {
      File('${dir.path}/sub/f$i.txt').writeAsStringSync('file $i ' * i);
    }
    await ZipFileEncoder().zipDirectory(dir, level: 1);
    final zip = File('${dir.path}.zip');
    expect(zip.existsSync(), isTrue);

    // package:archive can read it.
    final a = ref.ZipDecoder().decodeBytes(zip.readAsBytesSync());
    expect(a.findFile('small.txt')!.content, 'hello'.codeUnits);
    expect(a.findFile('sub/big.bin')!.size, 20 << 20);

    await extractFileToDisk(zip.path, '${tmp.path}/out');
    expect(File('${tmp.path}/out/small.txt').readAsStringSync(), 'hello');
    expect(File('${tmp.path}/out/sub/big.bin').readAsBytesSync(),
        File('${dir.path}/sub/big.bin').readAsBytesSync());
    expect(File('${tmp.path}/out/sub/f49.txt').readAsStringSync(),
        'file 49 ' * 49);
    expect(Directory('${tmp.path}/out/sub/empty').existsSync(), isTrue);
  });

  test('zip slip is refused', () async {
    final evil = ref.Archive()
      ..add(ref.ArchiveFile.bytes('../evil.txt', [1, 2, 3]));
    final p = '${tmp.path}/evil.zip';
    File(p).writeAsBytesSync(ref.ZipEncoder().encodeBytes(evil));
    await expectLater(extractFileToDisk(p, '${tmp.path}/out'),
        throwsA(isA<RapidArchiveException>()));
    expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
  });

  test('missing input gives a clear error', () async {
    await expectLater(gunzipFile('${tmp.path}/nope.gz', '${tmp.path}/x'),
        throwsA(isA<RapidArchiveException>()));
  });
}
