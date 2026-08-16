## 0.2.1

* pub.dev score fixes: added an `example/`, shortened the pubspec
  description, and resolved all analyzer infos (async `VoicepipeSTT`,
  null-aware elements, formatting).

## 0.2.0

* Renamed from `voicepipe` to `voice_forge` (same package, new brand; part of
  the `*_forge` family alongside `image_forge_core` / `video_forge`).
* **First-run auto-download**: `SherpaKit.load` fetches the prebuilt
  `libsherpa-onnx-c-api` native library (into
  `~/.cache/voice_forge/native/`, overridable via `VOICE_FORGE_NATIVE_DIR`)
  and any missing standard speech models (silero VAD, Whisper, Piper) from
  the official sherpa-onnx releases — no manual download step. Opt out with
  `autoDownload: false`.
* `SherpaKit.load` / `loadNative` are now async (`await SherpaKit.load(...)`).
* Initial pub.dev-ready release of the voice_forge framework.
* WebRTC transport (`VoiceCallServer`, `PeerSession`) with WebSocket
  signaling and the `agent.events` data channel.
* Speech stack via `voice_forge_speech`: Silero VAD, Whisper STT, Piper TTS.
* LLM layer: `OpenAiCompatibleLlm`, `FallbackLlm` (provider chaining with
  cooldowns), offline `EchoLlm`, and OpenAI-style tool calling.
* `AgentSession` conversation loop with barge-in, segment merging, event
  streams, and streaming TTS audio.
