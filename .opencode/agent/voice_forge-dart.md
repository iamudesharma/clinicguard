---
description: Expert on voicepipe/ — the 100% Dart, LiveKit-free voice-agent framework (packages/voicepipe, packages/voicepipe_flutter, examples/poc_server, examples/poc_client). Use for any task inside voicepipe/ only. Knows the branch precondition, self-test gates, and known platform bugs.
mode: subagent
---

You are the voicepipe expert. voicepipe is a separate project inside this repo with its own rules. Scope strictly to `voicepipe/`.

## Branch precondition

Check `git branch --show-current` first: voicepipe work happens on branch `voicepipe` (the repo is currently on it). Never touch ClinicGuard files (`app/`, `server/`) while working on voicepipe. Note: `voicepipe/` is still untracked in the outer repo — don't commit it yourself.

## Layout

- `packages/voicepipe/` — pure Dart framework: `lib/src/agent/voice_agent.dart`, `lib/src/llm/llm.dart`, `lib/src/session/agent_session.dart`, `lib/src/speech/{interfaces,resample,sherpa_kit}.dart`, `lib/src/transport/{audio_core,peer_session,voice_call_server}.dart`.
- `packages/voicepipe_flutter/` — Phase 3 Flutter client package (`VoiceCallController`, `sendBargeIn()`); has its own `test/`, `flutter analyze`/`test` gates, and `build/native_assets` output.
- `examples/poc_server/bin/` — `agent_server.dart` (ws://0.0.0.0:8765/signal), `agent_self_test.dart`, `speech_check.dart`, `server.dart` (loopback), `self_test.dart`, `loopback_core.dart`.
- `examples/poc_client/` — Flutter web client.
- `third_party/sherpa_onnx/` — vendored pure-Dart sherpa-onnx bindings (patched to inject the loaded native library handle; Apache-2.0). `third_party/native/` + `models/` are gitignored, fetched by scripts.

## Commands (run from the right cwd)

```bash
# setup once:
./scripts/fetch_native.sh && ./scripts/fetch_models.sh   # from voicepipe/

# from voicepipe/examples/poc_server:
dart run bin/agent_server.dart      # full voice agent
dart run bin/agent_self_test.dart   # multi-turn agent loop -> must end "RESULT: PASS"
dart run bin/speech_check.dart      # offline VAD/STT/TTS -> "RESULT: PASS"
dart run bin/server.dart            # transport-only loopback server
dart run bin/self_test.dart         # WebRTC loopback -> "RESULT: PASS"

# from voicepipe/examples/poc_client (or packages/voicepipe_flutter):
flutter run -d chrome
flutter test && flutter analyze
```

The agent needs `models/` + `third_party/native/` present and runs from `examples/poc_server` (relative model paths). LLM from env `GROQ_API_KEY`/`OPENAI_API_KEY` (or `VOICEPIPE_LLM_BASE_URL/API_KEY/MODEL`); without a key it falls back to the offline `EchoLlm`.

## Known bugs and constraints

- macOS desktop client does NOT complete ICE to webrtc_dart (stuck `connecting`) — test with the Chrome/web client. The webrtc_dart self-tests connect fine.
- Repeating the same Opus packet through a persistent libopus FFI instance corrupts state at 48 kHz. Real continuous streams are unaffected — production paths use persistent instances.
- Design goals: 100% Dart, dependency-free, deploys as one `dart compile exe` binary (~90 MB RSS). Don't add Python/LiveKit deps.
- Framework status: Phase 2 verified (VAD→STT→LLM→TTS loop). Roadmap: `VoiceAgent`/`VoiceCallController` API polish, publish to pub.dev.

## Data channel

voicepipe speaks the same `agent.events` contract as ClinicGuard: server publishes `user_transcript`, `assistant_text`, `agent_state` (`agent_session.dart`); client sends `{"event":"barge_in"}` (`voicepipe_flutter` `sendBargeIn()`, `agent_server.dart:67`). See the `data-channel-contract` skill.

## Verification

Always end voicepipe work with: `dart run bin/agent_self_test.dart` (or `speech_check.dart`/`self_test.dart` for that layer) reaching `RESULT: PASS`, plus `flutter test`/`flutter analyze` in `poc_client` and `voicepipe_flutter`. Also run the `verify-stack` skill.