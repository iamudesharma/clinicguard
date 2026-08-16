/// voice_forge_flutter — Flutter client for voice_forge voice agents.
///
/// ```dart
/// final call = VoiceCallController(signalingUrl: 'ws://host:8765/signal');
/// call.events.listen((e) { /* user_transcript / assistant_text / agent_state */ });
/// await call.start();      // mic -> agent, agent audio plays automatically
/// call.sendBargeIn();      // interrupt the agent instantly
/// await call.end();
/// ```
library;

export 'src/voice_call_controller.dart';
