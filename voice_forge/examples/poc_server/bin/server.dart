/// voice_forge Phase 1 transport POC — Dart WebRTC server (loopback).
///
/// Accepts a Flutter client's offer over WebSocket (/signal), decodes the
/// client's Opus audio to raw PCM with libopus (opus_codec_dart), re-encodes
/// it, and sends it back — proving the full server-side audio loop:
///
///   flutter_webrtc -> WebRTC -> webrtc_dart -> Opus decode -> PCM -> encode -> back
///
/// Run:
///   dart run bin/server.dart
///   curl localhost:8765/health
library;

import 'dart:ffi';
import 'dart:io';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:voice_forge/voice_forge.dart';

import 'loopback_core.dart';

void initOpusLibrary() {
  final candidates = <String>[
    '/opt/homebrew/opt/opus/lib/libopus.dylib',
    '/opt/homebrew/lib/libopus.dylib',
    '/usr/local/lib/libopus.dylib',
    'libopus.dylib',
    'libopus.so.0',
    'opus.dll',
  ];
  for (final path in candidates) {
    try {
      initOpus(DynamicLibrary.open(path));
      stdout.writeln('[opus] loaded $path (${getOpusVersion()})');
      return;
    } catch (_) {}
  }
  throw StateError(
    'libopus not found. Install it: brew install opus (macOS) / '
    'apt install libopus0 (Linux)',
  );
}

Future<void> main() async {
  initOpusLibrary();
  await runVoiceCallServer(coreFactory: LoopbackCore.new);
}
