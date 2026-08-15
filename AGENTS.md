# AGENTS.md

ClinicGuard — free-tier voice AI clinical triage demo. `app/` (Flutter client) + `server/` (Python FastAPI control plane + legacy LiveKit agent). `README.md` is an accurate architecture overview; `docs/tunneling.md` covers exposing the backend to a phone.

`voicepipe/` is a separate project inside this repo (branch `voicepipe`): a 100% Dart, LiveKit-free voice-agent framework. **The app now talks to the voicepipe ClinicGuard agent by default** (no LiveKit Cloud, no tokens). See `voicepipe/README.md` for status.

## voicepipe commands

```bash
# setup (once, from voicepipe/):
./scripts/fetch_native.sh      # libsherpa-onnx-c-api (prebuilt)
./scripts/fetch_models.sh      # silero VAD + whisper tiny + piper (to models/)

# ClinicGuard triage agent (from voicepipe/examples/clinicguard_agent):
dart run bin/agent.dart            # the agent the app connects to (ws://:8765/signal)
dart run bin/self_test.dart        # greeting+turns+summary+EHR-bridge -> RESULT: PASS
dart run bin/summary_check.dart    # offline summary-generation check

# POC agent/transport (from voicepipe/examples/poc_server):
dart run bin/agent_server.dart      # generic voice agent
dart run bin/agent_self_test.dart   # multi-turn + barge-in test -> RESULT: PASS
dart run bin/speech_check.dart      # offline VAD/STT/TTS check -> RESULT: PASS
dart run bin/server.dart            # transport-only loopback server
dart run bin/self_test.dart         # WebRTC loopback -> RESULT: PASS

# framework unit tests (from voicepipe/packages/voicepipe):
dart test && dart analyze           # 12 tests, keep green

# client (from voicepipe/examples/poc_client):
flutter run -d chrome               # mic -> agent -> TTS in the browser
flutter test / flutter analyze      # keep green after any change
```

Notes: the agent needs `models/` + `third_party/native/` (gitignored, fetched
by the scripts) and runs from the example dirs (relative model paths).
LLM comes from env: `GROQ_API_KEY`/`OPENAI_API_KEY` (or
`VOICEPIPE_LLM_BASE_URL/API_KEY/MODEL`); without a key it falls back to an
offline echo LLM. `VOICEPIPE_WHISPER_MODEL=tiny|base` picks the STT model.
Agent speech stack is sherpa-onnx (vendored pure-Dart bindings in
`third_party/sherpa_onnx`). Kill stray servers with `lsof -ti:8765 | xargs kill`.

## Commands

Server (uv-managed, Python 3.13 — all commands run from `server/`):
```bash
cd server && uv sync
uv run python agent.py console   # fastest iteration: voice loop in terminal (no LiveKit Cloud needed)
uv run python agent.py dev       # connect to LiveKit Cloud + hot reload
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
```

App (from `app/`):
```bash
flutter pub get
flutter test              # tests: lib/vad detector + home screen smoke
flutter analyze           # flutter_lints is the only linting in the repo
flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8000 --dart-define=VOICEPIPE_SIGNALING_URL=ws://<mac-lan-ip>:8765/signal   # physical iPhone (simulator has no mic)
```
Web/macOS can point both at `127.0.0.1` directly (no tunnel). On a phone,
`VOICEPIPE_SIGNALING_URL` (voicepipe agent, port 8765) and `API_BASE_URL`
(FastAPI, port 8000) must both be reachable; `docs/tunneling.md` covers
exposing them.

## Server gotchas

- Settings come from `server/.env` via pydantic-settings (`config.py`); the file is loaded relative to cwd, so run server commands from `server/`. `cp .env.example .env` before first run. Never commit `.env` (contains live keys) or `server/models/` (downloaded weights, gitignored).
- Everything is provider-switchable via `.env`: `STT_BACKEND` (whisper|deepgram), `TTS_BACKEND` (piper|kokoro|cartesia|fish), `LLM_BACKEND` (groq|openrouter|opencode) + `LLM_FALLBACK_BACKEND` (auto 429 failover with cooldown). Default is now opencode/piper/whisper — README still reads as Groq-first; trust `.env.example` + `config.py`.
- First turn has a 5–40s cold start: Whisper/Piper models prewarm in `_prewarm()` and the agent uses `JobExecutorType.THREAD` so one process loads the model once. Don't switch that.
- No Python test suite, linter, or formatter is configured — verify changes by `uv run python agent.py console` or uvicorn + `curl localhost:8000/health`.
- `/token` (legacy LiveKit path) and the voicepipe bridge endpoints
  (`POST /sessions/{room}/transcripts`, `GET /sessions/{room}/summary`) are
  intentionally unauthenticated (demo); don't add auth without checking
  `docs/tunneling.md`'s security notes.
- Store (`store.py`) uses Supabase only when `SUPABASE_URL` + key are set, else in-memory.

## App gotchas

- `lib/vad/barge_in_detector.dart` is pure Dart by design — no native/Rust code, ever. (The former livekit-based `barge_in_controller.dart` was removed when the app moved to voicepipe; barge-in now happens server-side via the agent's own VAD.)
- Data-channel contract between app and agent (keep `app/lib/state/call_state.dart` and `voicepipe/examples/clinicguard_agent/bin/agent.dart` in sync): the agent publishes JSON on the `agent.events` data channel with a `type` field (`user_transcript`, `assistant_text`, `agent_state`, `summary`, plus `connected` with the room id); the app may send `{"event":"barge_in"}` / `{"event":"end_call"}` on the same channel.
- `lib/config.dart` holds `API_BASE_URL` (FastAPI control plane), `VOICEPIPE_SIGNALING_URL` (voicepipe agent), Supabase URL + anon key — all overridable via `--dart-define`; the Supabase key is publishable by design, do not treat as secrets.

## Repo conventions

- Git repo has no commits/CI yet — first commit should exclude `server/.env` and `server/models/`.
- Demo-only project: fake patient data, not HIPAA-compliant. Keep prompts/transcripts to test data.
