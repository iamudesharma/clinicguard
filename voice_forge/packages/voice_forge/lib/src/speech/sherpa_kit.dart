/// sherpa-onnx speech implementations of the voice_forge interfaces.
///
/// The native `libsherpa-onnx-c-api` library is loaded by the host process.
/// On first run it is downloaded automatically from the official sherpa-onnx
/// releases into a user cache (see `native_download.dart`); set
/// `autoDownload: false` on [SherpaKit.load] to manage it manually.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:voice_forge_speech/voice_forge_speech.dart' as sherpa;

import 'interfaces.dart';
import 'native_download.dart';
import 'worker.dart';

/// Locate + load the sherpa-onnx native library.
///
/// Probes the usual places first (repo layout, current directory, system
/// search path, cache); if none exist and [autoDownload] is set, downloads
/// the prebuilt library from the official sherpa-onnx release into the user
/// cache (~/.cache/voice_forge/native, or `VOICE_FORGE_NATIVE_DIR`).
Future<DynamicLibrary> loadSherpaLibrary({bool autoDownload = true}) async {
  final os = Platform.operatingSystem;
  final arch = Platform.version.contains('arm64') ? 'arm64' : 'x86_64';
  final dylib = os == 'macos'
      ? 'libsherpa-onnx-c-api.dylib'
      : 'libsherpa-onnx-c-api.so';
  final cacheDir = nativeCacheDir();
  final candidates = <String>[
    'third_party/native/$os-$arch/$dylib',
    '${Directory.current.path}/../../third_party/native/$os-$arch/$dylib',
    '$cacheDir/$dylib',
    dylib,
    'sherpa-onnx-c-api.dll',
  ];
  for (final path in candidates) {
    try {
      return DynamicLibrary.open(path);
    } catch (_) {}
  }
  if (autoDownload) {
    final libPath = await downloadNativeLibrary(cacheDir);
    return DynamicLibrary.open(libPath);
  }
  throw StateError(
    'libsherpa-onnx-c-api not found. Either re-enable auto-download or '
    'download the prebuilt library from the official sherpa-onnx releases '
    'and place it in the current directory or on the system library search '
    'path (see the voice_forge_speech README).',
  );
}

/// Fetches the standard speech models into [models]' directories when the
/// expected files are missing (silero VAD, whisper encoder/decoder + tokens,
/// piper en_US-lessac-medium int8). Model URLs come from the official
/// sherpa-onnx releases.
Future<void> ensureModels(SherpaModels models) async {
  const asrBase = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';
  if (!File(models.sileroVad).existsSync()) {
    await downloadFile('$asrBase/asr-models/silero_vad.onnx', models.sileroVad);
  }
  if (!Directory(models.whisperDir).existsSync()) {
    final parent = File(models.whisperDir).parent.path;
    await extractTarball(
      '$asrBase/asr-models/sherpa-onnx-whisper-${models.whisperPrefix}.tar.bz2',
      parent,
    );
  }
  if (!Directory(models.piperDir).existsSync()) {
    final parent = File(models.piperDir).parent.path;
    await extractTarball(
      '$asrBase/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2',
      parent,
    );
  }
}

/// Model paths for the sherpa speech stack (whisper encoder/decoder + piper).
class SherpaModels {
  final String sileroVad;
  final String whisperDir;
  final String whisperPrefix; // e.g. "tiny" or "base" (encoder/decoder files)
  final String piperDir;
  final String? streamingDir; // e.g. 'models/streaming-zipformer-b-ctc-small'
  final String whisperLanguage; // e.g. 'en', 'hi', '' (auto-detect)
  final String whisperTask; // 'transcribe' or 'translate'
  final String streamingModelType; // 'zipformer2' or 'nemo'

  const SherpaModels({
    required this.sileroVad,
    required this.whisperDir,
    this.whisperPrefix = 'tiny',
    required this.piperDir,
    this.streamingDir,
    this.whisperLanguage = '',
    this.whisperTask = 'transcribe',
    this.streamingModelType = 'zipformer2',
  });

  /// Standard layout under [modelsDir]: `silero_vad.onnx`,
  /// `sherpa-onnx-whisper-<prefix>/`, `vits-piper-en_US-lessac-medium-int8/`.
  factory SherpaModels.fromModelsDir(
    String modelsDir, {
    String whisperPrefix = 'tiny',
    String? streamingDir,
    String whisperLanguage = '',
    String whisperTask = 'transcribe',
    String streamingModelType = 'zipformer2',
  }) {
    return SherpaModels(
      sileroVad: '$modelsDir/silero_vad.onnx',
      whisperDir: '$modelsDir/sherpa-onnx-whisper-$whisperPrefix',
      whisperPrefix: whisperPrefix,
      piperDir: '$modelsDir/vits-piper-en_US-lessac-medium-int8',
      streamingDir: streamingDir,
      whisperLanguage: whisperLanguage,
      whisperTask: whisperTask,
      streamingModelType: streamingModelType,
    );
  }
}

/// One owned set of sherpa-onnx runtime objects; expose each interface
/// implementation backed by the same native instances.
class SherpaKit {
  final List<sherpa.VoiceActivityDetector> _vads = [];
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.OfflineTts? _tts;
  sherpa.OnlineRecognizer? _onlineRecognizer;
  SpeechWorker? _worker;
  late SherpaModels _models;

  static bool _bound = false;

  /// Ensures the native library is loaded (downloading it on first run when
  /// [autoDownload] is enabled) and initializes the bindings.
  static Future<void> loadNative({bool autoDownload = true}) async {
    if (_bound) return;
    final lib = await loadSherpaLibrary(autoDownload: autoDownload);
    sherpa.setSherpaLibrary(lib); // vendored patch: inject the handle
    sherpa.initBindings();
    _bound = true;
  }

  /// Loads bindings + all models (downloading the native library and any
  /// missing standard models on first run unless [autoDownload] is false).
  /// [models] selects the whisper prefix.
  static Future<SherpaKit> load({
    required SherpaModels models,
    bool autoDownload = true,
  }) async {
    await loadNative(autoDownload: autoDownload);
    if (autoDownload) {
      await ensureModels(models);
    }
    final kit = SherpaKit._().._models = models;

    kit._recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder:
                '${models.whisperDir}/${models.whisperPrefix}-encoder.int8.onnx',
            decoder:
                '${models.whisperDir}/${models.whisperPrefix}-decoder.int8.onnx',
            language: models.whisperLanguage,
            task: models.whisperTask,
          ),
          tokens: '${models.whisperDir}/${models.whisperPrefix}-tokens.txt',
          modelType: 'whisper',
          debug: false,
          numThreads: 2,
        ),
      ),
    );

    kit._tts = sherpa.OfflineTts(
      sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: '${models.piperDir}/en_US-lessac-medium.onnx',
            tokens: '${models.piperDir}/tokens.txt',
            dataDir: '${models.piperDir}/espeak-ng-data',
            lengthScale: 1.0,
          ),
          numThreads: 1,
          debug: false,
        ),
      ),
    );

    // Streaming STT — optional, used for partial transcripts.
    // Supports both Zipformer2 and Nemotron (NeMo transducer) architectures.
    if (models.streamingDir != null) {
      final dir = models.streamingDir!;
      try {
        // Determine model files based on architecture type.
        String encoder, decoder, joiner;
        if (models.streamingModelType == 'nemo') {
          // Nemotron: files use simple names (encoder.int8.onnx, etc.)
          encoder = '$dir/encoder.int8.onnx';
          decoder = '$dir/decoder.int8.onnx';
          joiner = '$dir/joiner.int8.onnx';
        } else {
          // Zipformer: files use chunk suffix
          encoder = '$dir/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx';
          decoder = '$dir/decoder-epoch-99-avg-1-chunk-16-left-128.onnx';
          joiner = '$dir/joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx';
        }
        kit._onlineRecognizer = sherpa.OnlineRecognizer(
          sherpa.OnlineRecognizerConfig(
            model: sherpa.OnlineModelConfig(
              transducer: sherpa.OnlineTransducerModelConfig(
                encoder: encoder,
                decoder: decoder,
                joiner: joiner,
              ),
              tokens: '$dir/tokens.txt',
              modelType: models.streamingModelType,
              numThreads: 2,
              debug: false,
            ),
            enableEndpoint: true,
            rule1MinTrailingSilence: 2.4,
            rule2MinTrailingSilence: 1.2,
            rule3MinUtteranceLength: 20,
          ),
        );
      } catch (e) {
        print('streaming STT init failed ($e); '
            'falling back to batch Whisper');
      }
    }

    return kit;
  }

  SherpaKit._();

  /// A FRESH VAD instance. The Silero VAD is stateful: one instance MUST NOT
  /// be shared across concurrent sessions (interleaved audio corrupts the
  /// segment detection). Call once per session.
  VoicepipeVAD createVad() {
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: _models.sileroVad,
          minSilenceDuration: 0.30, // quick turn detection
          minSpeechDuration: 0.25,
          maxSpeechDuration: 15.0,
        ),
        sampleRate: 16000,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    _vads.add(vad);
    return _SherpaVad(vad);
  }

  /// Shared VAD for single-session tools (speech_check); NOT for servers
  /// that host multiple concurrent calls — use [createVad] there.
  VoicepipeVAD get vad => createVad();

  /// STT implementation (16 kHz mono float segments). Stateless per call:
  /// safe to share across sessions.
  VoicepipeSTT get stt => _SherpaStt(this);

  /// TTS implementation. Stateless per call: safe to share.
  VoicepipeTTS get tts => _SherpaTts(this);

  /// Streaming STT implementation (partial transcripts). Returns null if
  /// the streaming model was not loaded.
  VoicepipeStreamingSTT? get streamingStt =>
      _onlineRecognizer != null ? _SherpaStreamingStt(_onlineRecognizer!) : null;

  /// Convenience: all three implementations in one place.
  ({VoicepipeVAD Function() vadFactory, VoicepipeSTT stt, VoicepipeTTS tts})
  get speech => (vadFactory: createVad, stt: stt, tts: tts);

  /// STT/TTS implementations that run in a long-lived worker isolate, so the
  /// sync sherpa-onnx FFI calls (transcription/synthesis) never stall the
  /// main isolate's event loop (RTP decode + VAD barge-in). The worker
  /// re-initializes the native library + models in its own isolate; the
  /// main-isolate instances above stay alive for single-session tools and
  /// self-tests. Falls back to them on ANY worker init error — the voice
  /// loop must never die because the worker failed.
  Future<({VoicepipeSTT stt, VoicepipeTTS tts})> createWorkerSpeech() async {
    try {
      final worker = await SpeechWorker.start(models: _models);
      _worker = worker;
      return (stt: _WorkerStt(worker), tts: _WorkerTts(worker));
    } catch (e) {
      print('speech worker init failed ($e); '
          'falling back to main-isolate STT/TTS');
      return (stt: _SherpaStt(this), tts: _SherpaTts(this));
    }
  }

  void dispose() {
    _worker?.dispose();
    _worker = null;
    for (final vad in _vads) {
      vad.free();
    }
    _vads.clear();
    _recognizer?.free();
    _tts?.free();
    _onlineRecognizer?.free();
    _recognizer = null;
    _tts = null;
    _onlineRecognizer = null;
  }
}

class _SherpaVad implements VoicepipeVAD {
  final sherpa.VoiceActivityDetector _vad;
  _SherpaVad(this._vad);

  @override
  int get windowSize => 512;

  @override
  Float32List? accept(Float32List frame) {
    _vad.acceptWaveform(frame);
    if (_vad.isDetected()) return null; // still talking
    if (_vad.isEmpty()) return null; // no completed segment
    final seg = _vad.front();
    _vad.pop();
    return seg.samples;
  }

  @override
  Float32List? flush() {
    _vad.flush();
    if (_vad.isEmpty()) return null;
    final seg = _vad.front();
    _vad.pop();
    return seg.samples;
  }
}

class _SherpaStt implements VoicepipeSTT {
  final SherpaKit kit;
  _SherpaStt(this.kit);

  @override
  Future<String> transcribe(Float32List segment16k) async {
    final stream = kit._recognizer!.createStream();
    stream.acceptWaveform(samples: segment16k, sampleRate: 16000);
    kit._recognizer!.decode(stream);
    final result = kit._recognizer!.getResult(stream);
    stream.free();
    return result.text.trim();
  }
}

class _SherpaStreamingStt implements VoicepipeStreamingSTT {
  final sherpa.OnlineRecognizer _recognizer;
  late sherpa.OnlineStream _stream;

  _SherpaStreamingStt(this._recognizer) {
    _stream = _recognizer.createStream();
  }

  /// Set language hint for multilingual models (e.g. Nemotron 3.5).
  /// [lang] — e.g. 'en-US', 'hi-IN', or 'auto' for auto-detection.
  @override
  void setLanguage(String lang) {
    _stream.setOption(key: 'language', value: lang);
  }

  @override
  String acceptFrame(Float32List frame) {
    _stream.acceptWaveform(samples: frame, sampleRate: 16000);
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    return _recognizer.getResult(_stream).text;
  }

  @override
  String finalize() {
    // Add tail padding to flush the recognizer
    final tail = Float32List(8000); // 0.5s silence at 16kHz
    _stream.acceptWaveform(samples: tail, sampleRate: 16000);
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    final result = _recognizer.getResult(_stream).text.trim();
    _stream.free();
    _stream = _recognizer.createStream();
    return result;
  }

  @override
  void reset() {
    _stream.free();
    _stream = _recognizer.createStream();
  }
}

class _SherpaTts implements VoicepipeTTS {
  final SherpaKit kit;
  _SherpaTts(this.kit);

  @override
  Future<TtsAudio> synthesize(String text) async {
    final audio = kit._tts!.generate(text: text, speed: 1.0, sid: 0);
    return TtsAudio(samples: audio.samples, sampleRate: audio.sampleRate);
  }
}

class _WorkerStt implements VoicepipeSTT {
  final SpeechWorker worker;
  _WorkerStt(this.worker);

  @override
  Future<String> transcribe(Float32List segment16k) =>
      worker.transcribe(segment16k);
}

class _WorkerTts implements VoicepipeTTS {
  final SpeechWorker worker;
  _WorkerTts(this.worker);

  @override
  Future<TtsAudio> synthesize(String text) => worker.synthesize(text);
}
