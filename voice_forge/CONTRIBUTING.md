# Contributing to voice_forge

Thanks for wanting to help! voice_forge is a small, dependency-light voice-agent
framework; the whole point is that one person can hold it in their head.

## Project layout

```
packages/voice_forge            # pure Dart server framework
packages/voice_forge_flutter    # Flutter client (VoiceCallController)
packages/voice_forge_speech     # vendored Apache-2.0 bindings, own pub.dev
                              # package (do not edit beyond the documented
                              # Flutter/web-free patches in README.md)
examples/                     # POCs + the ClinicGuard agent, each with self-tests
scripts/                      # one-command model/native downloads
```

## Design rules

1. **One dependency per concern.** Transport (`webrtc_dart`), codec
   (`opus_codec_dart`), speech (`voice_forge_speech`), HTTP (`http`). Don't add a
   framework to glue them.
2. **Providers behind interfaces.** `VoicepipeVAD/STT/TTS/LLM` — the session
   loop must never import a specific provider.
3. **Small.** Prefer a focused PR over a sweeping one; the framework should
   stay readable in one sitting.
4. **Tests.** `packages/voice_forge`: `dart test` (unit). Examples: run the
   self-tests (`RESULT: PASS` expected). Flutter: `flutter test` + analyze.

## Verifying

```bash
cd packages/voice_forge && dart test && dart analyze
cd ../voice_forge_flutter && flutter test && flutter analyze
cd examples/poc_server && dart run bin/self_test.dart        # transport
cd examples/clinicguard_agent && dart run bin/self_test.dart # full agent (needs models + a Groq key)
```

## Known findings (read before touching codec/transport code)

- **Dart FFI × libopus at 48 kHz**: a persistent encoder/decoder corrupts its
  state when the *same packet bytes* are fed repeatedly (decoder output
  amplifies to full-scale; encoder output shrinks). Real phase-progressive
  streams are unaffected; all production paths use persistent instances.
- **macOS desktop ⇄ webrtc_dart ICE** does not connect (Chrome and the
  webrtc_dart self-tests do). Tracked in the README; test with the web client.
- The vendored sherpa_onnx package is patched to accept a host-injected
  `DynamicLibrary` (macOS loads the native lib explicitly). Upstreaming this
  patch is welcome.

## Releasing

See `PUBLISHING.md` for the full checklist and current compliance state.
Order: `voice_forge_speech` → `voice_forge` → `voice_forge_flutter`. Before the
first real publish: set the real repo URL in the pubspecs, drop the
temporary `dependency_overrides` once voice_forge_speech is live, and commit
from a clean tree. Until then the packages ship with `--dry-run` verification
only — nothing is uploaded.
