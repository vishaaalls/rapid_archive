// Picks the native (dart:ffi) bindings or the WebAssembly bindings at
// compile time. Both expose the same functions.
export 'bindings_ffi.dart' if (dart.library.js_interop) 'bindings_web.dart';
