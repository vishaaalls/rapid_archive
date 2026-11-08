#!/usr/bin/env bash
# Compare rapid_archive with package:archive on your own files.
# Usage: bash bench/compare.sh ~/Movies/clip.mov ~/Documents/MyFolder ~/Downloads/thing.zip
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
if ! command -v dart >/dev/null; then
  for d in "$HOME"/fvm/versions/stable/bin "$HOME"/development/flutter/bin; do
    [ -x "$d/dart" ] && export PATH="$d:$PATH" && break
  done
fi
command -v cargo >/dev/null || { echo "Install Rust first: https://rustup.rs"; exit 1; }
command -v dart  >/dev/null || { echo "Install Dart 3.10+ (or Flutter 3.38+)"; exit 1; }
# Resolve paths before we cd, so relative paths and ~ work.
args=()
for a in "$@"; do
  if [[ "$a" != --* && -e "$OLDPWD/$a" && "$a" != /* ]]; then args+=("$OLDPWD/$a"); else args+=("$a"); fi
done
os=$(uname -s | tr '[:upper:]' '[:lower:]'); [ "$os" = darwin ] && os=macos
arch=$(uname -m); [ "$arch" = x86_64 ] && arch=x64; [ "$arch" = aarch64 ] && arch=arm64
bin="build/cli/${os}_${arch}/bundle/bin/compare"
if [ ! -x "$bin" ] || [ bench/compare.dart -nt "$bin" ]; then
  dart pub get >/dev/null
  dart build cli -t bench/compare.dart >/dev/null
fi
exec "$bin" "${args[@]}"
