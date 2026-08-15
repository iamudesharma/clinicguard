# AGENTS.md

ClinicGuard — free-tier voice AI clinical triage demo. `app/` (Flutter, iOS-first client) + `server/` (Python LiveKit Agents voice agent + FastAPI). `README.md` is an accurate architecture overview; `docs/tunneling.md` covers exposing the backend to a phone.

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
flutter test              # only tests in the repo (lib/vad logic)
flutter analyze           # flutter_lints is the only linting in the repo
flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8000   # physical iPhone (simulator has no mic)
```
Web/macOS can point `API_BASE_URL` at `http://127.0.0.1:8000` directly (no tunnel); only the FastAPI `/token` endpoint must be reachable from the device — the agent connects outbound to LiveKit Cloud.

## Server gotchas

- Settings come from `server/.env` via pydantic-settings (`config.py`); the file is loaded relative to cwd, so run server commands from `server/`. `cp .env.example .env` before first run. Never commit `.env` (contains live keys) or `server/models/` (downloaded weights, gitignored).
- Everything is provider-switchable via `.env`: `STT_BACKEND` (whisper|deepgram), `TTS_BACKEND` (piper|kokoro|cartesia|fish), `LLM_BACKEND` (groq|openrouter|opencode) + `LLM_FALLBACK_BACKEND` (auto 429 failover with cooldown). Default is now opencode/piper/whisper — README still reads as Groq-first; trust `.env.example` + `config.py`.
- First turn has a 5–40s cold start: Whisper/Piper models prewarm in `_prewarm()` and the agent uses `JobExecutorType.THREAD` so one process loads the model once. Don't switch that.
- No Python test suite, linter, or formatter is configured — verify changes by `uv run python agent.py console` or uvicorn + `curl localhost:8000/health`.
- `/token` is intentionally unauthenticated (demo); don't add auth without checking `docs/tunneling.md`'s security notes.
- Store (`store.py`) uses Supabase only when `SUPABASE_URL` + key are set, else in-memory.

## App gotchas

- `lib/vad/` (local barge-in) is pure Dart by design — no native/Rust code, ever.
- Data-channel contract between app and agent (keep `app/lib/state/call_state.dart` and `server/agent.py` in sync): agent publishes JSON on topic `agent.events` with a `type` field (`user_transcript`, `assistant_text`, `agent_state`, `summary`); the app sends `{"event":"barge_in"}` on the same topic for instant interrupt.
- Supabase URL + anon key defaults are hardcoded in `lib/config.dart` — publishable by design, do not treat as secrets.

## Repo conventions

- Git repo has no commits/CI yet — first commit should exclude `server/.env` and `server/models/`.
- Demo-only project: fake patient data, not HIPAA-compliant. Keep prompts/transcripts to test data.
