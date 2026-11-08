// Build hook: compiles the Rust core with cargo for whatever platform the app
// is being built for, and registers the library as a code asset so the
// `@Native` functions in lib/src/bindings.dart resolve to it.
//
// Runs automatically on `dart run`, `dart test`, `flutter run` and
// `flutter build`. Needs a Rust toolchain plus the target installed
// (`rustup target add <triple>`). Published releases will ship prebuilt
// binaries so app developers don't need Rust.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

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

    final libName =
        static ? os.staticlibFileName(_crate) : os.dylibFileName(_crate);
    final lib = targetDir.resolve('$triple/release/$libName');
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/bindings_ffi.dart',
      linkMode: static ? StaticLinking() : DynamicLoadingBundled(),
      file: lib,
    ));

    // Rebuild when Rust sources change.
    output.dependencies.addAll([
      crateDir.resolve('Cargo.toml'),
      crateDir.resolve('Cargo.lock'),
      for (final f in Directory.fromUri(crateDir.resolve('src/'))
          .listSync(recursive: true)
          .whereType<File>())
        f.uri,
    ]);
  });
}
