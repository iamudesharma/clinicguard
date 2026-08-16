# voice_forge — package publishing guide

Everything needed to publish the three Dart/Flutter packages to pub.dev:
inventory, setup, run, utilization, compliance state, and the exact release
procedure. **Nothing on this page has been uploaded** — `--dry-run` only.

## Packages

| # | Package | Version | Type | Purpose | Dependencies | Tests | License |
|---|---------|---------|------|---------|--------------|-------|---------|
| 1 | `voice_forge_speech` | 1.13.5 | Dart (pure) | Vendored, Flutter/web-free FFI bindings for sherpa-onnx (k2-fsa): Silero VAD, Whisper ASR, Piper TTS, speaker ID, denoising, WAV I/O. Host injects the native library handle. | `ffi` | — (upstream examples) | Apache-2.0 (Xiaomi Corp.) |
| 2 | `voice_forge` | 0.2.0 | Dart (pure) | Server-side voice-agent framework: WebRTC transport (`VoiceCallServer`, `PeerSession`, `audio_core`), signaling, speech interfaces + sherpa implementations (`SherpaKit`), LLM layer (`OpenAiCompatibleLlm`, `FallbackLlm`, `EchoLlm`, tool calling), conversation loop (`AgentSession`). | `http`, `opus_codec_dart`, `shelf`, `shelf_web_socket`, `voice_forge_speech`, `web_socket_channel`, `webrtc_dart` | 37 unit tests (`dart test`) | MIT |
| 3 | `voice_forge_flutter` | 0.1.0 | Flutter (pure) | Client for voice_forge agents: `VoiceCallController` — mic → WebRTC → agent, `agent.events` data channel, playback, barge-in, RTT pings. | `flutter_webrtc`, `web_socket_channel` | 2 tests (`flutter test`) | MIT |

Not published: `examples/` (`poc_server`, `poc_client`, `clinicguard_agent`) and
`app/` — all keep `publish_to: none`.

### Publish order (dependency chain)

```
voice_forge_speech  (no published deps)        -> publish FIRST
voice_forge         (needs voice_forge_speech)   -> publish SECOND
voice_forge_flutter (no in-repo deps)          -> publish THIRD
```

## Setup

Prereqs: Dart SDK ≥ 3.13 (`dart --version`), Flutter ≥ 3.24 (`flutter --version`).

```bash
# native speech library + models (once, from voice_forge/):
./scripts/fetch_native.sh      # libsherpa-onnx-c-api -> third_party/native/
./scripts/fetch_models.sh      # silero VAD + whisper tiny + piper -> models/

# resolve each package
dart pub get    # packages/voice_forge_speech, packages/voice_forge
flutter pub get # packages/voice_forge_flutter, examples/poc_client
```

LLM keys come from the environment (any of `CLINE_API_KEY` / `OPENCODE_API_KEY`
/ `OPENCODE_GO_API_KEY` / `GEMINI_API_KEY` / `OPENROUTER_API_KEY` /
`GROQ_API_KEY` / `OPENAI_API_KEY`, or the explicit
`VOICE_FORGE_LLM_BASE_URL`/`VOICE_FORGE_LLM_API_KEY`/`VOICE_FORGE_LLM_MODEL` trio).
With no key, agents run on the offline `EchoLlm` — enough to exercise the
speech stack, but LLM-dependent checks (summaries, barge-in timing) need a
real key for a full pass.

## Run (verification gates)

```bash
# 1. framework unit tests + analyze
cd packages/voice_forge && dart test && dart analyze        # 37 tests, clean
cd ../voice_forge_flutter && flutter test && flutter analyze # 2 tests, clean
cd ../voice_forge_speech && dart analyze                     # clean

# 2. transport loopback (server first, from examples/poc_server)
dart run bin/server.dart &          # transport-only server on :8765
dart run bin/self_test.dart         # -> RESULT: PASS

# 3. speech stack (VAD/STT/TTS, offline, no key needed)
dart run bin/speech_check.dart      # -> RESULT: PASS

# 4. full agent loop (agent server first; use a real LLM key)
dart run bin/agent_server.dart &    # voice agent on :8765
dart run bin/agent_self_test.dart   # -> RESULT: PASS (with real LLM key)

# 5. ClinicGuard agent (agent first; control plane on :8000 optional)
cd examples/clinicguard_agent
dart run bin/agent.dart &           # ws://:8765/signal
dart run bin/self_test.dart         # greeting+turns+summary+EHR-bridge

# 6. Flutter client
cd examples/poc_client
flutter test && flutter analyze
flutter run -d chrome               # mic -> agent in the browser
```

Known test caveat: with the offline `EchoLlm` (no key set), the barge-in
latency check in `agent_self_test` can time out (the instant echo finishes
speaking before the interrupt lands) and the LLM-generated call summary in
`clinicguard_agent` stays null. Run these with a real LLM key for the full
green pass.

## Utilization

### Server: voice_forge (`package:voice_forge/voice_forge.dart`)

```dart
import 'dart:io';
import 'package:voice_forge/voice_forge.dart';

// 1. speech stack (sherpa-onnx models; see scripts/fetch_models.sh)
final kit = SherpaKit.load(models: SherpaModels.fromModelsDir('models'));

// 2. LLM (OpenAI-compatible: OpenRouter, Groq, Gemini, OpenCode Zen, ...)
final llm = OpenAiCompatibleLlm(
  baseUrl: 'https://api.openai.com/v1',
  apiKey: Platform.environment['OPENAI_API_KEY']!,
  model: 'gpt-4o-mini',
);

// 3. agent: fresh VAD per session, one session per call
final agent = VoiceAgent(
  vadFactory: kit.createVad,   // Silero VAD is stateful — never share it
  stt: kit.speech.stt,
  tts: kit.speech.tts,
  llm: llm,
  systemPrompt: 'You are a triage assistant.',
);

final session = agent.createSession();
session.events.listen((e) => print('[${e.state}] ${e.text}'));
session.onAudio(pcm48kStereo); // feed decoded WebRTC audio

// optional tool calling
session.configure(
  tools: [ToolDef(name: 'get_weather', description: '...', parameters: {...})],
  toolExecutor: (call) async => call.name == 'get_weather' ? '20 C' : 'unknown',
);
```

Complete server wiring (WebRTC offer/answer, `agent.events` data channel,
Opus codec) lives in `examples/poc_server/bin/agent_server.dart` — the
reference implementation of the framework API.

### Client: voice_forge_flutter (`package:voice_forge_flutter/voice_forge_flutter.dart`)

```dart
final call = VoiceCallController(signalingUrl: 'ws://host:8765/signal');
call.phase.listen((p) => print(p));              // idle/connecting/connected/error
call.events.listen((e) => print(e['type']));     // user_transcript / assistant_text
call.rttMs.listen((ms) => print('RTT $ms ms'));  // data-channel round trips
await call.start();          // mic -> agent; agent audio plays automatically
call.sendBargeIn();          // instant interrupt
await call.end();            // clean teardown
```

The `events` stream carries the full data-channel contract: `user_transcript`,
`assistant_text`, `agent_state`, `summary`, `booking_confirmed`, `connected`,
plus `{'type': 'raw', ...}` for non-JSON payloads.

### Speech: voice_forge_speech (`package:voice_forge_speech/voice_forge_speech.dart`)

```dart
import 'package:voice_forge_speech/voice_forge_speech.dart';

void main() {
  initBindings(); // once per isolate; pass a path to the native lib if needed
  // VoiceActivityDetector / OfflineRecognizer / OfflineTts as in upstream
  // sherpa-onnx dart-api-examples.
}
```

## Publishing compliance — current state

### Done (verified 2026-08-16, re-verified after rename)

- [x] **Rebranded the whole project** to the `*_forge` family: `voicepipe` →
      `voice_forge`, `voicepipe_flutter` → `voice_forge_flutter`,
      `sherpa_onnx_dart` → `voice_forge_speech` (same `image_forge_core` /
      `video_forge` brand). Package dirs, entry libraries, imports, path
      deps, `dependency_overrides`, env names (`VOICEPIPE_*` →
      `VOICE_FORGE_*`), docs, and the git branch (`voicepipe` →
      `voice_forge`) all renamed; zero old-name references remain except the
      deliberate upstream `sherpa_onnx` attribution in `voice_forge_speech`.
- [x] `publish_to: none` removed from all three packages
- [x] No path dependencies inside published packages (`voice_forge` → hosted
      `voice_forge_speech: ^1.13.5`); `voice_forge_speech` moved out of
      `third_party/` into `packages/`
- [x] Web/WASM code stripped from `voice_forge_speech` (server-side only) —
      no dangling conditional imports
- [x] README.md + CHANGELOG.md present and real in all three packages
- [x] LICENSE present in all three (Apache-2.0 for sherpa bindings, MIT for
      the two voice_forge packages)
- [x] `topics:` added to all three pubspecs
- [x] `dart analyze` clean ×3, `flutter analyze` clean, tests green
- [x] `dart pub publish --dry-run` (voice_forge_speech, voice_forge) and
      `flutter pub publish --dry-run` (voice_forge_flutter) all pass
      — zero errors, only the expected pre-commit warnings

### Remaining before the real publish

- [ ] **Set the real repo URL**: both `voice_forge` pubspecs still carry
      `repository: https://github.com/example/voice_forge # TODO: set real repo`.
      Replace with the actual repository before publishing (pub.dev links it
      on the package page).
- [ ] **Check name availability**: `voice_forge_speech`, `voice_forge`,
      `voice_forge_flutter` — the dry-run does NOT reserve or check names;
      only the real publish does. If taken, bump names in all pubspecs +
      imports.
- [ ] **Drop the temporary `dependency_overrides`** (3 files:
      `packages/voice_forge/pubspec.yaml`, `examples/poc_server/pubspec.yaml`,
      `examples/clinicguard_agent/pubspec.yaml`). They exist only until
      `voice_forge_speech` is live on pub.dev; the dry-run reports them as a
      hint. Note the override must stay in the *examples* until they no
      longer need it locally — they are not published, so it is harmless
      there.
- [ ] **Commit first**: publish from a clean git state (the dry-runs warn
      about uncommitted changes). This repo's first commit must exclude
      `server/.env`, `server/models/`, `models/`, `third_party/native/`
      (already gitignored).
- [ ] **Version bumps**: keep semantic versions aligned — if you change any
      package, bump its version + CHANGELOG entry (and dependent packages if
      the API changed). Changelog dates are optional.
- [ ] Optional polish: package `example/` folders inside each package (pub.dev
      scores examples), `homepage:` field, `funding:`/`issue_tracker:` if the
      repo gains them.

### Publish commands (NOT yet run — manual, in order)

```bash
cd packages/voice_forge_speech  && dart pub publish        # FIRST
cd ../voice_forge               && dart pub publish        # SECOND (after removing dependency_overrides)
cd ../voice_forge_flutter       && flutter pub publish     # THIRD
```

Each prompts for confirmation. There is no unpublish or overwrite — verify
the printed file list and version before confirming.

## What never gets published

- `build/`, `.dart_tool/` (gitignored)
- `models/`, `third_party/native/` (downloaded weights/libs, gitignored)
- `server/` (Python control plane), `app/` (ClinicGuard app) — separate repo
  concerns, both `publish_to: none`
- `server/.env` and any credentials (gitignored; publish only ships files
  tracked in git)

## Dry-run results (2026-08-16, re-run 2026-08-16 after the rename)

| Package | Command | Result | Notes |
|---------|---------|--------|-------|
| voice_forge_speech | `dart pub publish --dry-run` | PASS (1 warning) | warning = uncommitted git changes only |
| voice_forge | `dart pub publish --dry-run` | PASS (1 warning + 1 hint) | warning = uncommitted git changes; hint = temporary dependency_overrides |
| voice_forge_flutter | `flutter pub publish --dry-run` | PASS (1 warning) | warning = uncommitted git changes |

Name availability re-checked on pub.dev before the dry-runs: all three new
names are free (404 = available). No uploads were performed. The pub.dev
server may enforce additional checks at real publish time (name/version
conflicts, email verification).
