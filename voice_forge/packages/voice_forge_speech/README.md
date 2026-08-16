# voice_forge_speech

Pure-Dart FFI bindings for [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
(k2-fsa), the next-gen-Kaldi speech toolkit — **server-side edition**.

This is a Flutter-free, web-free build of the official `sherpa_onnx` Dart
bindings (v1.13.5, Apache-2.0) with one small patch. It is used by
[voice_forge](https://github.com/iamudesharma/clinicguard) for VAD, speech-to-text,
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

> Using the [voice_forge](https://github.com/iamudesharma/clinicguard) framework?
> `SherpaKit.load()` downloads this library automatically on first run —
> nothing below is needed.

1. **Get the native library** — this package has no bundled natives; the
   host process must be able to load `libsherpa-onnx-c-api`. Download the
   prebuilt library from the official sherpa-onnx releases
   (https://github.com/k2-fsa/sherpa-onnx/releases):

   | Platform | Asset (v1.13.5) |
   | -------- | ---------------- |
   | macOS arm64 | `sherpa-onnx-v1.13.5-osx-arm64-shared.tar.bz2` |
   | macOS x64 | `sherpa-onnx-v1.13.5-osx-x64-shared.tar.bz2` |
   | Linux x64 | `sherpa-onnx-v1.13.5-linux-x64-shared.tar.bz2` |
   | Windows / others | see the release page for `*-shared` builds |

   Each archive contains `lib/libsherpa-onnx-c-api.dylib` (macOS),
   `lib/libsherpa-onnx-c-api.so` (Linux) or `bin/sherpa-onnx-c-api.dll`
   (Windows), plus the `libonnxruntime` it links against. Place both next to
   your binary (the current working directory), on the system library search
   path, or pass the directory to `initBindings(...)`.

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
upstream repository. For a complete voice-agent built on this package, see
the [voice_forge](https://github.com/iamudesharma/clinicguard) project.

## License

Apache-2.0, copyright Xiaomi Corporation (see `LICENSE`). This is a vendored
derivative of the official bindings; keep upstream attribution intact when
redistributing.
