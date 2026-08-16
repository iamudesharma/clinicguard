# voice_forge

Minimal open-source voice-agent framework for **Dart**. Server-side WebRTC
transport, signaling, speech (sherpa-onnx: VAD/STT/TTS), an LLM interface,
and the conversation loop — all pure Dart, no LiveKit, no Python.

Runs as a single `dart compile exe` binary in ~90 MB RSS. The Flutter client
package is [`voice_forge_flutter`](https://github.com/iamudesharma/clinicguard).

## Features

- **WebRTC transport** for the server side (`webrtc_dart`): audio
  (Opus) + the `agent.events` data channel, WebSocket signaling via
  `shelf_web_socket`.
- **Speech stack** via `voice_forge_speech`: Silero VAD, Whisper STT,
  Piper TTS — pluggable behind `VoicepipeVAD` / `VoicepipeSTT` /
  `VoicepipeTTS` interfaces.
- **LLM interface** (`VoicepipeLlm`) with an OpenAI-compatible HTTP
  implementation (`OpenAiCompatibleLlm`), a `FallbackLlm` that chains
  providers with cooldowns, and an offline `EchoLlm` for development.
- **Conversation loop** (`AgentSession`): VAD segmentation → merged
  utterances → STT → LLM → TTS, with barge-in (interrupt), event streams
  (`AgentEvent`: user transcript, assistant text, state changes), and
  streaming TTS audio out.
- **Tool calling**: OpenAI-style function calling (`ToolDef`,
  `LlmToolCall`, `replyWithTools`) with automatic fallback to plain chat
  when the provider rejects tools.

## Getting started

**No manual downloads needed.** The first time you create the speech kit,
voice_forge fetches everything automatically:

1. the prebuilt `libsherpa-onnx-c-api` native library (from the official
   sherpa-onnx releases) into a user cache
   (`~/.cache/voice_forge/native/`, overridable via `VOICE_FORGE_NATIVE_DIR`);
2. the standard speech models (`silero_vad.onnx`, Whisper tiny,
   Piper en_US-lessac) into the models directory if they are missing.

```dart
final kit = await SherpaKit.load(
  models: SherpaModels.fromModelsDir('models'), // created on first run
);
```

Subsequent runs are instant (cached). To manage artifacts manually, call
`SherpaKit.load(models: ..., autoDownload: false)` — then the assets must be
provided by you:

| Asset | Source |
| ----- | ------ |
| `libsherpa-onnx-c-api.dylib` / `.so` | `sherpa-onnx-v1.13.5-{osx-arm64,osx-x64,linux-x64}-shared.tar.bz2` from https://github.com/k2-fsa/sherpa-onnx/releases, next to your binary |
| `silero_vad.onnx` | https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx |
| `sherpa-onnx-whisper-tiny/` (encoder/decoder int8 + tokens) | https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2 |
| `vits-piper-en_US-lessac-medium-int8/` | https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2 |

Layout matches `SherpaModels.fromModelsDir` (`silero_vad.onnx`,
`sherpa-onnx-whisper-<prefix>/`, `vits-piper-en_US-lessac-medium-int8/`).

Add the dependency:

```yaml
dependencies:
  voice_forge: ^0.2.0
```

## Usage

Build the speech kit and LLM once, then create an agent:

```dart
import 'package:voice_forge/voice_forge.dart';

final kit = await SherpaKit.load(
  models: SherpaModels.fromModelsDir('models'),
);

final llm = OpenAiCompatibleLlm(
  baseUrl: 'https://api.openai.com/v1',
  apiKey: Platform.environment['OPENAI_API_KEY']!,
  model: 'gpt-4o-mini',
);

final agent = VoiceAgent(
  vadFactory: kit.createVad, // fresh VAD per session (stateful!)
  stt: kit.speech.stt,
  tts: kit.speech.tts,
  llm: llm,
  systemPrompt: 'You are a helpful voice assistant.',
);

// One session per call
final session = agent.createSession();
session.events.listen((e) => print('[${e.state}] ${e.text}'));
session.onAudio(pcm); // feed 48 kHz stereo Int16 PCM from the network
```

For a complete end-to-end server (WebRTC offer/answer, data channel, agent
loop) see `examples/poc_server/agent_server.dart` in the voice_forge
repository: https://github.com/iamudesharma/clinicguard

### Tool calling

```dart
session.configure(
  tools: [
    ToolDef(
      name: 'get_weather',
      description: 'Get the current weather for a city.',
      parameters: {
        'type': 'object',
        'properties': {
          'city': {'type': 'string'},
        },
        'required': ['city'],
      },
    ),
  ],
  toolExecutor: (call) async {
    if (call.name == 'get_weather') {
      return '20 C and sunny';
    }
    return 'unknown tool';
  },
);
```

## API map

| Library | Contents |
| ------- | -------- |
| `src/agent/voice_agent.dart` | `VoiceAgent` composition root |
| `src/session/agent_session.dart` | `AgentSession`, `AgentEvent`, `AgentState` |
| `src/llm/llm.dart` | `VoicepipeLlm`, `OpenAiCompatibleLlm`, `FallbackLlm`, `EchoLlm`, `ChatMessage`, `ToolDef`, `LlmToolCall`, `LlmReply` |
| `src/speech/interfaces.dart` | `VoicepipeVAD`, `VoicepipeSTT`, `VoicepipeTTS` |
| `src/speech/sherpa_kit.dart` | `SherpaKit`, `SherpaModels` (sherpa-onnx implementations) |
| `src/speech/resample.dart` | 48 kHz → 16 kHz resampling |
| `src/transport/audio_core.dart` | Opus encode/decode over `opus_codec_dart` |
| `src/transport/peer_session.dart` | WebRTC peer handling (`PeerSession`) |
| `src/transport/voice_call_server.dart` | `VoiceCallServer` (WebSocket signaling + agents) |

## Additional information

- Repository: https://github.com/iamudesharma/clinicguard (set to the real URL
  before the first release)
- Client package: `voice_forge_flutter`
- Speech bindings: `voice_forge_speech`
- License: MIT
