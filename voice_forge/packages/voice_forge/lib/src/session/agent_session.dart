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

/// Crash-proof log: piped stdout can throw "StreamSink is bound to a stream"
/// under backpressure; never let a log line break the turn flow.
void _safeLog(String message) {
  try {
    print(message);
  } catch (_) {}
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
  int _voicedOnsetRun = 0;

  /// Bumped every time a NEW utterance begins (barge-in onset). Segments
  /// captured before the bump are stale: they must never reach the LLM ahead
  /// of (or instead of) what the user is saying now.
  int _epoch = 0;

  /// Completed segments awaiting a turn, tagged with the epoch they were
  /// captured in. Stale entries are skipped when the turn frees up.
  final List<({Float32List samples, int epoch})> _segmentQueue = [];

  /// Audio being merged while the user pauses mid-utterance (one turn).
  final List<Float32List> _pendingSegments = [];
  int _pendingEpoch = -1;
  Timer? _mergeTimer;

  /// How long to wait for a paused utterance to continue before sending it
  /// to the LLM as one turn.
  static const _mergeWindow = Duration(milliseconds: 450);

  // Tool calling + retrieval hooks (see [configure]).
  List<ToolDef> _tools = const [];
  Future<String> Function(LlmToolCall call)? _toolExecutor;
  Future<String?> Function(String userText)? _knowledgeProvider;

  /// RMS (0..1) above which a 32 ms window counts as the user speaking
  /// while the agent is talking (instant onset barge-in). Raise it when the
  /// mic picks up the agent's own TTS on speakers (no AEC in the pipeline).
  final double _bargeInRmsThreshold;

  /// Consecutive voiced windows required to declare an onset (~64 ms).
  final int _bargeInOnsetFrames;

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
    double bargeInRmsThreshold = 0.03,
    int bargeInOnsetFrames = 2,
  })  : _vad = vad,
        _stt = stt,
        _tts = tts,
        _llm = llm,
        _systemPrompt = systemPrompt ?? _defaultPrompt,
        _bargeInRmsThreshold = bargeInRmsThreshold,
        _bargeInOnsetFrames = bargeInOnsetFrames;

  static const _defaultPrompt =
      'You are a voice triage assistant for a clinic. Ask concise questions '
      'about symptoms and keep replies under 40 words.';

  AgentState get state => _state;

  /// Enable tool calling and per-turn knowledge retrieval.
  ///
  /// [tools] is offered to the LLM each turn; when the model requests a call,
  /// [toolExecutor] runs it and must return a JSON string (the `tool`-role
  /// message fed back to the model). [knowledgeProvider] is called with the
  /// latest user transcript before each LLM turn; its return value (a short
  /// grounded-knowledge block, or null when nothing relevant was found) is
  /// injected as system context for that turn only.
  void configure({
    List<ToolDef> tools = const [],
    Future<String> Function(LlmToolCall call)? toolExecutor,
    Future<String?> Function(String userText)? knowledgeProvider,
  }) {
    _tools = tools;
    _toolExecutor = toolExecutor;
    _knowledgeProvider = knowledgeProvider;
  }

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

  /// Inject a system-level context block (e.g. the patient chart) that the
  /// LLM sees for the rest of the call. Safe to call before or after [greet];
  /// seeding happens automatically if needed.
  void addSystemContext(String text) {
    if (text.isEmpty) return;
    if (!_seeded) {
      _seeded = true;
      _history.add(ChatMessage('system', _systemPrompt));
    }
    _history.add(ChatMessage('system', text));
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
      _safeLog('[voice_forge] summary generation error: $e');
      return null;
    }
  }

  /// Ask the LLM a one-off structured question about the conversation
  /// (e.g. booking intent). Returns the parsed JSON map, or null.
  Future<Map<String, dynamic>?> askStructured({
    required String instruction,
    ChatMessage? extra,
  }) async {
    try {
      final transcript = _history
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => '${m.role}: ${m.content}')
          .join('\n');
      final reply = await _llm.reply([
        ChatMessage('system', '$instruction\n\nTRANSCRIPT:\n$transcript'),
        if (extra != null) extra,
      ]);
      return _extractJson(reply);
    } catch (e) {
      _safeLog('[voice_forge] structured ask error: $e');
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
    // The user started a new utterance: queued tails are stale, drop them.
    _beginNewUtterance();
  }

  /// A new utterance has begun: anything captured before now (queued tails,
  /// audio pending the merge window) must never be sent to the LLM.
  void _beginNewUtterance() {
    _epoch++;
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _pendingSegments.clear();
    _pendingEpoch = -1;
    _segmentQueue.clear();
  }

  /// A completed speech segment arrived from the VAD.
  void _onSegment(Float32List segment) {
    if (_state == AgentState.speaking) {
      // User started talking over us: everything queued so far is stale.
      _interrupt = true;
      _setState(AgentState.listening);
      _beginNewUtterance();
    }
    if (_processing) {
      _segmentQueue.add((samples: segment, epoch: _epoch));
    } else {
      _scheduleMerged(segment);
    }
  }

  /// Merge segments that arrive close together (a paused utterance) into a
  /// single LLM turn instead of sending each chunk separately.
  void _scheduleMerged(Float32List segment) {
    _pendingSegments.add(segment);
    _pendingEpoch = _epoch;
    _mergeTimer?.cancel();
    _mergeTimer = Timer(_mergeWindow, () {
      _mergeTimer = null;
      final epoch = _pendingEpoch;
      final merged = _mergePending();
      if (merged == null || epoch != _epoch) return;
      if (_processing) {
        _segmentQueue.add((samples: merged, epoch: epoch));
      } else {
        unawaited(_handleSegment(merged, epoch: epoch));
      }
    });
  }

  Float32List? _mergePending() {
    if (_pendingSegments.isEmpty) return null;
    var total = 0;
    for (final s in _pendingSegments) {
      total += s.length;
    }
    final out = Float32List(total);
    var offset = 0;
    for (final s in _pendingSegments) {
      out.setRange(offset, offset + s.length, s);
      offset += s.length;
    }
    _pendingSegments.clear();
    _pendingEpoch = -1;
    return out;
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
      if (_state == AgentState.speaking && !_interrupt) {
        // Instant onset barge-in: stop as soon as the user starts talking
        // over us (~64 ms), instead of waiting for the utterance to finish
        // (Silero only emits a completed segment after speech end + hangover).
        if (_segmentRms(frame) >= _bargeInRmsThreshold) {
          _voicedOnsetRun++;
          if (_voicedOnsetRun >= _bargeInOnsetFrames) {
            _voicedOnsetRun = 0;
            _interrupt = true;
            _setState(AgentState.listening);
            _beginNewUtterance();
          }
        } else {
          _voicedOnsetRun = 0;
        }
      } else {
        _voicedOnsetRun = 0;
      }
      final segment = _vad.accept(frame);
      if (segment != null) _onSegment(segment);
    }
  }

  Future<void> _handleSegment(Float32List segment, {required int epoch}) async {
    // Reject noise bursts (applause, clicks): require audible speech energy.
    if (_segmentRms(segment) < 0.01) return;
    if (_processing || _epoch != epoch) return;
    _processing = true;
    try {
      _setState(AgentState.thinking);
      if (!_seeded) {
        _seeded = true;
        _history.add(ChatMessage('system', _systemPrompt));
      }
      final text = await _transcribe(segment);
      // User started a new utterance while we transcribed: drop this stale
      // turn (no transcript, no LLM round trip, no reply).
      if (_epoch != epoch) return;
      if (text.isEmpty) return;

      _events.add(AgentEvent({
        'type': 'user_transcript',
        'text': text,
        'is_final': true,
        'language': 'auto',
      }));
      _history.add(ChatMessage('user', text));

      final messages = [..._history];
      if (_knowledgeProvider != null) {
        // Ground this turn with retrieved knowledge (one-shot system block).
        try {
          final ctx = await _knowledgeProvider!(text);
          if (ctx != null && ctx.trim().isNotEmpty) {
            messages.add(ChatMessage('system', ctx));
          }
        } catch (e, st) {
          _safeLog('[voice_forge] knowledge retrieval error: $e\n$st');
        }
      }

      final reply = await _runTurn(messages);
      // Turn went stale while the LLM was working: never speak it or record
      // it — the user has moved on to a new utterance.
      if (_epoch != epoch) return;
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
      // Drain the queue in order, skipping segments made stale by a
      // barge-in while this turn was in flight.
      while (_segmentQueue.isNotEmpty) {
        final next = _segmentQueue.removeAt(0);
        if (next.epoch == _epoch) {
          unawaited(_handleSegment(next.samples, epoch: next.epoch));
          break;
        }
      }
    }
  }

  Future<String> _transcribe(Float32List segment) async {
    // sherpa bindings are per-isolate; keep transcription on this isolate.
    // whisper tiny int8 transcribes ~10s of audio in well under a second.
    final sw = Stopwatch()..start();
    final text = await _stt.transcribe(segment);
    _safeLog('[voice_forge] stt: ${sw.elapsedMilliseconds}ms');
    return text;
  }

  /// One LLM turn: offer tools, execute any requested calls, and loop until
  /// the model produces spoken content. Falls back to a plain [reply] when
  /// the provider rejects the `tools` request (e.g. models without function
  /// calling).
  Future<String> _runTurn(List<ChatMessage> messages) async {
    const maxToolRounds = 4;
    final tools = _tools.isEmpty ? null : _tools;
    LlmReply reply;
    try {
      reply = await _llm.replyWithTools(messages, tools: tools);
    } on LlmException {
      if (tools == null) rethrow;
      // Provider/model without tool support: plain chat completions.
      return _llm.reply([...messages]);
    }
    var toolCalls = reply.toolCalls;
    var rounds = 0;
    while (toolCalls.isNotEmpty && rounds < maxToolRounds) {
      rounds++;
      _history.add(ChatMessage('assistant', reply.content ?? '',
          toolCalls: toolCalls));
      for (final call in toolCalls) {
        String result;
        if (_toolExecutor == null) {
          result = jsonEncode({'error': 'no tool executor configured'});
        } else {
          try {
            result = await _toolExecutor!(call);
          } catch (e) {
            result = jsonEncode({'error': '$e'});
          }
        }
        _history.add(ChatMessage('tool', result, toolCallId: call.id));
      }
      try {
        reply = await _llm.replyWithTools([..._history], tools: tools);
      } on LlmException {
        return _llm.reply([..._history]);
      }
      toolCalls = reply.toolCalls;
    }
    final text = reply.content;
    if (text == null || text.isEmpty) {
      // Model produced only tool calls and the loop ended: force a text reply.
      return _llm.reply([..._history]);
    }
    return text;
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
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _pendingSegments.clear();
    _pendingEpoch = -1;
    final finalSegment = _vad.flush();
    if (finalSegment != null) {
      unawaited(_handleSegment(finalSegment, epoch: _epoch));
    }
    _history.clear();
    _seeded = false;
  }

  void dispose() {
    _mergeTimer?.cancel();
    _mergeTimer = null;
    _pendingSegments.clear();
    _events.close();
    _ttsOut.close();
    _speaking.close();
  }
}
