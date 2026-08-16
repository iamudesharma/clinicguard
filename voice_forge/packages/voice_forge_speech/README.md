# voice_forge_speech

Pure-Dart FFI bindings for [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
(k2-fsa), the next-gen-Kaldi speech toolkit — **server-side edition**.

This is a Flutter-free, web-free build of the official `sherpa_onnx` Dart
bindings (v1.13.5, Apache-2.0) with one small patch. It is used by
[voice_forge](https://github.com/example/voice_forge) for VAD, speech-to-text,
and text-to-speech in a pure-Dart voice agent.

## What you get

- Silero **VAD** (`VoiceActivityDetector`)
- **ASR** (offline + streaming): Whisper, SenseVoice, NeMo, Zipformer
  transducer, and more (`OfflineRecognizer`, `OnlineRecognizer`)
- **TTS** (Piper/VITS and others) (`OfflineTts`)
- Speaker identification / diarization, punctuation restoration, audio
  tagging, spoken language identification, speech denoising
- WAV read/write helpers

## Why not just depend on the official `sherpa_onnx` from pub.dev?

The official package cannot be used from a pure-Dart process, which is the
whole point of voice_forge (`dart compile exe`, no Flutter engine):

- its pubspec declares `flutter: sdk: flutter` and imports
  `package:flutter/foundation.dart` — `dart pub get` refuses to resolve it,
  and importing `package:flutter` crashes in a plain Dart VM;
- it is a Flutter plugin: it bundles the native libraries through nine
  platform sub-packages (`sherpa_onnx_macos`, `sherpa_onnx_linux`, …) that
  are only wired up by the Flutter plugin loader.

So this package is the same upstream bindings (v1.13.5, Apache-2.0), adapted
for a server process that downloads its own `libsherpa-onnx-c-api`.

## Exact changes vs the official v1.13.5

Everything except the items below is byte-identical to the official package,
including all of `lib/src/*` (the 87 KB `sherpa_onnx_bindings.dart` FFI
surface and every recognizer/TTS/VAD/config file):

| File | Change | Why |
| ---- | ------ | --- |
| `pubspec.yaml` | Removed `flutter: sdk: flutter`, the `flutter:` plugin section, and the 9 `sherpa_onnx_*` platform packages | `dart pub get` fails on any package with a Flutter SDK dependency |
| `lib/src/init_native.dart` | Added `setSherpaLibrary(DynamicLibrary)`; on macOS the host-injected handle is used instead of the bundled `.xcframework` path | voice_forge loads the dylib itself; on macOS a host-loaded library is not visible to `DynamicLibrary.process()` (RTLD_LOCAL), so the handle must be injected |
| `lib/voice_forge_speech.dart` (entry) | Dropped the `package:flutter/foundation.dart` import and the two `kIsWeb` web branches; removed the web conditional imports/exports; added the `setSherpaLibrary` re-export | `package:flutter` cannot be imported in a pure Dart VM |
| deleted | `lib/src/web/` (17 files) + `lib/src/init_stub.dart` | Web/WASM loader is dead code server-side |

Keeping upstream attribution: LICENSE is untouched (Apache-2.0, Xiaomi
Corporation), and the upstreaming of the `setSherpaLibrary` patch is
encouraged so this fork can shrink over time.

## Getting started

1. Get the native library. From the voice_forge repo:
   `./scripts/fetch_native.sh` downloads `libsherpa-onnx-c-api` for your OS/arch.
   (Any other copy of the library works too — pass its path to `initBindings`.)
2. Add the dependency:

```yaml
dependencies:
  voice_forge_speech: ^1.13.5
```

3. Initialize once before creating any recognizer/TTS/VAD object:

```dart
import 'package:voice_forge_speech/voice_forge_speech.dart';

void main() {
  initBindings(); // or initBindings('/path/to/native/lib')
  // ... create VoiceActivityDetector / OfflineRecognizer / OfflineTts
}
```

Note: `initBindings()` must be called **in every isolate** that uses
sherpa-onnx APIs — each isolate has its own FFI binding state.

For concrete end-to-end usage see the `dart-api-examples/` folder in the
upstream repository.

## License

Apache-2.0, copyright Xiaomi Corporation (see `LICENSE`). This is a vendored
derivative of the official bindings; keep upstream attribution intact when
redistributing.
