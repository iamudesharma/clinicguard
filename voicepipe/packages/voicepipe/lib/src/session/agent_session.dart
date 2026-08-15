/// The conversation loop: VAD -> STT -> LLM -> TTS, with barge-in and
/// the ClinicGuard-compatible event contract.
///
/// Agent states (published as `agent_state`): idle | listening | thinking |
/// speaking.
///
/// Events (published on the data channel, `type` field):
///   user_transcript {text, is_final, language}
///   assistant_text  {text}
///   agent_state     {state}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../llm/llm.dart';
import '../speech/interfaces.dart';
import '../speech/resample.dart';

enum AgentState { idle, listening, thinking, speaking }

class AgentEvent {
  final Map<String, dynamic> payload;
  const AgentEvent(this.payload);
}

/// One voice call: receives 48 kHz stereo PCM from the transport and emits
/// 48 kHz stereo 20 ms TTS frames. Coordinates VAD/STT/LLM/TTS.
class AgentSession {
  final VoicepipeVAD _vad;
  final VoicepipeSTT _stt;
  final VoicepipeTTS _tts;
  final VoicepipeLlm _llm;
  final String _systemPrompt;
  final StreamController<AgentEvent> _events =
      StreamController<AgentEvent>.broadcast();
  final StreamController<Int16List> _ttsOut =
      StreamController<Int16List>.broadcast();
  final StreamController<bool> _speaking =
      StreamController<bool>.broadcast();

  final List<ChatMessage> _history = [];
  final List<double> _vadWindow = []; // 16k mono float pending window

  AgentState _state = AgentState.idle;
  bool _interrupt = false;
  bool _processing = false;
  bool _seeded = false;
  final List<Float32List> _segmentQueue = [];

  /// Events for the data channel.
  Stream<AgentEvent> get events => _events.stream;

  /// 48 kHz stereo interleaved 20 ms frames to send to the caller.
  Stream<Int16List> get ttsAudio => _ttsOut.stream;

  /// Fires with the current speaking state (for local UI/ducking).
  Stream<bool> get speaking => _speaking.stream;

  AgentSession({
    required VoicepipeVAD vad,
    required VoicepipeSTT stt,
    required VoicepipeTTS tts,
    required VoicepipeLlm llm,
    String? systemPrompt,
  })  : _vad = vad,
        _stt = stt,
        _tts = tts,
        _llm = llm,
        _systemPrompt = systemPrompt ?? _defaultPrompt;

  static const _defaultPrompt =
      'You are a voice triage assistant for a clinic. Ask concise questions '
      'about symptoms and keep replies under 40 words.';

  AgentState get state => _state;

  void _setState(AgentState s) {
    if (_state == s) return;
    _state = s;
    _events.add(AgentEvent({
      'type': 'agent_state',
      'state': s.name,
    }));
  }

  /// Speak an opening line (e.g. the greeting) before the caller talks.
  Future<void> greet(String text) async {
    if (!_seeded) {
      _seeded = true;
      _history.add(ChatMessage('system', _systemPrompt));
    }
    _history.add(ChatMessage('assistant', text));
    _events.add(AgentEvent({'type': 'assistant_text', 'text': text}));
    await _speak(text);
  }

  /// Ask the LLM for a structured summary of the conversation.
  /// Returns null when the LLM reply cannot be parsed as JSON.
  Future<Map<String, dynamic>?> generateSummary({ChatMessage? extra}) async {
    try {
      // Only user/assistant turns: including the triage system prompt makes
      // the model stay in agent role instead of producing the summary.
      final transcript = _history
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => '${m.role}: ${m.content}')
          .join('\n');
      final reply = await _llm.reply([
        ChatMessage(
            'system',
            'Summarize the following triage call as JSON with EXACTLY these '
            'keys: patient_name, chief_complaint (the patient\'s main problem '
            'from the USER turns, e.g. "fever and headache"), symptoms '
            '(array of strings from the USER turns), urgency_level '
            '(low|medium|high|emergency), reason, recommendation, language. '
            'Reply with the JSON object only.\n\n'
            'TRANSCRIPT:\n$transcript'),
        if (extra != null) extra,
      ]);
      return _extractJson(reply);
    } catch (e) {
      print('[voicepipe] summary generation error: $e');
      return null;
    }
  }

  Map<String, dynamic>? _extractJson(String reply) {
    try {
      final trimmed = reply.trim();
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start >= 0 && end > start) {
        final decoded =
            jsonDecode(trimmed.substring(start, end + 1)) as Map<String, dynamic>;
        return decoded;
      }
      final direct = jsonDecode(trimmed);
      if (direct is Map<String, dynamic>) return direct;
    } catch (_) {}
    return null;
  }

  /// Client-initiated barge-in: stop speaking immediately.
  void interrupt() {
    _interrupt = true;
    _setState(AgentState.listening);
  }

  /// Feed decoded caller audio (48 kHz stereo interleaved).
  void onAudio(Int16List pcm48kStereo) {
    // Always feed the VAD so utterance tails are never lost; completed
    // segments are queued while a turn is in flight.
    final mono16k = downmixAndResample(pcm48kStereo, 48000, 2, 16000);
    _vadWindow.addAll(mono16k);
    final windowSize = _vad.windowSize;
    while (_vadWindow.length >= windowSize) {
      final frame = Float32List.fromList(_vadWindow.sublist(0, windowSize));
      _vadWindow.removeRange(0, windowSize);
      final segment = _vad.accept(frame);
      if (segment != null) {
        if (_processing) {
          if (_state == AgentState.speaking) {
            // barge-in: user started talking over us
            _interrupt = true;
            _setState(AgentState.listening);
          }
          _segmentQueue.add(segment);
        } else {
          unawaited(_handleSegment(segment));
        }
      }
    }
  }

  Future<void> _handleSegment(Float32List segment) async {
    // Reject noise bursts (applause, clicks): require audible speech energy.
    if (_segmentRms(segment) < 0.01) return;
    if (_state == AgentState.speaking) {
      // barge-in: user started talking over us
      _interrupt = true;
      _setState(AgentState.listening);
    }
    if (_processing) return;
    _processing = true;
    try {
      _setState(AgentState.thinking);
      if (!_seeded) {
        _seeded = true;
        _history.add(ChatMessage('system', _systemPrompt));
      }
      final text = await _transcribe(segment);
      if (text.isEmpty) return;

      _events.add(AgentEvent({
        'type': 'user_transcript',
        'text': text,
        'is_final': true,
        'language': 'auto',
      }));
      _history.add(ChatMessage('user', text));

      final reply = await _llm.reply([..._history]);
      _history.add(ChatMessage('assistant', reply));
      _events.add(AgentEvent({
        'type': 'assistant_text',
        'text': reply,
      }));

      await _speak(reply);
    } catch (e) {
      _events.add(AgentEvent({'type': 'agent_error', 'error': '$e'}));
    } finally {
      _processing = false;
      _setState(AgentState.listening);
      if (_segmentQueue.isNotEmpty) {
        unawaited(_handleSegment(_segmentQueue.removeAt(0)));
      }
    }
  }

  Future<String> _transcribe(Float32List segment) async {
    // sherpa bindings are per-isolate; keep transcription on this isolate.
    // whisper tiny int8 transcribes ~10s of audio in well under a second.
    return _stt.transcribe(segment);
  }

  Future<void> _speak(String text) async {
    _interrupt = false;
    _setState(AgentState.speaking);
    _speaking.add(true);
    try {
      final audio = _tts.synthesize(text);
      if (audio.samples.isEmpty) return;
      // piper: 22050 Hz mono -> upsample to 48k, emit 20 ms stereo frames.
      final ups = resampleUp(audio.samples, audio.sampleRate, 48000);
      final stereo = toPcm16Stereo(ups, 2);
      const frameLen = 48000 * 2 ~/ 50; // 1920
      for (var i = 0; i + frameLen <= stereo.length; i += frameLen) {
        if (_interrupt) {
          _events.add(AgentEvent({'type': 'agent_state', 'state': 'listening'}));
          return;
        }
        _ttsOut.add(Int16List.sublistView(stereo, i, i + frameLen));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _speaking.add(false);
      _setState(AgentState.listening);
    }
  }

  double _segmentRms(Float32List segment) {
    if (segment.isEmpty) return 0;
    var sum = 0.0;
    for (final s in segment) {
      sum += s * s;
    }
    return sqrt(sum / segment.length);
  }

  /// Fire-and-forget cleanup when the call ends.
  void endCall() {
    final finalSegment = _vad.flush();
    if (finalSegment != null) {
      unawaited(_handleSegment(finalSegment));
    }
    _history.clear();
    _seeded = false;
  }

  void dispose() {
    _events.close();
    _ttsOut.close();
    _speaking.close();
  }
}
