# voicepipe

Minimal open-source voice-agent framework — 100% Dart, no LiveKit, no Python.

A real-time voice agent needs: audio transport (WebRTC), speech-to-text, a language
model, text-to-speech, and a small conversation loop to glue them together.
LiveKit gives you all of this; `voicepipe` gives you a tiny, readable, dependency-free
version of the same idea that runs in ~90 MB and deploys as a single `dart compile exe`
binary.

## Stack

| Layer        | Component                                          |
| ------------ | -------------------------------------------------- |
| Transport    | `webrtc_dart` (server), `flutter_webrtc` (client)  |
| Signaling    | `shelf` + `shelf_web_socket`                       |
| Opus codec   | `opus_codec_dart` (libopus 1.5.2 FFI)              |
| Speech stack | `sherpa-onnx` (vendored pure-Dart FFI): Silero VAD, Whisper tiny STT, Piper TTS |
| LLM          | OpenAI-compatible HTTP (Groq/OpenAI/OpenRouter/...) or offline `EchoLlm` |

## Status

- [x] Transport POC — audio + data-channel round trip (Phase 1)
- [x] Voice pipeline — VAD → STT → LLM → TTS loop over WebRTC (Phase 2)
- [x] Framework API — `VoiceAgent`, `AgentSession`, pluggable VAD/STT/TTS/LLM (Phase 3)
- [x] Flutter client package — `voicepipe_flutter` (`VoiceCallController`) (Phase 3)
- [x] **ClinicGuard migration (Phase 4)** — the app talks to the voicepipe
      triage agent by default (see `examples/clinicguard_agent`); the Python
      FastAPI remains the control plane (patients, summaries, Supabase)
- [ ] Publish to pub.dev (packages are `publish_to: none` until the API settles)

## Phase 2 — verified

Full agent loop, end-to-end over WebRTC (synthetic "patient" audio → server →
agent → TTS audio back), including multi-turn conversation:

| Check | Result |
| ----- | ------ |
| Silero VAD segmentation of live stream | ✅ segments detected per utterance |
| Whisper tiny STT (multilingual, en+hi) | ✅ real transcripts from Obama.wav |
| Groq LLM (llama-3.3-70b, OpenAI-compatible) | ✅ triage-style replies |
| Piper TTS → RTP → client | ✅ 3–4 s audio per reply, RMS ~0.11 |
| `agent.events` contract (user_transcript / assistant_text / agent_state) | ✅ over data channel |
| Multi-turn (2 utterances) | ✅ 2 transcripts + 2 replies |
| Memory | ✅ **89 MB RSS** (whole agent server) |

Run it:
```bash
./scripts/fetch_native.sh   # libsherpa-onnx-c-api (once)
./scripts/fetch_models.sh   # VAD + whisper + piper models (once)
cd examples/poc_server
dart run bin/agent_server.dart &            # voice agent server (ws://:8765/signal)
dart run bin/agent_self_test.dart           # full loop test -> RESULT: PASS
dart run bin/speech_check.dart              # offline speech-stack check
dart run bin/server.dart &                  # transport-only loopback server
dart run bin/self_test.dart                 # transport test -> RESULT: PASS
```

Point the Flutter client (`../poc_client`, `flutter run -d chrome`) at the
agent server for a real mic-to-agent call; transcripts and agent state appear
in the client's data-channel log.

## Known findings

- **macOS desktop client does not complete ICE to webrtc_dart** (stuck at
  `connecting`), while Chrome (web) and the webrtc_dart self-tests connect
  fine. Root cause not yet isolated (likely libwebrtc-desktop ⇄ webrtc_dart
  ICE interop). Test with the web client on desktop.
- Repeating the *same* Opus packet through a persistent libopus instance via
  Dart FFI corrupts state at 48 kHz (decoder output amplifies to full-scale;
  encoder output shrinks). Real continuous streams (phase-progressive frames)
  are unaffected — all production paths use persistent instances.
- `third_party/sherpa_onnx` is a vendored, Flutter-free build of the official
  `sherpa_onnx` Dart bindings (Apache-2.0) with a small patch to inject the
  loaded native library handle. Upstream it and this disappears.

## Layout

```
packages/voicepipe            # pure Dart framework (transport, speech, llm, session)
packages/voicepipe_flutter    # Flutter client package (Phase 3)
third_party/sherpa_onnx       # vendored pure-Dart sherpa-onnx bindings
third_party/native/           # downloaded libsherpa-onnx-c-api (gitignored)
models/                       # downloaded speech models (gitignored)
scripts/                      # fetch_native.sh, fetch_models.sh
examples/poc_server           # loopback + agent servers, self-tests
examples/poc_client           # Flutter/web client
```
