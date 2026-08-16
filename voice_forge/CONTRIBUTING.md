# Contributing to voicepipe

Thanks for wanting to help! voicepipe is a small, dependency-light voice-agent
framework; the whole point is that one person can hold it in their head.

## Project layout

```
packages/voicepipe            # pure Dart server framework
packages/voicepipe_flutter    # Flutter client (VoiceCallController)
third_party/sherpa_onnx       # vendored Apache-2.0 bindings (do not edit beyond
                              # the documented Flutter-free patches in README.md)
examples/                     # POCs + the ClinicGuard agent, each with self-tests
scripts/                      # one-command model/native downloads
```

## Design rules

1. **One dependency per concern.** Transport (`webrtc_dart`), codec
   (`opus_codec_dart`), speech (`sherpa_onnx`), HTTP (`http`). Don't add a
   framework to glue them.
2. **Providers behind interfaces.** `VoicepipeVAD/STT/TTS/LLM` — the session
   loop must never import a specific provider.
3. **Small.** Prefer a focused PR over a sweeping one; the framework should
   stay readable in one sitting.
4. **Tests.** `packages/voicepipe`: `dart test` (unit). Examples: run the
   self-tests (`RESULT: PASS` expected). Flutter: `flutter test` + analyze.

## Verifying

```bash
cd packages/voicepipe && dart test && dart analyze
cd ../voicepipe_flutter && flutter test && flutter analyze
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

Phase 5 is not done: the packages are not yet on pub.dev (`publish_to: none`).
Before publishing: real repo URL in pubspecs, CHANGELOGs, examples wiring,
and a decision on `third_party/sherpa_onnx` (publish a pure-Dart
`sherpa_onnx_dart` package instead of vendoring).
