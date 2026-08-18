/// Composition root: build the agent once, get a session per call.
///
/// ```dart
/// final agent = VoiceAgent(
///   vadFactory: kit.createVad,     // FRESH VAD per session (stateful!)
///   stt: kit.speech.stt, tts: kit.speech.tts,
///   llm: llmFromEnv(Platform.environment),
///   systemPrompt: '...',
/// );
/// final session = agent.createSession();   // one per call
/// ```
library;

import '../llm/llm.dart';
import '../session/agent_session.dart';
import '../speech/interfaces.dart';

class VoiceAgent {
  /// Creates one VAD instance per session. The Silero VAD is stateful and
  /// must never be shared between concurrent calls.
  final VoicepipeVAD Function() vadFactory;
  final VoicepipeSTT stt;
  final VoicepipeTTS tts;
  final VoicepipeLlm llm;
  final VoicepipeStreamingSTT? streamingStt;
  final String? systemPrompt;

  VoiceAgent({
    required this.vadFactory,
    required this.stt,
    required this.tts,
    required this.llm,
    this.streamingStt,
    this.systemPrompt,
  });

  /// One session per call: owns its conversation history, its own VAD state,
  /// and its event streams.
  AgentSession createSession() => AgentSession(
    vad: vadFactory(),
    stt: stt,
    tts: tts,
    llm: llm,
    streamingStt: streamingStt,
    systemPrompt: systemPrompt,
  );
}
