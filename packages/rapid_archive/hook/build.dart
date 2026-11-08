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
    OS.android => arch == Architecture.arm
        ? 'armv7-linux-androideabi'
        : '$a-linux-android',
    OS.iOS => code.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? (arch == Architecture.arm64 ? 'aarch64-apple-ios-sim' : 'x86_64-apple-ios')
        : 'aarch64-apple-ios',
    OS.macOS => '$a-apple-darwin',
    OS.linux => arch == Architecture.arm
        ? 'armv7-unknown-linux-gnueabihf'
        : '$a-unknown-linux-gnu',
    OS.windows => '$a-pc-windows-msvc',
    _ => throw UnsupportedError('OS $os'),
  };
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    final triple = _triple(os, code.targetArchitecture, code);
    final static = os == OS.iOS ||
        code.linkModePreference == LinkModePreference.static;

    final crateDir = input.packageRoot.resolve('native/');
    final targetDir = input.outputDirectoryShared.resolve('cargo/');
    // Android cross-compiles need the NDK linker configured for cargo, e.g.
    // with cargo-ndk or native/.cargo/config.toml.
    final result = await Process.run(
      'cargo',
      [
        'build',
        '--release',
        '--target', triple,
        '--manifest-path', crateDir.resolve('Cargo.toml').toFilePath(),
        '--target-dir', targetDir.toFilePath(),
      ],
    );
    if (result.exitCode != 0) {
      throw Exception('cargo build failed for $triple:\n${result.stderr}');
    }

    final libName = static
        ? os.staticlibFileName(_crate)
        : os.dylibFileName(_crate);
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
