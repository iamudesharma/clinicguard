/// voice_forge — minimal voice-agent framework for Dart.
///
/// Design goals:
///  - one dependency per concern, all published Dart packages
///  - the conversation loop lives here; providers plug in behind interfaces
///  - runs in ~90 MB as a single `dart compile exe` binary
library;

export 'src/agent/voice_agent.dart';
export 'src/llm/llm.dart';
export 'src/session/agent_session.dart';
export 'src/speech/interfaces.dart';
export 'src/speech/resample.dart';
export 'src/speech/sherpa_kit.dart';
export 'src/transport/audio_core.dart';
export 'src/transport/peer_session.dart';
export 'src/transport/voice_call_server.dart';
