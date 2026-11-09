// Build hook: compiles the Rust core with cargo for whatever platform the app
// is being built for, and registers the library as a code asset so the
// `@Native` functions in lib/src/bindings.dart resolve to it.
//
// Runs automatically on `dart run`, `dart test`, `flutter run` and
// `flutter build`. Released versions download a prebuilt, checksum-verified
// library from GitHub Releases (see lib/src/prebuilt.dart), so app developers
// don't need Rust. Without a prebuilt binary it builds with cargo, which
// needs Rust plus the target (`rustup target add <triple>`). To force a
// source build, add this to the app's pubspec.yaml:
//
//   hooks:
//     user_defines:
//       rapid_archive:
//         from_source: true

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'package:rapid_archive/src/prebuilt.dart';

const _crate = 'rapid_archive';

String _triple(OS os, Architecture arch, CodeConfig code) {
  final a = switch (arch) {
    Architecture.arm64 => 'aarch64',
    Architecture.x64 => 'x86_64',
    Architecture.arm => 'armv7',
    Architecture.ia32 => 'i686',
    Architecture.riscv64 => 'riscv64gc',
    _ => throw UnsupportedError('architecture $arch'),
  };
  return switch (os) {
    OS.android =>
      arch == Architecture.arm ? 'armv7-linux-androideabi' : '$a-linux-android',
    OS.iOS => code.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? (arch == Architecture.arm64
            ? 'aarch64-apple-ios-sim'
            : 'x86_64-apple-ios')
        : 'aarch64-apple-ios',
    OS.macOS => '$a-apple-darwin',
    OS.linux => arch == Architecture.arm
        ? 'armv7-unknown-linux-gnueabihf'
        : '$a-unknown-linux-gnu',
    OS.windows => '$a-pc-windows-msvc',
    _ => throw UnsupportedError('OS $os'),
  };
}

/// Points cargo (and the `cc` crate that builds libdeflate) at the toolchain
/// the Flutter/Dart SDK hands us, so Android needs no manual NDK setup.
Map<String, String> _toolchainEnv(CodeConfig code, String triple) {
  final env = <String, String>{};
  final t = triple.toUpperCase().replaceAll('-', '_');
  final u = triple.replaceAll('-', '_');
  switch (code.targetOS) {
    case OS.android:
      final cc = code.cCompiler;
      if (cc == null) break;
      // The NDK ships per-target clang wrappers next to clang, e.g.
      // aarch64-linux-android21-clang. They set --target and the API level.
      final bin = File.fromUri(cc.compiler).parent.path;
      final api = code.android.targetNdkApi;
      final clangTriple = triple == 'armv7-linux-androideabi'
          ? 'armv7a-linux-androideabi'
          : triple;
      var wrapper = '$bin/$clangTriple$api-clang';
      if (!File(wrapper).existsSync()) wrapper = cc.compiler.toFilePath();
      env['CARGO_TARGET_${t}_LINKER'] = wrapper;
      env['CC_$u'] = wrapper;
      env['AR_$u'] = cc.archiver.toFilePath();
      // 16 KB page alignment, required for Google Play from Android 15.
      env['CARGO_TARGET_${t}_RUSTFLAGS'] =
          '-C link-arg=-Wl,-z,max-page-size=16384';
    case OS.iOS:
      _setSdkRoot(
          env,
          triple.endsWith('-sim') || triple.startsWith('x86_64')
              ? 'iphonesimulator'
              : 'iphoneos');
      env['IPHONEOS_DEPLOYMENT_TARGET'] =
          '${code.iOS.deploymentVersion.major}.${code.iOS.deploymentVersion.minor}';
    case OS.macOS:
      _setSdkRoot(env, 'macosx');
      env['MACOSX_DEPLOYMENT_TARGET'] =
          '${code.macOS.deploymentVersion.major}.${code.macOS.deploymentVersion.minor}';
    default:
  }
  return env;
}

/// The hooks runner gives us a trimmed environment without SDKROOT, so the C
/// compiler that builds libdeflate can't find system headers like string.h.
void _setSdkRoot(Map<String, String> env, String sdk) {
  final r = Process.runSync('xcrun', ['--sdk', sdk, '--show-sdk-path']);
  final path = (r.stdout as String).trim();
  if (r.exitCode == 0 && path.isNotEmpty) env['SDKROOT'] = path;
}

/// Xcode and Gradle builds often run without ~/.cargo/bin on PATH.
String _cargo() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final exe = Platform.isWindows ? 'cargo.exe' : 'cargo';
  final local = home == null ? null : File('$home/.cargo/bin/$exe');
  return local != null && local.existsSync() ? local.path : 'cargo';
}

/// Downloads the prebuilt library for [triple] from the GitHub release that
/// matches this package version, verifies its SHA-256 against the hash
/// shipped in lib/src/prebuilt.dart, and caches it. Returns null when there is
/// no prebuilt binary for this target (then we build with cargo).
Future<Uri?> _prebuilt(BuildInput input, String triple, String libName) async {
  final hash = prebuiltHashes['$triple/$libName'];
  if (hash == null || prebuiltVersion.isEmpty) return null;
  final asset = '$triple-$libName';
  final dir = Directory.fromUri(
      input.outputDirectoryShared.resolve('prebuilt/$prebuiltVersion/'));
  final file = File('${dir.path}$asset');
  if (file.existsSync() && _sha256(file.readAsBytesSync()) == hash) {
    return file.uri;
  }
  // `prebuilt_url` (a user-define) points at a mirror, or a local server in tests.
  final base = input.userDefines['prebuilt_url'] as String? ?? prebuiltBaseUrl;
  final url = Uri.parse('$base/$prebuiltVersion/$asset');
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final req = await client.getUrl(url);
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: url);
    }
    final bytes = <int>[];
    await for (final chunk in res) {
      bytes.addAll(chunk);
    }
    final got = _sha256(bytes);
    if (got != hash) {
      throw Exception('Checksum mismatch for $url: expected $hash, got $got');
    }
    dir.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsBytesSync(bytes);
    tmp.renameSync(file.path);
    return file.uri;
  } finally {
    client.close();
  }
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

bool _hasCargo() {
  try {
    return Process.runSync(_cargo(), ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<Uri> _cargoBuild(
    BuildInput input, CodeConfig code, String triple, String libName) async {
  final crateDir = input.packageRoot.resolve('native/');
  final targetDir = input.outputDirectoryShared.resolve('cargo/');
  final result = await Process.run(
    _cargo(),
    [
      'build',
      '--release',
      '--target',
      triple,
      '--manifest-path',
      crateDir.resolve('Cargo.toml').toFilePath(),
      '--target-dir',
      targetDir.toFilePath(),
    ],
    environment: _toolchainEnv(code, triple),
  );
  if (result.exitCode != 0) {
    final err = result.stderr as String;
    if (err.contains('target may not be installed')) {
      throw Exception('The Rust target $triple is not installed. Run:\n'
          '  rustup target add $triple');
    }
    throw Exception('cargo build failed for $triple:\n$err');
  }
  return targetDir.resolve('$triple/release/$libName');
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    final triple = _triple(os, code.targetArchitecture, code);
    // Follow what the SDK asks for: Flutter wants dynamic libraries on every
    // platform (it wraps them in a framework on iOS); some setups ask for
    // static linking instead.
    final static = code.linkModePreference == LinkModePreference.static;
    final libName =
        static ? os.staticlibFileName(_crate) : os.dylibFileName(_crate);

    // Order: the `from_source: true` user-define forces cargo. Otherwise use the
    // verified prebuilt binary when one exists, and fall back to cargo.
    final crateDir = input.packageRoot.resolve('native/');
    final fromSource = input.userDefines['from_source'] == true;
    Uri? lib;
    if (!fromSource) {
      try {
        lib = await _prebuilt(input, triple, libName);
      } catch (e) {
        if (!_hasCargo()) {
          throw Exception('Could not download the prebuilt rapid_archive '
              'library ($e), and Rust is not installed to build it.');
        }
        stderr.writeln('rapid_archive: prebuilt download failed ($e); '
            'building with cargo.');
      }
    }
    if (lib == null) {
      if (!_hasCargo()) {
        throw Exception('rapid_archive has no prebuilt library for $triple. '
            'Install Rust (https://rustup.rs) and run: rustup target add $triple');
      }
      lib = await _cargoBuild(input, code, triple, libName);
      // Rebuild when Rust sources change.
      output.dependencies.addAll([
        crateDir.resolve('Cargo.toml'),
        crateDir.resolve('Cargo.lock'),
        for (final f in Directory.fromUri(crateDir.resolve('src/'))
            .listSync(recursive: true)
            .whereType<File>())
          f.uri,
      ]);
    }
    output.dependencies.add(input.packageRoot.resolve('lib/src/prebuilt.dart'));

    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/bindings_ffi.dart',
      linkMode: static ? StaticLinking() : DynamicLoadingBundled(),
      file: lib,
    ));
  });
}
