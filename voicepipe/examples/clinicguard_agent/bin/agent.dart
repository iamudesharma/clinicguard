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
  final http.Client _http = http.Client();
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  TriageCore(this.session, {required this.roomId, required this.apiBase}) {
    session.events.listen((e) {
      final p = e.payload;
      _events.add(p);
      if (p['type'] == 'user_transcript' || p['type'] == 'assistant_text') {
        _persist(p['type'] == 'user_transcript' ? 'user' : 'assistant',
            p['text'] as String? ?? '');
      }
    });
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
    if (message['event'] == 'barge_in') {
      stdout.writeln('[$roomId] barge-in from client');
      session.interrupt();
    }
    if (message['event'] == 'end_call') {
      stdout.writeln('[$roomId] end_call from client; finalizing...');
      unawaited(_finalize());
    }
  }

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void onPeerClosed() {
    stdout.writeln('[$roomId] call ended; finalizing...');
    // Generate the summary BEFORE clearing the session history.
    unawaited(_finalize().whenComplete(session.endCall));
  }

  @override
  void onDataChannelOpen() {
    // Speak the greeting as soon as events can reach the client.
    unawaited(session.greet(_greeting));
  }

  @override
  Map<String, dynamic>? get connectionInfo => {'room': roomId};

  Future<void> _finalize() async {
    var summary = await session.generateSummary();
    if (summary == null) {
      // One retry with an explicit "JSON only" instruction.
      summary = await session.generateSummary(
          extra: ChatMessage('user',
              'Reply with the JSON object only. No prose, no markdown.'));
    }
    if (summary != null) {
      _events.add({'type': 'summary', 'summary': summary});
      stdout.writeln('[$roomId] summary: $summary');
    } else {
      stdout.writeln('[$roomId] summary generation failed');
    }
  }

  void dispose() {
    session.dispose();
    _events.close();
    _http.close();
  }
}

Future<void> main() async {
  initOpusLibrary();

  final env = Platform.environment;
  final whisperModel = env['VOICEPIPE_WHISPER_MODEL'] ?? 'tiny';
  final apiBase = env['API_BASE_URL'] ?? _defaultApiBase;
  stdout.writeln('loading sherpa-onnx (whisper=$whisperModel) ...');
  final sw = Stopwatch()..start();
  final kit = SherpaKit.load(
    models: SherpaModels.fromModelsDir(_modelsDir, whisperPrefix: whisperModel),
  );
  stdout.writeln('sherpa-onnx ready in ${sw.elapsed.inSeconds}s');

  final llm = llmFromEnv(env);
  stdout.writeln('LLM: ${llm is EchoLlm ? "EchoLlm (offline)" : "OpenAI-compatible"}'
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
      stdout.writeln('[$roomId] session started');
      final core = TriageCore(agent.createSession(),
          roomId: roomId, apiBase: apiBase);
      return core;
    },
  );
}
