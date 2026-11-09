// Memory check on very large inputs. Usage:
//   dart run bench/large_check.dart <folder-with-big-files> <work-dir>
import 'dart:async';
import 'dart:io';

import 'package:rapid_archive/rapid_archive_io.dart';

/// Runs [f] and prints its time and the highest process memory (RSS)
/// seen while it ran, sampled every 20 ms. The file helpers run in a
/// background isolate, so the sampler keeps running during them.
Future<void> step(String name, Future<void> Function() f) async {
  final before = ProcessInfo.currentRss;
  var peak = before;
  final t = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final r = ProcessInfo.currentRss;
    if (r > peak) peak = r;
  });
  final sw = Stopwatch()..start();
  await f();
  t.cancel();
  final r = ProcessInfo.currentRss;
  if (r > peak) peak = r;
  String mib(int b) => (b / (1 << 20)).toStringAsFixed(0);
  print('$name: ${sw.elapsedMilliseconds} ms, RSS before ${mib(before)} MiB, '
      'peak ${mib(peak)} MiB');
}

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final work = args[1];
  final big = dir
      .listSync()
      .whereType<File>()
      .reduce((a, b) => a.lengthSync() >= b.lengthSync() ? a : b);
  print('biggest file: ${big.path} (${big.lengthSync() >> 20} MiB)');
  await step('gzip stream (parallel)', () => big
      .openRead()
      .transform(const GZipEncoder(parallel: true).transformer(level: 1))
      .pipe(File('$work/s.gz').openWrite()));
  await step('gunzip stream', () => File('$work/s.gz')
      .openRead()
      .transform(const GZipDecoder().transformer())
      .pipe(File('$work/s.out').openWrite()));
  if (File('$work/s.out').lengthSync() != big.lengthSync()) throw 'size mismatch';
  File('$work/s.out').deleteSync();
  await step('gzipFile', () => gzipFile(big.path, '$work/f.gz', level: 1));
  await step('gunzipFile', () => gunzipFile('$work/f.gz', '$work/f.out'));
  File('$work/f.out').deleteSync();
  await step('zipDirectory', () =>
      ZipFileEncoder().zipDirectory(dir, filename: '$work/d.zip', level: 1));
  await step('extractFileToDisk', () => extractFileToDisk('$work/d.zip', '$work/x'));
  print('zip size: ${File('$work/d.zip').lengthSync() >> 20} MiB');
  print('process peak RSS (includes mapped file pages): '
      '${(ProcessInfo.maxRss / (1 << 20)).toStringAsFixed(0)} MiB');
}
