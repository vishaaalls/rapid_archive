#!/usr/bin/env bash
# Builds the benchmark as a native (AOT) binary and runs it.
# Usage: bench/run.sh --mb 512 [--runs 3] [--file ~/Downloads/big.tar]
set -euo pipefail
cd "$(dirname "$0")/.."
command -v cargo >/dev/null || { echo "Install Rust first: https://rustup.rs"; exit 1; }
command -v dart  >/dev/null || { echo "Install Dart 3.10+ (or Flutter 3.38+)"; exit 1; }
dart pub get
dart build cli -t bench/bench.dart
os=$(uname -s | tr '[:upper:]' '[:lower:]'); [ "$os" = darwin ] && os=macos
arch=$(uname -m); [ "$arch" = x86_64 ] && arch=x64; [ "$arch" = aarch64 ] && arch=arm64
exec "build/cli/${os}_${arch}/bundle/bin/bench" "$@"
