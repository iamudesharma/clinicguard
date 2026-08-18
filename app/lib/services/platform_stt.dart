import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text/speech_to_text.dart' show SpeechListenOptions;

/// Platform-specific STT service using Apple's SFSpeechRecognizer (macOS/iOS),
/// Web Speech API (Chrome), or Google STT (Android).
///
/// Falls back gracefully when the platform doesn't support speech recognition.
class PlatformSttService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;
  bool _available = false;
  String _currentLocaleId = '';

  final _resultController = StreamController<SttResult>.broadcast();
  final _statusController = StreamController<SttStatus>.broadcast();

  /// Stream of recognition results (partial and final).
  Stream<SttResult> get results => _resultController.stream;

  /// Stream of status changes (listening, notListening, etc).
  Stream<SttStatus> get statusChanges => _statusController.stream;

  /// Whether the platform STT is available.
  bool get isAvailable => _available;

  /// Whether currently listening.
  bool get isListening => _speech.isListening;

  /// Available locales for speech recognition.
  Future<List<SttLocale>> getLocales() async {
    if (!_available) return [];
    final locales = await _speech.locales();
    return locales
        .map((l) => SttLocale(
              localeId: l.localeId,
              name: l.name,
            ))
        .toList();
  }

  /// Initialize the platform STT. Returns true if available.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      _available = await _speech.initialize(
        onStatus: (status) {
          debugPrint('[PlatformStt] status: $status');
          final s = sttStatusFromString(status);
          _statusController.add(s);
          // Auto-restart on 'done' to prevent silent stops.
          if (s == SttStatus.done && _currentLocaleId.isNotEmpty) {
            _autoRestart();
          }
        },
        onError: (error) {
          debugPrint('[PlatformStt] error: ${error.errorMsg} (code: ${error.permanent})');
          if (!error.permanent) {
            _statusController.add(SttStatus.notListening);
          } else {
            _statusController.add(SttStatus.notListening);
          }
        },
        // webDoNotAggregate fixes duplicate results on Android Chrome.
        options: kIsWeb ? [stt.SpeechToText.webDoNotAggregate] : null,
      );
      if (_available) {
        debugPrint('[PlatformStt] initialized OK');
      } else {
        debugPrint('[PlatformStt] not available on this platform');
      }
    } catch (e) {
      debugPrint('[PlatformStt] init failed: $e');
      _available = false;
    }
    return _available;
  }

  /// Auto-restart listening after a 'done' status (platform stopped due
  /// to silence timeout). This keeps recognition alive across pauses.
  void _autoRestart() {
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!_speech.isListening && _currentLocaleId.isNotEmpty) {
        debugPrint('[PlatformStt] auto-restarting after done');
        startListening(localeId: _currentLocaleId);
      }
    });
  }

  /// Start listening for speech.
  ///
  /// Uses the modern SpeechListenOptions API (no deprecated params).
  /// [localeId] — e.g. 'en-IN' for English (India), 'hi-IN' for Hindi.
  Future<void> startListening({
    String localeId = '',
  }) async {
    if (!_available) {
      debugPrint('[PlatformStt] not available, cannot listen');
      return;
    }
    // Don't start if already listening — prevents race conditions.
    if (_speech.isListening) {
      debugPrint('[PlatformStt] already listening, skipping');
      return;
    }
    _currentLocaleId = localeId;
    try {
      await _speech.listen(
        onResult: _onResult,
        localeId: localeId.isEmpty ? null : localeId,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: stt.ListenMode.dictation,
          autoPunctuation: true,
        ),
        // Long listen duration (10 min) — auto-restart handles pauses.
        listenFor: const Duration(minutes: 10),
        // Generous pause: 8 seconds before the platform considers the
        // utterance complete. Apple's dictation uses ~3-5s.
        pauseFor: const Duration(seconds: 8),
      );
      debugPrint('[PlatformStt] listening (locale: $localeId)');
    } catch (e) {
      debugPrint('[PlatformStt] listen failed: $e');
    }
  }

  /// Stop listening.
  Future<void> stopListening() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
  }

  /// Cancel the current listening session.
  Future<void> cancel() async {
    if (_speech.isListening) {
      await _speech.cancel();
    }
  }

  void _onResult(SpeechRecognitionResult result) {
    _resultController.add(SttResult(
      text: result.recognizedWords,
      isFinal: result.finalResult,
      confidence: result.confidence,
      localeId: _currentLocaleId,
    ));
  }

  void dispose() {
    _resultController.close();
    _statusController.close();
    _speech.stop();
  }
}

/// A speech recognition result.
class SttResult {
  final String text;
  final bool isFinal;
  final double confidence;
  final String localeId;

  const SttResult({
    required this.text,
    required this.isFinal,
    this.confidence = 0.0,
    this.localeId = '',
  });
}

/// A locale available for speech recognition.
class SttLocale {
  final String localeId;
  final String name;

  const SttLocale({required this.localeId, required this.name});
}

/// Speech recognition status.
enum SttStatus { listening, notListening, done }

SttStatus sttStatusFromString(String s) {
  switch (s) {
    case 'listening':
      return SttStatus.listening;
    case 'notListening':
      return SttStatus.notListening;
    case 'done':
      return SttStatus.done;
    default:
      return SttStatus.notListening;
  }
}
