// Copyright (c)  2024  Xiaomi Corporation
// Vendored for voice_forge: Flutter-free, web-free build (server-side only).

// Conditional import: native uses dart:io/dart:ffi, web uses dart:js_interop.
import 'src/init_native.dart' as init;

// Vendored for voice_forge: allow the host to inject the loaded library handle.
export 'src/init_native.dart' show setSherpaLibrary;

// Conditional import for web WASM loader.

/// Dart bindings for the public sherpa-onnx inference APIs.
///
/// Import this library to access offline and streaming ASR, text-to-speech,
/// VAD, speaker identification, speaker diarization, punctuation restoration,
/// audio tagging, spoken language identification, speech denoising, and WAV
/// I/O helpers from a single entry point.
///
/// Before creating any runtime object, call [initBindings] (native) or
/// [initBindingsAsync] (all platforms including web) once so the package can
/// load the underlying native `sherpa-onnx-c-api` library for the current
/// platform.
///
/// For concrete end-to-end usage, see `dart-api-examples/` in the repository,
/// especially:
///
/// - `non-streaming-asr/bin/sense-voice.dart`
/// - `non-streaming-asr/bin/whisper.dart`
/// - `non-streaming-asr/bin/nemo-transducer.dart`
/// - `streaming-asr/bin/zipformer-transducer.dart`
/// - `tts/bin/pocket-en.dart`
/// - `vad/bin/vad.dart`
/// - `speaker-diarization/`

export 'src/audio_tagging_config.dart';
export 'src/audio_tagging.dart';
export 'src/feature_config.dart';
export 'src/homophone_replacer_config.dart';
export 'src/keyword_spotter_config.dart';
export 'src/keyword_spotter.dart';
export 'src/offline_punctuation_config.dart';
export 'src/offline_punctuation.dart';
export 'src/offline_recognizer_config.dart';
export 'src/offline_recognizer.dart';
export 'src/offline_speaker_diarization_config.dart';
export 'src/offline_speaker_diarization.dart';
export 'src/offline_speech_denoiser_config.dart';
export 'src/offline_speech_denoiser.dart';
export 'src/offline_stream.dart';
export 'src/online_speech_denoiser_config.dart';
export 'src/online_speech_denoiser.dart';
export 'src/online_punctuation_config.dart';
export 'src/online_punctuation.dart';
export 'src/online_recognizer_config.dart';
export 'src/online_recognizer.dart';
export 'src/online_stream.dart';
export 'src/speaker_identification_config.dart';
export 'src/speaker_identification.dart';
export 'src/spoken_language_identification_config.dart';
export 'src/spoken_language_identification.dart';
export 'src/tts_config.dart';
export 'src/tts.dart';
export 'src/vad_config.dart';
export 'src/vad.dart';
export 'src/version.dart';
export 'src/wave_reader_config.dart';
export 'src/wave_reader.dart';
export 'src/wave_writer.dart';

String? _path;

/// Initialize the native sherpa-onnx bindings.
///
/// **Important:** This must be called in every isolate that uses sherpa-onnx.
/// Each isolate has its own FFI binding state, so calling `initBindings()` in
/// one isolate does NOT make sherpa-onnx available in other isolates. If you
/// use Dart isolates for background work (e.g., TTS generation, model loading),
/// call `initBindings()` in each isolate before calling any sherpa-onnx API.
///
/// On web, use [initBindingsAsync] instead. This method throws
/// [UnsupportedError] on web.
void initBindings([String? p]) {
  _path ??= p;
  init.initNativeBindings(_path);
}

/// Initialize the sherpa-onnx bindings (works on all platforms including web).
///
/// On web, this loads the WASM module and JS wrappers automatically.
/// On native platforms, this behaves the same as [initBindings].
///
/// **Important:** If you use Dart isolates, call `initBindings()` or
/// `initBindingsAsync()` in each isolate that calls sherpa-onnx APIs.
/// See [initBindings] for details.
Future<void> initBindingsAsync([String? p]) async {
  _path ??= p;
  init.initNativeBindings(_path);
}
