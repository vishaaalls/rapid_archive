# Rust-powered Flutter packages

A collection of drop-in replacements for popular Dart and Flutter packages,
with their heavy work moved into Rust. To switch, an app changes one import
line and keeps the rest of its code.

| Package | Replaces | Status |
|---|---|---|
| [`rapid_archive`](packages/rapid_archive) | `archive` (gzip, zlib, zip) | Proof of concept |

## How every package is built

```
packages/<name>/
  native/          Rust crate (cdylib + staticlib), exposes a small C ABI
  hook/build.dart  Dart build hook: runs cargo for the target platform and
                   bundles the library (no Flutter plugin boilerplate needed)
  lib/src/bindings.dart   @Native leaf FFI calls
  lib/<name>.dart  Public API that mirrors the original package
  test/            Interop tests against the original package
  bench/           Benchmarks against the original package
```

The rules that make these packages fast:

1. **No copies across the boundary.** Inputs go to Rust as `Uint8List.address`
   through leaf calls. Outputs are Rust buffers wrapped with
   `asTypedList(finalizer: ...)`, so the Dart GC frees them.
2. **One native call per operation.** Batch work, such as all of a zip's
   entries, into a single call instead of one call per item.
3. **Use every core** where the format allows it, with rayon.
4. **Same API as the original**, and tests that check both packages can read
   each other's output.
5. **Only target CPU-heavy, pure-compute packages.** Packages that wrap
   platform APIs (camera, storage) can't get faster this way.
