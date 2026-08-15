# Vendored package: sherpa_onnx (pure-Dart core)

This directory is a **vendored, Flutter-free copy** of the `sherpa_onnx` Dart
bindings from [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
(v1.13.5, Apache-2.0), the official next-gen-Kaldi speech toolkit.

## Changes vs upstream

- Removed the Flutter plugin plumbing (pubspec `flutter:` section) and all
  platform packages (`sherpa_onnx_macos`, `sherpa_onnx_linux`, …).
- Removed `package:flutter/foundation.dart` (`kIsWeb` is now a constant
  `false`); web-only sources under `lib/src/web/` were deleted (the
  conditional `dart.library.js_interop` exports then resolve to the native
  implementations).
- Native library loading is delegated to the host process: voicepipe loads
  `libsherpa-onnx-c-api.dylib` explicitly before calling `initBindings()`,
  so `DynamicLibrary.process()` in `src/init_native.dart` finds it.

## License

Apache-2.0, copyright Xiaomi Corporation (see `LICENSE`). Unmodified binding
code; do not republish without upstream attribution.
