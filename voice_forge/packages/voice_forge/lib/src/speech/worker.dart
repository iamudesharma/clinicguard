/// Worker-isolate STT/TTS for the voice agent.
///
/// sherpa-onnx runs its native inference as sync FFI calls; on the main
/// isolate those stall the event loop (RTP decode + the agent's VAD barge-in
/// gate). This worker re-initializes the native library + models in its own
/// isolate (Dart statics and native pointers don't cross isolates) and
/// answers STT/TTS requests one at a time. The worker isolate owns its
/// `OfflineRecognizer`/`OfflineTts` instances.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:voice_forge_speech/voice_forge_speech.dart' as sherpa;

import 'interfaces.dart';
import 'sherpa_kit.dart' show SherpaModels, loadSherpaLibrary;

/// Long-lived worker isolate that runs transcription and synthesis off the
/// main isolate.
///
/// Requests are correlated by an incrementing id; the worker processes them
/// serially (one sync FFI call at a time), which matches the session's
/// already-serialized STT/TTS calls. Call [dispose] when done to kill the
/// isolate.
class SpeechWorker {
  SpeechWorker._(this._isolate, this._replies) {
    _replies.listen(_onReply);
  }

  /// Spawns the worker isolate, waits for it to initialize the native
  /// library + models, and returns once it reports ready. Throws if init
  /// fails inside the worker.
  static Future<SpeechWorker> start({required SherpaModels models}) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(_entry, [replies.sendPort, models]);
    final worker = SpeechWorker._(isolate, replies);
    await worker._ready.future; // rethrows worker init errors
    return worker;
  }

  final Isolate _isolate;
  final ReceivePort _replies;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  SendPort? _requests; // set when the worker reports ready
  int _nextId = 0;

  /// Transcribe a 16 kHz mono float segment; returns the trimmed text.
  Future<String> transcribe(Float32List samples) async {
    final result = await _request({'op': 'stt', 'samples': samples});
    return result as String;
  }

  /// Synthesize speech for [text].
  Future<TtsAudio> synthesize(String text) async {
    final result = await _request({'op': 'tts', 'text': text});
    return result as TtsAudio;
  }

  Future<Object?> _request(Map<String, Object?> request) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _requests!.send({'id': id, ...request});
    return completer.future;
  }

  void _onReply(Object? message) {
    final reply = message as Map;
    if (reply['ready'] != null) {
      if (reply['ready'] == true) {
        _requests = reply['requests'] as SendPort;
        _ready.complete();
      } else {
        _ready.completeError(
          StateError('speech worker init failed: ${reply['error']}'),
        );
      }
      return;
    }
    final completer = _pending.remove(reply['id'] as int);
    if (completer == null) return; // stale reply
    final text = reply['text'];
    if (text != null) {
      completer.complete(text as String);
    } else {
      completer.complete(
        TtsAudio(
          samples: reply['samples'] as Float32List,
          sampleRate: reply['sampleRate'] as int,
        ),
      );
    }
  }

  /// Kills the worker isolate (best-effort shutdown notice first so the
  /// worker can release its native objects).
  void dispose() {
    _requests?.send({'op': 'shutdown'});
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

/// Worker isolate entry: init native bindings + models, then serve requests.
Future<void> _entry(List<Object?> message) async {
  final replyPort = message[0] as SendPort;
  final models = message[1] as SherpaModels;
  final requests = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  sherpa.OfflineTts? tts;
  try {
    final lib = await loadSherpaLibrary(autoDownload: false);
    sherpa.setSherpaLibrary(lib); // vendored patch: inject the handle
    sherpa.initBindings();
    // Mirror SherpaKit.load's exact configs.
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder:
                '${models.whisperDir}/${models.whisperPrefix}-encoder.int8.onnx',
            decoder:
                '${models.whisperDir}/${models.whisperPrefix}-decoder.int8.onnx',
            language: '', // auto-detect (en/hi)
          ),
          tokens: '${models.whisperDir}/${models.whisperPrefix}-tokens.txt',
          modelType: 'whisper',
          debug: false,
          numThreads: 2,
        ),
      ),
    );
    tts = sherpa.OfflineTts(
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
    replyPort.send({'ready': true, 'requests': requests.sendPort});
  } catch (e, st) {
    // Reported so createWorkerSpeech can fall back to the main isolate.
    replyPort.send({'ready': false, 'error': '$e\n$st'});
    requests.close();
    return;
  }

  await for (final message in requests) {
    final request = message as Map;
    final id = request['id'] as int;
    final op = request['op'] as String;
    if (op == 'shutdown') break;
    if (op == 'stt') {
      final samples = request['samples'] as Float32List;
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      replyPort.send({'id': id, 'text': text});
    } else if (op == 'tts') {
      final audio = tts.generate(
        text: request['text'] as String,
        speed: 1.0,
        sid: 0,
      );
      replyPort.send({
        'id': id,
        'samples': audio.samples,
        'sampleRate': audio.sampleRate,
      });
    }
  }
  recognizer.free();
  tts.free();
  requests.close();
}
