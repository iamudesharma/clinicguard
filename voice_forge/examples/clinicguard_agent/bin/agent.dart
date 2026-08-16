/// ClinicGuard voice agent on voicepipe (LiveKit-free).
///
/// Replaces the LiveKit `server/agent.py` voice path:
///   - triage system prompt (en + hi), one question at a time
///   - greeting spoken at call start
///   - per-call room id (`clinic-xxxx`) sent in the `connected` message
///   - transcripts persisted to the Python FastAPI control plane
///     (POST /sessions/{room}/transcripts) so Supabase/EHR keeps working
///   - a structured `summary` event published over the data channel at call end
///
/// Run (from examples/clinicguard_agent):
///   dart run bin/agent.dart
/// Env: GROQ_API_KEY/OPENAI_API_KEY, API_BASE_URL (default
///      http://127.0.0.1:8000), VOICEPIPE_WHISPER_MODEL (tiny|base).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:voicepipe/voicepipe.dart';

const _modelsDir = '../../models';
const _defaultApiBase = 'http://127.0.0.1:8000';

const _greeting =
    'Namaste and welcome to the clinic. I am your triage assistant. '
    'I can help you in English or Hindi. Please tell me your name, age, '
    'and what is bothering you.';

/// Crash-proof logging: when stdout is piped (e.g. through a timestamp
/// wrapper) Dart's stdout sink can enter a "bound" state under pipe
/// backpressure, making the next writeln throw "Bad state: StreamSink is
/// bound to a stream" — inside the turn flow. Never let a log line break a
/// call.
void safeLog(String message) {
  try {
    stdout.writeln(message);
  } catch (_) {}
}

const _systemPrompt = '''
You are "ClinicGuard", a multilingual clinical triage dispatcher for a
primary-care clinic. Support patients in English and Hindi. Always speak in
the patient's language.

## Conversation flow
1. Greet, confirm identity (name, age, sex) and capture the chief complaint.
2. Ask ONE short question at a time (spoken voice: keep answers under 40 words).
3. Ask targeted severity questions based on the chief complaint (onset,
   severity, red flags, existing conditions, allergies, medications).
4. Finish with a clear recommendation: stay home + self-care, see a doctor
   today, go to urgent care, or call emergency services. Never diagnose.

## Urgency levels
- low: minor, self-care is safe (cold, small cuts, mild headache).
- medium: see a doctor within 24-48h (persistent fever, pain with movement).
- high: see a doctor today (chest discomfort, severe abdominal pain).
- emergency: call emergency services NOW (severe chest pain radiating,
  trouble breathing at rest, stroke signs, anaphylaxis, severe bleeding).

## Red flags that must escalate
Chest pain/pressure with sweating or radiating pain · sudden severe headache ·
one-sided weakness or slurred speech · face/throat swelling or difficulty
breathing after allergen exposure · high fever in an infant under 3 months ·
persistent vomiting or severe dehydration · confusion or altered consciousness.

## Tools (call them when appropriate)
- If the patient asks to book an appointment, call get_available_slots, read
  the slot labels aloud, ask the patient which one they want, then call
  book_appointment with the chosen label, the patient's name and the reason
  (chief complaint). Never invent a slot the tool did not return.
- If the patient asks about a condition, treatment, or "what should I do",
  call search_knowledge for grounded suggestions.
''';

void initOpusLibrary() {
  for (final path in [
    '/opt/homebrew/opt/opus/lib/libopus.dylib',
    '/opt/homebrew/lib/libopus.dylib',
    '/usr/local/lib/libopus.dylib',
    'libopus.dylib',
    'libopus.so.0',
  ]) {
    try {
      initOpus(DynamicLibrary.open(path));
      return;
    } catch (_) {}
  }
  throw StateError('libopus not found (brew install opus)');
}

/// Agent core: triage session + transcript persistence + summary at close.
class TriageCore implements AudioCore {
  final AgentSession session;
  final String roomId;
  final String apiBase;
  final int ragTopK;
  final int ragMaxContextChars;
  final http.Client _http = http.Client();
  // Dedicated client for RAG retrieval + tools: the 900ms retrieval budget
  // abandons in-flight requests, and an abandoned request on a shared client
  // corrupts later sends ("Bad state: StreamSink is bound to a stream").
  // On timeout we close it so the abandoned request dies with it, and a fresh
  // client is created for the next call.
  http.Client? _ragHttp;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  String? _patientId;
  Map<String, dynamic>? _patient;
  bool _bookedDuringCall = false;

  http.Client get _ragClient => _ragHttp ??= http.Client();

  TriageCore(
    this.session, {
    required this.roomId,
    required this.apiBase,
    this.ragTopK = 3,
    this.ragMaxContextChars = 2400,
  }) {
    session.configure(
      tools: _tools,
      toolExecutor: _runTool,
      knowledgeProvider: _knowledgeForTurn,
    );
    _lastUserTurnAt = null;
    session.events.listen((e) {
      final p = e.payload;
      try {
        _events.add(p);
      } catch (err, st) {
        safeLog('[$roomId] publish error: $err\n$st');
      }
      if (p['type'] == 'user_transcript') {
        _lastUserTurnAt = DateTime.now();
      }
      if (p['type'] == 'assistant_text' && _lastUserTurnAt != null) {
        final ms = DateTime.now().difference(_lastUserTurnAt!).inMilliseconds;
        safeLog('[$roomId] TURN LATENCY: $ms ms '
            '(speech end -> agent starts speaking)');
        _lastUserTurnAt = null;
      }
      if (p['type'] == 'user_transcript' || p['type'] == 'assistant_text') {
        _persist(p['type'] == 'user_transcript' ? 'user' : 'assistant',
            p['text'] as String? ?? '');
      }
    });
  }

  DateTime? _lastUserTurnAt;

  /// Tools offered to the LLM (OpenAI-style function calling).
  static const _tools = [
    ToolDef(
      name: 'get_available_slots',
      description:
          'List the clinic\'s next available appointment slots. Call this '
          'when the patient asks to book an appointment, then read the labels '
          'aloud and let the patient choose.',
      parameters: {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
    ),
    ToolDef(
      name: 'book_appointment',
      description:
          'Book a clinic appointment. Call it ONLY when the patient has '
          'explicitly asked to book AND has chosen a slot from '
          'get_available_slots output. patient_id is filled in automatically.',
      parameters: {
        'type': 'object',
        'properties': {
          'slot': {
            'type': 'string',
            'description': 'The exact label returned by get_available_slots, '
                'e.g. "Tomorrow 11:00".',
          },
          'name': {
            'type': 'string',
            'description': 'Patient name from the conversation.',
          },
          'reason': {
            'type': 'string',
            'description': 'Chief complaint / reason for the visit, briefly.',
          },
        },
        'required': ['slot', 'name', 'reason'],
        'additionalProperties': false,
      },
    ),
    ToolDef(
      name: 'search_knowledge',
      description:
          'Search the clinic knowledge base for grounded health guidance '
          '(self-care tips, red flags, condition information). Call it when '
          'the patient asks about a condition, symptom, treatment, or '
          '"what should I do".',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The patient\'s question or symptom, verbatim-ish.',
          },
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    ),
  ];

  Future<String> _runTool(LlmToolCall call) async {
    final sw = Stopwatch()..start();
    String result;
    switch (call.name) {
      case 'get_available_slots':
        result = await _getSlotsJson();
      case 'book_appointment':
        result = await _bookAppointment(call.arguments);
      case 'search_knowledge':
        result = await _searchKnowledge(call.arguments);
      default:
        result = jsonEncode({'error': 'unknown tool: ${call.name}'});
    }
    sw.stop();
    safeLog('[$roomId] tool: ${call.name} -> ${sw.elapsedMilliseconds}ms');
    return result;
  }

  Future<String> _getSlotsJson() async {
    try {
      final res = await _http
          .get(Uri.parse('$apiBase/slots'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return res.body;
    } catch (e) {
      safeLog('[$roomId] slots fetch failed: $e');
    }
    return jsonEncode({'error': 'could not fetch slots'});
  }

  Future<String> _bookAppointment(Map<String, dynamic> args) async {
    final slot = (args['slot'] as String? ?? '').trim();
    if (slot.isEmpty) {
      return jsonEncode({'error': 'slot is required'});
    }
    try {
      final res = await _http
          .post(
            Uri.parse('$apiBase/bookings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'patient_id': _patientId ?? '',
              'room_id': roomId,
              'name': args['name'] ?? '',
              'slot': slot,
              'reason': args['reason'] ?? '',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 && res.statusCode != 201) {
        return jsonEncode({'error': 'booking failed: ${res.statusCode}'});
      }
      final booking = jsonDecode(res.body) as Map<String, dynamic>;
      _bookedDuringCall = true;
      _events.add({'type': 'booking_confirmed', 'booking': booking});
      safeLog('[$roomId] booked ${booking['slot']} (${booking['id']})');
      return jsonEncode({
        'status': 'confirmed',
        'booking_id': booking['id'],
        'slot': booking['slot'],
        'name': booking['name'],
      });
    } catch (e) {
      safeLog('[$roomId] booking failed: $e');
      return jsonEncode({'error': 'booking request failed: $e'});
    }
  }

  Future<String> _searchKnowledge(Map<String, dynamic> args) async {
    final query = (args['query'] as String? ?? '').trim();
    if (query.isEmpty) return jsonEncode({'error': 'query is required'});
    try {
      final res = await _ragClient
          .post(
            Uri.parse('$apiBase/rag/search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query, 'k': ragTopK}),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body) as Map<String, dynamic>;
        final results = (decoded['results'] as List?) ?? const [];
        if (results.isNotEmpty) return jsonEncode({'results': results});
      }
    } catch (e) {
      safeLog('[$roomId] knowledge search failed: $e');
    }
    return jsonEncode({'results': []});
  }

  /// Auto-retrieval before each LLM turn: ground the reply with the top-k
  /// knowledge chunks for the user's latest utterance.
  ///
  /// Gated by [_shouldRetrieve] so chatter/greetings/booking-flow turns never
  /// pay a retrieval round trip, and hard-capped by [retrievalTimeout] so a
  /// slow search can never stall the voice loop.
  Future<String?> _retrieveKnowledge(String userText) async {
    if (userText.trim().isEmpty) return null;
    final sw = Stopwatch()..start();
    final client = _ragClient;
    try {
      final res = await client
          .post(
            Uri.parse('$apiBase/rag/search'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': userText, 'k': ragTopK}),
          )
          .timeout(const Duration(seconds: 5));
      sw.stop();
      if (res.statusCode != 200) {
        safeLog('[$roomId] rag: status ${res.statusCode} in '
            '${sw.elapsedMilliseconds}ms');
        return null;
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (decoded['results'] as List?) ?? const [];
      safeLog('[$roomId] rag: ${results.length} result(s) in '
          '${sw.elapsedMilliseconds}ms '
          'for "${userText.length > 60 ? userText.substring(0, 60) : userText}"');
      if (results.isEmpty) return null;
      final buffer = StringBuffer(
          'KNOWLEDGE BASE (retrieved snippets — they may be irrelevant; '
          'only use what matches the patient\'s situation):\n');
      for (final r in results.take(ragTopK)) {
        if (buffer.length >= ragMaxContextChars) break;
        final title = r['title']?.toString() ?? '';
        final content = r['content']?.toString() ?? '';
        final category = r['category']?.toString() ?? '';
        final line = '- [$category] $title\n  $content\n';
        if (buffer.length + line.length > ragMaxContextChars) break;
        buffer.write(line);
      }
      if (buffer.length <= 50) return null;
      return buffer.toString();
    } catch (e) {
      // Timeout fires most often (the 900ms budget or the 5s HTTP timeout):
      // close the dedicated client so the abandoned request dies with it and
      // cannot corrupt later requests on the shared client.
      if (_ragHttp == client) {
        _ragHttp?.close();
        _ragHttp = null;
      }
      safeLog('[$roomId] knowledge retrieval failed: $e');
      return null;
    }
  }

  /// Turns that clearly need health-knowledge grounding: symptom/condition
  /// words or "what/how/should" questions. Everything else (greetings,
  /// yes/no, thanks, small talk, and the booking flow) skips retrieval so the
  /// voice loop stays fast.
  static final RegExp _knowledgeIntent = RegExp(
      r'\b(fever|cold|flu|cough|sore throat|headache|migraine|pain|ache|'
      r'symptom|treat|treatment|medicine|medication|tablet|allerg|asthma|'
      r'wheez|diabetes|sugar|blood pressure|\bbp\b|hypertension|heart|chest|'
      r'throat|stomach|nausea|vomit|diarrhea|dehydrat|dizzy|sleep|insomnia|'
      r'fatigue|weakness|wound|injury|burn|bite|sting|rash|hives|ear|eye|'
      r'dental|tooth|infection|antibiotic|vaccin|red flag|urgent|emergency|'
      r'what should|how do|how to|what can|is it normal|why do|should i)\b',
      caseSensitive: false);

  /// Booking-flow turns: the LLM handles these via tools; grounding adds
  /// nothing but latency.
  static final RegExp _bookingFlow = RegExp(
      r'\b(book|booking|appointment|slot|schedule|tomorrow|available|'
      r'doctor|clinic|visit|morning|afternoon|evening|time)\b',
      caseSensitive: false);

  bool _shouldRetrieve(String userText) {
    final t = userText.trim();
    if (t.length < 12) return false;
    if (_bookingFlow.hasMatch(t)) return false;
    return _knowledgeIntent.hasMatch(t);
  }

  void _persist(String role, String text) {
    if (text.isEmpty) return;
    unawaited(_http
        .post(
          Uri.parse('$apiBase/sessions/$roomId/transcripts'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'role': role, 'text': text, 'language': 'auto'}),
        )
        .then((_) {})
        .catchError((_) {}));
  }

  @override
  void onDecodedPcm(Int16List pcm48kStereo) => session.onAudio(pcm48kStereo);

  @override
  Stream<Int16List> get outgoingPcm => session.ttsAudio;

  @override
  void onDataMessage(Map<String, dynamic> message) {
    if (message['event'] == 'patient_id') {
      final id = message['patient_id'] as String?;
      if (id != null && id.isNotEmpty && _patient == null) {
        unawaited(_loadPatient(id));
      }
    }
    if (message['event'] == 'barge_in') {
      safeLog('[$roomId] barge-in from client');
      session.interrupt();
    }
    if (message['event'] == 'end_call') {
      safeLog('[$roomId] end_call from client; finalizing...');
      unawaited(_finalize());
    }
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void onPeerClosed() {
    safeLog('[$roomId] call ended; finalizing...');
    // Generate the summary BEFORE clearing the session history.
    unawaited(_finalize().whenComplete(session.endCall));
  }

  @override
  void onDataChannelOpen() {
    // Give the client a brief window to announce the patient before greeting.
    unawaited(_greetWhenReady());
  }

  /// Knowledge provider for the session: applies the intent gate and a hard
  /// timeout so retrieval can never add more than [retrievalBudget] of latency.
  static const _retrievalBudget = Duration(milliseconds: 900);

  Future<String?> _knowledgeForTurn(String userText) {
    if (!_shouldRetrieve(userText)) {
      safeLog('[$roomId] rag: skipped (no knowledge intent)');
      return Future.value(null);
    }
    return _retrieveKnowledge(userText).timeout(
      _retrievalBudget,
      onTimeout: () {
        // Abandon the in-flight request: kill the dedicated client so it
        // cannot corrupt later sends on the shared client.
        _ragHttp?.close();
        _ragHttp = null;
        safeLog('[$roomId] rag: timed out, continuing without grounding');
        return null;
      },
    );
  }

  Future<void> _greetWhenReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_patient == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final name = _patient?['name']?.toString().trim();
    final greeting = (name != null && name.isNotEmpty)
        ? 'Namaste, welcome back $name. The clinic has your records. '
            'Please tell me what is bothering you today.'
        : _greeting;
    await session.greet(greeting);
  }

  @override
  Map<String, dynamic>? get connectionInfo => {'room': roomId};

  Future<void> _loadPatient(String id) async {
    try {
      final res = await _http
          .get(Uri.parse('$apiBase/patients/$id'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        throw HttpException('status ${res.statusCode}');
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      _patientId = id;
      _patient = decoded;
    } catch (e) {
      safeLog('[$roomId] patient lookup failed: $e');
      return;
    }
    final parts = <String>[
      'name: ${_patient?['name']?.toString().trim() ?? ''}',
      'age: ${_patient?['age']?.toString().trim() ?? ''}',
      'sex: ${_patient?['sex']?.toString().trim() ?? ''}',
      'known conditions: ${_patient?['known_conditions']?.toString().trim() ?? ''}',
    ];
    final allergies = _patient?['allergies']?.toString().trim() ?? '';
    if (allergies.isNotEmpty) {
      parts.add('allergies: $allergies');
    }
    final block =
        'PATIENT CONTEXT from clinic records. Verify details with the patient; '
        'never assume unstated facts. The patient\'s identity (name/age/sex) '
        'is ALREADY KNOWN — do NOT ask for name, age, or sex again; greet them '
        'by name and go straight to the chief complaint:\n${parts.join(' | ')}';
    session.addSystemContext(block);
    safeLog('[$roomId] patient context loaded: ${_patient?['name']}');
  }

  Future<void> _finalize() async {
    var summary = await session.generateSummary();
    if (summary == null) {
      // One retry with an explicit "JSON only" instruction.
      summary = await session.generateSummary(
          extra: ChatMessage('user',
              'Reply with the JSON object only. No prose, no markdown.'));
    }
    if (summary != null) {
      _events.add({
        'type': 'summary',
        'summary': summary,
        if (_patientId != null) 'patient_id': _patientId,
      });
      safeLog('[$roomId] summary: $summary');
      if (_patientId != null) {
        unawaited(_http
            .put(
              Uri.parse('$apiBase/sessions/$roomId'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(
                  {'patient_id': _patientId, 'status': 'ended'}),
            )
            .then((_) {})
            .catchError((_) {}));
      }
    } else {
      safeLog('[$roomId] summary generation failed');
    }
    await _maybeBookAppointment(summary);
  }

  Future<void> _maybeBookAppointment(Map<String, dynamic>? summary) async {
    if (summary == null) return;
    if (_bookedDuringCall) {
      safeLog('[$roomId] already booked during the call; skipping');
      return;
    }
    final intent = await session.askStructured(
      instruction:
          'Based on this triage call, decide whether the patient explicitly '
          'agreed to book a clinic appointment after the recommendation was '
          'given (a polite "no, thanks" or "I will call back" counts as NO). '
          'Reply with a JSON object with EXACTLY these keys: wants_booking '
          '(boolean, true only if the patient clearly agreed), preferred_slot '
          '(string or null; only when the patient stated a preference, e.g. '
          '"tomorrow 11:00"). Reply with the JSON object only.',
    );
    final wants = intent?['wants_booking'] == true;
    if (!wants) {
      safeLog('[$roomId] no in-call booking requested');
      return;
    }
    String slotLabel = (intent?['preferred_slot'] as String?) ?? '';
    if (slotLabel.trim().isEmpty) {
      try {
        final res = await _http
            .get(Uri.parse('$apiBase/slots'))
            .timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          final slots =
              (jsonDecode(res.body)['slots'] as List?) ?? const [];
          slotLabel =
              slots.isNotEmpty ? (slots.first['label'] as String? ?? '') : '';
        }
      } catch (e) {
        safeLog('[$roomId] slots fetch failed: $e');
      }
    }
    if (slotLabel.isEmpty) slotLabel = 'Tomorrow 09:00';
    try {
      final res = await _http
          .post(
            Uri.parse('$apiBase/bookings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'patient_id': _patientId ?? '',
              'room_id': roomId,
              'name': summary['patient_name'] ?? '',
              'slot': slotLabel,
              'reason': summary['chief_complaint'] ?? '',
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 && res.statusCode != 201) {
        safeLog('[$roomId] booking POST failed: ${res.statusCode}');
        return;
      }
      final booking = jsonDecode(res.body) as Map<String, dynamic>;
      _events.add({'type': 'booking_confirmed', 'booking': booking});
      stdout
          .writeln('[$roomId] booked ${booking['slot']} (${booking['id']})');
      await session.greet(
          'I have booked your appointment for $slotLabel. Take care and get well soon.');
    } catch (e) {
      safeLog('[$roomId] booking failed: $e');
    }
  }

  void dispose() {
    session.dispose();
    _events.close();
    _http.close();
    _ragHttp?.close();
  }
}

Future<void> main() async {
  initOpusLibrary();

  final env = Platform.environment;
  final whisperModel = env['VOICEPIPE_WHISPER_MODEL'] ?? 'tiny';
  final apiBase = env['API_BASE_URL'] ?? _defaultApiBase;
  safeLog('loading sherpa-onnx (whisper=$whisperModel) ...');
  final sw = Stopwatch()..start();
  final kit = SherpaKit.load(
    models: SherpaModels.fromModelsDir(_modelsDir, whisperPrefix: whisperModel),
  );
  safeLog('sherpa-onnx ready in ${sw.elapsed.inSeconds}s');

  final llm = llmFromEnv(env);
  safeLog('LLM: ${llm is EchoLlm ? "EchoLlm (offline)" : "OpenAI-compatible"}'
      ' | control plane: $apiBase');

  final agent = VoiceAgent(
    vadFactory: kit.createVad,
    stt: kit.speech.stt,
    tts: kit.speech.tts,
    llm: llm,
    systemPrompt: _systemPrompt,
  );

  await runVoiceCallServer(
    coreFactory: () {
      final roomId =
          'clinic-${Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
      safeLog('[$roomId] session started');
      final ragTopK = int.tryParse(env['RAG_TOP_K'] ?? '') ?? 3;
      final ragMax = int.tryParse(env['RAG_MAX_CONTEXT_CHARS'] ?? '') ?? 2400;
      final core = TriageCore(agent.createSession(),
          roomId: roomId, apiBase: apiBase, ragTopK: ragTopK, ragMaxContextChars: ragMax);
      return core;
    },
  );
}
