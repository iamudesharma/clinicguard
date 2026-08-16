/// First-run auto-downloads for the sherpa-onnx runtime.
///
/// voice_forge does not bundle native binaries. On first load
/// ([SherpaKit.loadNative]) it downloads the prebuilt `libsherpa-onnx-c-api`
/// from the official sherpa-onnx GitHub releases into a user cache
/// (~/.cache/voice_forge/native, overridable via `VOICE_FORGE_NATIVE_DIR`),
/// and [ensureModels] fetches the standard speech models when missing.
/// Set `autoDownload: false` on [SherpaKit.load] to disable and manage
/// artifacts manually.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Native-library version the bindings are built for. Bump this together
/// with the `voice_forge_speech` dependency (the sherpa-sync pipeline pins
/// the same version).
const String kNativeVersion = '1.13.5';

String _arch() =>
    Platform.version.contains('arm64') ? 'arm64' : 'x86_64';

/// Release-asset platform key, e.g. `osx-arm64` or `linux-x64`.
String nativePlatformKey() {
  final os = Platform.operatingSystem;
  final arch = _arch();
  if (os == 'macos') {
    return arch == 'arm64' ? 'osx-arm64' : 'osx-x64';
  }
  if (os == 'linux') {
    if (arch == 'arm64') {
      throw StateError(
        'No prebuilt libsherpa-onnx-c-api for linux-arm64 in the '
        'sherpa-onnx v$kNativeVersion release. Download it manually '
        '(https://github.com/k2-fsa/sherpa-onnx/releases) and place it on '
        'the library search path, or build from source.',
      );
    }
    return 'linux-x64';
  }
  throw StateError(
    'No prebuilt libsherpa-onnx-c-api for $os-$arch in the sherpa-onnx '
    'v$kNativeVersion release. Download it manually '
    '(https://github.com/k2-fsa/sherpa-onnx/releases) and place it on the '
    'library search path.',
  );
}

String _nativeFileName() {
  return Platform.operatingSystem == 'macos'
      ? 'libsherpa-onnx-c-api.dylib'
      : 'libsherpa-onnx-c-api.so';
}

/// Where the auto-downloaded native library lives. Version-scoped so a
/// bindings upgrade re-downloads instead of reusing a stale library.
String nativeCacheDir() {
  final base = Platform.environment['VOICE_FORGE_NATIVE_DIR'] ??
      '${Platform.environment['HOME'] ?? Directory.current.path}'
          '/.cache/voice_forge/native';
  return '$base/${Platform.operatingSystem}-${_arch()}-v$kNativeVersion';
}

/// Download + unpack the official prebuilt library into [cacheDir] and
/// return the path to the `.dylib` / `.so`.
Future<String> downloadNativeLibrary(String cacheDir) async {
  final key = nativePlatformKey();
  final url =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/v$kNativeVersion/'
      'sherpa-onnx-v$kNativeVersion-$key-shared.tar.bz2';
  final name = _nativeFileName();

  Directory(cacheDir).createSync(recursive: true);
  final http.Client client = http.Client();
  try {
    final resp = await client.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw StateError(
        'Failed to download libsherpa-onnx-c-api ($url): HTTP '
        '${resp.statusCode}. Download it manually and set '
        'VOICE_FORGE_NATIVE_DIR to its directory.',
      );
    }
    final libPath = '$cacheDir/$name';
    for (final f in _unpack(resp.bodyBytes)) {
      final basename = f.name.split('/').last;
      if (basename == name || basename.startsWith('libonnxruntime')) {
        File('$cacheDir/$basename').writeAsBytesSync(
          f.content as List<int>,
          flush: true,
        );
      }
    }
    if (!File(libPath).existsSync()) {
      throw StateError(
        'Downloaded archive from $url did not contain $name.',
      );
    }
    return libPath;
  } finally {
    client.close();
  }
}

/// Unpack a `.tar.bz2` archive in memory (pure Dart).
List<ArchiveFile> _unpack(Uint8List bytes) {
  return TarDecoder()
      .decodeBytes(BZip2Decoder().decodeBytes(bytes))
      .files;
}

/// Download + unpack a `.tar.bz2` asset into [dir] (e.g. whisper/piper
/// model tarballs). Returns the top-level directory names that were written.
Future<List<String>> extractTarball(String url, String dir) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) {
    throw StateError('Download failed for $url: HTTP ${resp.statusCode}.');
  }
  final root = Directory(dir);
  root.createSync(recursive: true);
  final topLevels = <String>{};
  for (final f in _unpack(resp.bodyBytes)) {
    if (!f.isFile) continue;
    final parts = f.name.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) continue;
    topLevels.add(parts.first);
    final out = File('${root.path}/${parts.join('/')}');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(f.content as List<int>, flush: true);
  }
  return topLevels.toList();
}

/// Download a single model file (e.g. silero_vad.onnx).
Future<void> downloadFile(String url, String path) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) {
    throw StateError('Download failed for $url: HTTP ${resp.statusCode}.');
  }
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(resp.bodyBytes, flush: true);
}
