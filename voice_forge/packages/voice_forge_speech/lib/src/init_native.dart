// Native platform initialization (dart:io available).
// Vendored for voicepipe: an injected DynamicLibrary handle is used on
// macOS, because the native lib is loaded by the host process (RTLD_LOCAL)
// and would not be visible via DynamicLibrary.process().
import 'dart:io';
import 'dart:ffi';

import 'sherpa_onnx_bindings.dart';

DynamicLibrary _injected = DynamicLibrary.process();

/// Optional host-provided handle to the already-loaded native library.
void setSherpaLibrary(DynamicLibrary lib) {
  _injected = lib;
}

DynamicLibrary loadDylib(String? path) {
  if (Platform.isMacOS) {
    return _injected;
  }

  if (Platform.isIOS) {
    return DynamicLibrary.open('SherpaOnnxC.framework/SherpaOnnxC');
  }

  if (Platform.isAndroid || Platform.isLinux) {
    if (path == null) {
      return DynamicLibrary.open('libsherpa-onnx-c-api.so');
    } else {
      return DynamicLibrary.open('$path/libsherpa-onnx-c-api.so');
    }
  }

  if (Platform.isWindows) {
    if (path == null) {
      return DynamicLibrary.open('sherpa-onnx-c-api.dll');
    } else {
      return DynamicLibrary.open('$path\\sherpa-onnx-c-api.dll');
    }
  }

  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

void initNativeBindings(String? path) {
  final dylib = loadDylib(path);
  SherpaOnnxBindings.init(dylib);
}
