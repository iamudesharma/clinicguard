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

  /// The instant-onset barge-in gate is armed only while TTS audio is
  /// actually being emitted. During synthesis the user's own speech is still
  /// settling (VAD hangover tail, applause after the answered utterance) —
  /// counting those frames as "talking over us" would cut the reply before
  /// it ever plays. Once audio is out, any voiced frame means the user is
  /// genuinely interrupting.
  bool _onsetArmed = false;

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

  /// Whether the previous turn merged multiple segments. Merged turns mean
  /// the user tends to pause mid-utterance, so keep the longer merge window;
  /// single-segment turns mean utterances arrive complete, so shrink it.
  bool _lastTurnMerged = false;

  /// Merge window for short segments (may continue into the next sentence)
  /// and for turns where the user was pausing mid-utterance.
  static const _longMergeWindow = Duration(milliseconds: 450);

  /// Merge window for long, self-contained segments and for turns that have
  /// not been splitting recently.
  static const _shortMergeWindow = Duration(milliseconds: 200);

  /// Segments at or above this length (~2.4s @ 16 kHz) are treated as
  /// complete utterances that do not need a long merge window.
  static const _longSegmentSamples = 38400;

  /// Sentence-end delimiters (also handles Hindi danda). Inside a character
  /// class `.` is literal.
  static final RegExp _sentenceEnd = RegExp(r'[.!?।]');

  /// Only the last [maxTurnMessages] user/assistant messages go to the LLM
  /// (system context is always kept), so request size and TTFT stay flat on
  /// long calls.
  static const _maxTurnMessages = 8;

  /// Max tokens for spoken-turn requests. ~40 words of speech is ~60-80
  /// tokens; 160 also leaves room for tool-call JSON without letting a free
  /// model ramble for a minute.
  static const _turnMaxTokens = 160;

  /// Max tokens for JSON-structured asks (summary, booking intent): those
  /// replies carry several fields and must not be truncated mid-JSON.
  static const _structuredMaxTokens = 400;

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
  ///
  /// [preSynthesized] is optional audio produced ahead of time (e.g. at agent
  /// startup); when given, synthesis is skipped so the line plays instantly.
  Future<void> greet(String text, {TtsAudio? preSynthesized}) async {
    if (!_seeded) {
      _seeded = true;
      _history.add(ChatMessage('system', _systemPrompt));
    }
    _history.add(ChatMessage('assistant', text));
    _events.add(AgentEvent({'type': 'assistant_text', 'text': text}));
    await _speak(text, preSynthesized: preSynthesized);
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
      ], maxTokens: _structuredMaxTokens);
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
      ], maxTokens: _structuredMaxTokens);
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
  /// single LLM turn instead of sending each chunk separately. The merge
  /// window is adaptive: long self-contained segments and turns that have
  /// not been splitting recently get a short window; short segments after a
  /// turn that merged keep the longer window.
  void _scheduleMerged(Float32List segment) {
    _pendingSegments.add(segment);
    _pendingEpoch = _epoch;
    _mergeTimer?.cancel();
    _mergeTimer = Timer(_mergeWindowFor(segment), () {
      _mergeTimer = null;
      final epoch = _pendingEpoch;
      final pendingCount = _pendingSegments.length;
      final merged = _mergePending();
      _lastTurnMerged = pendingCount > 1;
      if (merged == null || epoch != _epoch) return;
      if (_processing) {
        _segmentQueue.add((samples: merged, epoch: epoch));
      } else {
        unawaited(_handleSegment(merged, epoch: epoch));
      }
    });
  }

  Duration _mergeWindowFor(Float32List segment) {
    if (segment.length >= _longSegmentSamples) return _shortMergeWindow;
    return _lastTurnMerged ? _longMergeWindow : _shortMergeWindow;
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
      if (_onsetArmed && !_interrupt) {
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

      final messages = _turnMessages();
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

      // Speak sentences as the LLM streams them, so first audio arrives
      // after the first sentence instead of the full reply.
      final controller = StreamController<String>();
      final speakFuture = _speakStreamed(controller.stream, epoch: epoch);

      String? replyText;
      try {
        replyText = await _runTurn(messages, onPartial: controller.add);
      } catch (e) {
        _events.add(AgentEvent({'type': 'agent_error', 'error': '$e'}));
      }
      await controller.close();

      // Turn went stale while the LLM was working: never record it — the
      // user has moved on to a new utterance (partial speech, if any, was
      // already interrupted by the barge-in).
      if (_epoch != epoch) return;
      if (replyText == null || replyText.isEmpty) return;
      _history.add(ChatMessage('assistant', replyText));
      _events.add(AgentEvent({
        'type': 'assistant_text',
        'text': replyText,
      }));

      await speakFuture;
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

  /// The messages sent to the LLM for a turn: all system context plus the
  /// last [_maxTurnMessages] user/assistant messages (history stays full for
  /// summaries, but the request is bounded for fast TTFT on long calls).
  List<ChatMessage> _turnMessages() {
    final out = <ChatMessage>[];
    final tail = <ChatMessage>[];
    for (final m in _history) {
      if (m.role == 'system') {
        out.add(m);
      } else {
        tail.add(m);
      }
    }
    final skip = tail.length - _maxTurnMessages;
    if (skip > 0) {
      out.addAll(tail.sublist(skip));
    } else {
      out.addAll(tail);
    }
    return out;
  }

  /// One LLM turn: stream the reply (sentences pushed to [onPartial] as they
  /// arrive), execute any requested tool calls, and loop until the model
  /// produces spoken content. Falls back to plain chat completions when the
  /// provider rejects streaming or tools.
  Future<String> _runTurn(List<ChatMessage> messages,
      {required void Function(String partial) onPartial}) async {
    const maxToolRounds = 4;
    final tools = _tools.isEmpty ? null : _tools;
    LlmReply reply;
    try {
      reply = await _llm.streamReplyWithTools(messages,
          tools: tools, onPartial: onPartial, maxTokens: _turnMaxTokens);
    } on LlmException {
      if (tools == null) rethrow;
      // Provider/model without tool support: plain chat completions.
      final fallback = await _llm.reply([...messages],
          maxTokens: _turnMaxTokens);
      onPartial(fallback);
      return fallback;
    }
    var toolCalls = reply.toolCalls;
    var usedToolLoop = toolCalls.isNotEmpty;
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
        reply = await _llm.replyWithTools([..._history],
            tools: tools, maxTokens: _turnMaxTokens);
      } on LlmException {
        final text = await _llm.reply([..._history],
            maxTokens: _turnMaxTokens);
        onPartial(text);
        return text;
      }
      toolCalls = reply.toolCalls;
    }
    var text = reply.content;
    if (text == null || text.isEmpty) {
      // Model produced only tool calls and the loop ended: force a text reply.
      text = await _llm.reply([..._history], maxTokens: _turnMaxTokens);
      onPartial(text);
    } else if (usedToolLoop) {
      // Tool rounds came back non-streaming: feed the final content now.
      onPartial(text);
    }
    return text;
  }

  /// Speak a complete reply, split into sentences. Synthesis of the next
  /// sentence overlaps playback of the current one, so first audio starts
  /// after a single sentence instead of the whole text.
  Future<void> _speak(String text, {TtsAudio? preSynthesized}) async {
    _interrupt = false;
    _setState(AgentState.speaking);
    _speaking.add(true);
    try {
      if (preSynthesized != null) {
        await _playAudio(preSynthesized, _epoch);
        return;
      }
      final sentences = _splitSentences(text);
      if (sentences.isEmpty) return;
      Future<void> tail = Future.value();
      for (final s in sentences) {
        tail = _playAfter(tail, s, _epoch);
      }
      await tail;
    } finally {
      _speaking.add(false);
      _setState(AgentState.listening);
    }
  }

  /// Speak sentences as they stream in from the LLM. The speaking state
  /// starts when the FIRST sentence enters synthesis (not when audio begins),
  /// so the client's barge-in detector is armed for the whole speech window
  /// — synthesis of the first sentence included.
  Future<void> _speakStreamed(Stream<String> chunks, {required int epoch}) async {
    _interrupt = false;
    try {
      String buffer = '';
      Future<void> tail = Future.value();
      var started = false;
      void startSpeaking() {
        if (started) return;
        started = true;
        _setState(AgentState.speaking);
        _speaking.add(true);
      }

      Future<void> queue(String sentence) {
        startSpeaking();
        tail = _playAfter(tail, sentence, epoch);
        return tail;
      }

      await for (final chunk in chunks) {
        if (_epoch != epoch || _interrupt) return;
        buffer += chunk;
        var m = _sentenceEnd.firstMatch(buffer);
        while (m != null) {
          final sentence = buffer.substring(0, m.end).trim();
          buffer = buffer.substring(m.end);
          if (sentence.isNotEmpty) queue(sentence);
          m = _sentenceEnd.firstMatch(buffer);
        }
        if (buffer.length > 300) {
          // No sentence end for a while: speak what we have rather than
          // stalling the voice loop on a long fragment.
          final sentence = buffer.trim();
          buffer = '';
          if (sentence.isNotEmpty) queue(sentence);
        }
      }
      final rest = buffer.trim();
      if (rest.isNotEmpty) queue(rest);
      await tail;
    } finally {
      _speaking.add(false);
      _setState(AgentState.listening);
    }
  }

  /// Split [text] into sentences, keeping the sentence-end punctuation.
  /// Returns the trailing fragment (no delimiter) as its own sentence.
  List<String> _splitSentences(String text) {
    final out = <String>[];
    var start = 0;
    for (final m in _sentenceEnd.allMatches(text)) {
      final sentence = text.substring(start, m.end).trim();
      if (sentence.isNotEmpty) out.add(sentence);
      start = m.end;
    }
    final rest = text.substring(start).trim();
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  /// Synthesize [sentence] while [prev] (the previous sentence's playback)
  /// runs, then play the audio. Returns a future that completes when the
  /// playback of this sentence is done.
  Future<void> _playAfter(Future<void> prev, String sentence, int epoch) async {
    final synth = _tts.synthesize(sentence);
    await prev;
    final audio = await synth;
    await _playAudio(audio, epoch);
  }

  Future<void> _playAudio(TtsAudio audio, int epoch) async {
    if (audio.samples.isEmpty || _epoch != epoch || _interrupt) return;
    // piper: 22050 Hz mono -> upsample to 48k, emit 20 ms stereo frames.
    final ups = resampleUp(audio.samples, audio.sampleRate, 48000);
    final stereo = toPcm16Stereo(ups, 2);
    const frameLen = 48000 * 2 ~/ 50; // 1920
    _onsetArmed = true;
    try {
      for (var i = 0; i + frameLen <= stereo.length; i += frameLen) {
        if (_interrupt) {
          _events.add(
              AgentEvent({'type': 'agent_state', 'state': 'listening'}));
          return;
        }
        _ttsOut.add(Int16List.sublistView(stereo, i, i + frameLen));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _onsetArmed = false;
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
