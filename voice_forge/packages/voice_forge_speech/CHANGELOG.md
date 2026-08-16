## 1.13.5

* Renamed from `sherpa_onnx_dart` to `voice_forge_speech` (same package, new
  brand). The upstream `sherpa_onnx` (k2-fsa) provenance and Apache-2.0
  attribution are unchanged.
* Initial release. Vendored, Flutter-free and web-free build of the official
  `sherpa_onnx` Dart bindings (v1.13.5, Apache-2.0, k2-fsa) with a patch that
  lets the host process inject the loaded native library handle
  (`setSherpaLibrary`).
