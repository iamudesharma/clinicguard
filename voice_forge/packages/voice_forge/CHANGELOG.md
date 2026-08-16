## 0.3.0

* **Streaming LLM replies**: `VoicepipeLlm.streamReplyWithTools` streams SSE
  `content` deltas to `onPartial` as they arrive and assembles `tool_calls`
  deltas by index; providers that ignore `stream` fall back to plain JSON.
  `FallbackLlm` and `EchoLlm` support it; per-call `maxTokens` (default 80)
  bounds responses.
* **Sentence-incremental TTS**: `AgentSession` splits replies on sentence
  ends and synthesizes/speaks each sentence as it completes — first audio
  starts after the first sentence instead of the full reply, with synthesis
  of the next sentence overlapping playback of the current one.
* **Worker-isolate STT/TTS**: `SherpaKit.createWorkerSpeech()` runs
  transcription and synthesis in a long-lived isolate (its own sherpa
  recognizer + TTS), so the event loop — and the instant-onset barge-in
  gate — stays live during speech work. Falls back to the main-isolate
  implementations on init failure.
* **Breaking (async speech interfaces)**: `VoicepipeSTT.transcribe` and
  `VoicepipeTTS.synthesize` now return `Future` (`Future<String>` /
  `Future<TtsAudio>`).
* **Adaptive turn detection**: merge window shrinks to 200 ms for long,
  self-contained segments (was a fixed 450 ms); `minSilenceDuration`
  defaults to 0.30 s.
* **Latency cuts**: LLM history capped at the last 8 user/assistant turns
  (system context always kept); `greet(preSynthesized:)` plays
  pre-rendered audio instantly; barge-in onset gate arms only while audio
  is actually playing (a reply is no longer cut by the tail of the user's
  own utterance).
* Measured per-turn latency improvement of ~43% on the ClinicGuard agent
  (speech end -> first audio: ~3.3 s vs ~5.7 s with a free-tier LLM).

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
