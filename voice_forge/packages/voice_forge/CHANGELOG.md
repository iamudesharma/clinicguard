## 0.2.0

* Renamed from `voicepipe` to `voice_forge` (same package, new brand; part of
  the `*_forge` family alongside `image_forge_core` / `video_forge`).
* Initial pub.dev-ready release of the voice_forge framework.
* WebRTC transport (`VoiceCallServer`, `PeerSession`) with WebSocket
  signaling and the `agent.events` data channel.
* Speech stack via `voice_forge_speech`: Silero VAD, Whisper STT, Piper TTS.
* LLM layer: `OpenAiCompatibleLlm`, `FallbackLlm` (provider chaining with
  cooldowns), offline `EchoLlm`, and OpenAI-style tool calling.
* `AgentSession` conversation loop with barge-in, segment merging, event
  streams, and streaming TTS audio.
