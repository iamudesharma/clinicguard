---
name: verify-stack
description: Use after any change to server/, app/, or voicepipe/ to run the repo's only verification paths. There is no CI and no server test suite — these commands ARE the gates.
---

# Verify the stack

Run only the components you touched; run all three if unsure. Each component has exactly one smoke path — do not invent others (e.g. there is no pytest).

## Server (`server/`)

```bash
cd server && uv sync          # after touching pyproject.toml
uv run python agent.py console   # fastest: full voice loop in terminal
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000 &
curl localhost:8000/health    # -> healthy JSON
```

Cold start is 5-40s (Whisper/Piper models prewarm once per process — `JobExecutorType.THREAD`). First turn is the slow one.

## App (`app/`)

```bash
cd app && flutter test && flutter analyze
```

Tests are only `test/barge_in_detector_test.dart` + `test/widget_test.dart`. flutter_lints is the only linting. Device runs: simulator has no mic; physical iPhone needs `--dart-define=API_BASE_URL=http://<mac-lan-ip>:8000`.

## voicepipe (from `voicepipe/examples/poc_server`)

```bash
dart run bin/agent_self_test.dart   # multi-turn agent loop -> must end "RESULT: PASS"
dart run bin/speech_check.dart      # offline VAD/STT/TTS check -> "RESULT: PASS"
dart run bin/self_test.dart         # WebRTC transport loopback -> "RESULT: PASS"
```

Plus, in `examples/poc_client` AND `packages/voicepipe_flutter`:

```bash
flutter test && flutter analyze
```

**Gates:** every self-test must end with `RESULT: PASS`; any failure means the change is not done. The agent needs `models/` + `third_party/native/` (fetched by `scripts/fetch_models.sh` / `fetch_native.sh`).