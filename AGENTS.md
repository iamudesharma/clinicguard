# AGENTS.md

ClinicGuard — free-tier voice AI clinical triage demo. `app/` (Flutter client) + `server/` (Python FastAPI control plane + legacy LiveKit agent). `README.md` is an accurate architecture overview; `docs/tunneling.md` covers exposing the backend to a phone.

`voice_forge/` is a separate project inside this repo (branch `voice_forge`): a 100% Dart, LiveKit-free voice-agent framework. **The app now talks to the voice_forge ClinicGuard agent by default** (no LiveKit Cloud, no tokens). See `voice_forge/README.md` for status.

## voice_forge commands

```bash
# setup (once, from voice_forge/):
./scripts/fetch_native.sh      # libsherpa-onnx-c-api (prebuilt)
./scripts/fetch_models.sh      # silero VAD + whisper tiny + piper (to models/)

# ClinicGuard triage agent (from voice_forge/examples/clinicguard_agent):
dart run bin/agent.dart            # the agent the app connects to (ws://:8765/signal)
dart run bin/self_test.dart        # greeting+turns+summary+EHR-bridge -> RESULT: PASS
dart run bin/summary_check.dart    # offline summary-generation check

# RAG knowledge base (from server/):
uv run python scripts/rag_build.py              # download MedQuAD (CC BY 4.0) + curated snippets, embed, upsert to Supabase pgvector
uv run python scripts/rag_build.py --verify     # stats + sample retrieval queries (no rebuild)
curl localhost:8000/rag/status                  # chunk count + embeddings provider
curl -X POST localhost:8000/rag/search -H 'Content-Type: application/json' -d '{"query":"fever and cough","k":3}'
# The agent auto-retrieves top-k chunks per user turn (POST /rag/search) and
# injects them as grounding; it also has tool calling: get_available_slots /
# book_appointment (voice-driven mid-call booking) / search_knowledge.
# Auto-retrieval is gated (agent.dart `_shouldRetrieve`): chatter, short
# turns, and the booking flow skip it, and a 900 ms hard budget (`_retrievalBudget`)
# caps worst-case latency so the voice loop stays responsive.
# Requires: pgvector enabled once in Supabase SQL editor (`create extension vector;`
# + re-apply server/supabase/schema.sql), and an embeddings provider: OPENROUTER_API_KEY
# (free nvidia/nemotron-3-embed-1b:free, default), OPENAI_API_KEY, or EMBEDDING_*.
# Without Supabase, /rag/search falls back to in-memory TF-IDF scoring.
# POC agent/transport (from voice_forge/examples/poc_server):
dart run bin/agent_server.dart      # generic voice agent
dart run bin/agent_self_test.dart   # multi-turn + barge-in test -> RESULT: PASS
dart run bin/speech_check.dart      # offline VAD/STT/TTS check -> RESULT: PASS
dart run bin/server.dart            # transport-only loopback server
dart run bin/self_test.dart         # WebRTC loopback -> RESULT: PASS

# framework unit tests (from voice_forge/packages/voice_forge):
dart test && dart analyze           # 31 tests, keep green

# client (from voice_forge/examples/poc_client):
flutter run -d chrome               # mic -> agent -> TTS in the browser
flutter test / flutter analyze      # keep green after any change
```

Notes: the agent needs `models/` + `third_party/native/` (gitignored, fetched
by the scripts). Standalone users don't — `SherpaKit.load()` auto-downloads
the native library (cache: `~/.cache/voice_forge/native/`, override
`VOICE_FORGE_NATIVE_DIR`) and missing standard models on first run
(`autoDownload: false` opts out). The agent runs from the example dirs
(relative model paths).
LLM comes from env with automatic failover, in this order: **Cline first**
(`CLINE_API_KEY`, `CLINE_MODEL`, default `poolside/laguna-s-2.1:free`, base
`https://api.cline.bot/api/v1` — note Cline wraps responses in a `data`
object, which `OpenAiCompatibleLlm` unwraps automatically), then **OpenCode
Zen** (`OPENCODE_API_KEY`, `OPENCODE_BASE_URL`, `OPENCODE_MODEL`, default
`laguna-s-2.1-free` — no chain-of-thought, fastest TTFT ~1.5s; requires the
`x-opencode-client`/`x-opencode-*` headers that `OpenAiCompatibleLlm` adds
automatically for opencode.ai base URLs, otherwise Zen answers
FreeUsageLimitError), then **OpenCode Go** (`OPENCODE_GO_API_KEY`,
`OPENCODE_GO_MODEL`, default `kimi-k3`, base
`https://opencode.ai/zen/go/v1` — paid tier, no rate limits; ordered LAST of
the opencode providers so billing only starts when the free ones fail),
then Google Gemini (`GEMINI_API_KEY`, `GEMINI_MODEL`,
default `gemini-3.7-flash`, OpenAI-compatible base URL
`https://generativelanguage.googleapis.com/v1beta/openai/`), then OpenRouter
(`OPENROUTER_API_KEY`, `OPENROUTER_MODEL`, default `openai/gpt-oss-20b:free`),
then Groq (`GROQ_API_KEY`) and OpenAI (`OPENAI_API_KEY`) (last resort), and
finally an offline echo LLM when no key is set. Keys come from the respective
provider dashboards (Cline: app.cline.bot, OpenCode: opencode.ai/auth, Gemini:
https://aistudio.google.com). After 3 consecutive
primary failures the provider is marked down for 60 s
(`FallbackLlm` in `packages/voice_forge/lib/src/llm/llm.dart`) and the agent
returns to the primary provider automatically when its quota recovers;
429/rate-limit errors are retried once (transient quota bursts, e.g. Google's
~20 req/min free tier) and otherwise mark the provider down immediately for
5 min with exponential backoff to 60 min so the chain skips it instead of
paying a wasted round trip every turn. The explicit
`VOICE_FORGE_LLM_BASE_URL/API_KEY/MODEL` trio overrides the whole chain.
`VOICE_FORGE_LLM_TIMEOUT_SECONDS` (default 45) raises the
per-call LLM timeout — needed for slow free-tier providers (e.g. OpenRouter
`:free` models). `VOICE_FORGE_WHISPER_MODEL=tiny|base` picks the STT model.
Agent speech stack is sherpa-onnx (vendored pure-Dart bindings in
`packages/voice_forge_speech`, published as its own package; the `voice_forge`
package uses it via a temporary `dependency_overrides` path until it's live
on pub.dev — see `voice_forge/PUBLISHING.md`). Kill stray servers with `lsof -ti:8765 | xargs kill`.
Logging gotcha: NEVER call `stdout.flush()` in the agent — Dart's piped stdout
binds its sink during flush's async drain, so the next `writeln` throws
"Bad state: StreamSink is bound to a stream" and can crash the server.
Use plain `print`/`safeLog` (crash-proof wrapper in agent.dart).

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
flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8000 --dart-define=VOICE_FORGE_SIGNALING_URL=ws://<mac-lan-ip>:8765/signal   # physical iPhone (simulator has no mic)
```
Web/macOS can point both at `127.0.0.1` directly (no tunnel). On a phone,
`VOICE_FORGE_SIGNALING_URL` (voice_forge agent, port 8765) and `API_BASE_URL`
(FastAPI, port 8000) must both be reachable; `docs/tunneling.md` covers
exposing them.

## Server gotchas

- Settings come from `server/.env` via pydantic-settings (`config.py`); the file is loaded relative to cwd, so run server commands from `server/`. `cp .env.example .env` before first run. Never commit `.env` (contains live keys) or `server/models/` (downloaded weights, gitignored).
- Everything is provider-switchable via `.env`: `STT_BACKEND` (whisper|deepgram), `TTS_BACKEND` (piper|kokoro|cartesia|fish), `LLM_BACKEND` (gemini|groq|openrouter|opencode) + `LLM_FALLBACK_BACKEND` (auto 429 failover with cooldown). Default is now gemini/piper/whisper — Gemini primary (`gemini_api_key`/`gemini_model`/`gemini_base_url` from `GEMINI_API_KEY`/`GEMINI_MODEL`/`GEMINI_BASE_URL`, default `gemini-3.7-flash` via `https://generativelanguage.googleapis.com/v1beta/openai/`) with `LLM_FALLBACK_BACKEND=groq` for 429 failover; trust `.env.example` + `config.py`.
- First turn has a 5–40s cold start: Whisper/Piper models prewarm in `_prewarm()` and the agent uses `JobExecutorType.THREAD` so one process loads the model once. Don't switch that.
- No Python test suite, linter, or formatter is configured — verify changes by `uv run python agent.py console` or uvicorn + `curl localhost:8000/health`.
- `/token` (legacy LiveKit path) and the voice_forge bridge endpoints
  (`POST /sessions/{room}/transcripts`, `PUT /sessions/{room}` — patient
  link/status, `GET /sessions` — history list with `?patient_id=`/`?owner_id=`,
  `GET /sessions/{room}/summary`, `GET /slots` + `POST|GET /bookings` —
  demo appointment booking) are intentionally unauthenticated (demo); don't
  add auth without checking `docs/tunneling.md`'s security notes.
- RAG endpoints (`GET /rag/status`, `POST /rag/search`, `POST /rag/ingest`)
  are also unauthenticated (demo). `/rag/search` defaults to Postgres full-text
  search via the `search_knowledge_keyword` RPC (generated `search_vector`
  tsvector column — zero query-time embedding calls, one fast Supabase round
  trip; `RAG_SEARCH_MODE=vector|hybrid` opts into embeddings:
  `rag/embeddings.py` = explicit `EMBEDDING_*` > `OPENAI_API_KEY` >
  `OPENROUTER_API_KEY` → free `nvidia/nemotron-3-embed-1b:free`, 2048-dim,
  via the `match_knowledge_chunks` pgvector RPC). `knowledge_chunks.embedding`
  is an *unconstrained* vector so switching models needs no schema change.
  In-memory fallback = TF-IDF-ish token scoring, so retrieval still returns
  something without Supabase.
- Store (`store.py`) uses Supabase only when `SUPABASE_URL` + key are set, else in-memory (in-memory tracks sessions in `_sessions`, bookings in `_bookings`).

## App gotchas

- Barge-in (interrupting the agent mid-speech, ChatGPT-style) has three layers: (1) the server's Silero VAD queues your interrupted utterance and still answers it; (2) the agent's instant onset gate (`AgentSession` bargeInRmsThreshold/OnsetFrames, default ~64ms) stops TTS as soon as you start talking — works for every client; (3) on web the app taps the mic PCM (`lib/vad/mic_tap_web.dart` + `barge_in_detector.dart`, both pure Dart by design — no native/Rust code, ever) and sends `{"event":"barge_in"}` the moment speech onset is detected while the agent is speaking (`CallState` arms the detector only in the `speaking` state). No AEC in the pipeline: on speakers the mic hears the agent's TTS — use headphones or raise `--dart-define=BARGE_IN_RMS_THRESHOLD` (default 0.025). In `agent_session.dart`, barge-in also drops *stale* turns: segments captured before a new utterance began are dropped (never sent to the LLM ahead of the new speech), and segments that pause briefly (~450 ms) are audio-merged into a single LLM turn instead of being answered one chunk at a time.
- Data-channel contract between app and agent (keep `app/lib/state/call_state.dart` and `voice_forge/examples/clinicguard_agent/bin/agent.dart` in sync): the agent publishes JSON on the `agent.events` data channel with a `type` field (`user_transcript`, `assistant_text`, `agent_state`, `summary` — optionally with `patient_id` — `booking_confirmed` with a `booking` object, plus `connected` with the room id); the app may send `{"event":"barge_in"}` / `{"event":"end_call"}` / `{"event":"patient_id","patient_id":"PAT-..."}` (the agent then loads the chart from `GET /patients/{id}`, injects it as LLM system context and greets the patient by name) on the same channel. Duplicate `patient_id` messages are ignored after the first. `booking_confirmed` may now fire *mid-call* (the LLM books via tool calling when the patient asks) instead of only at call end — the app already handles both.
- Tool calling lives in `voice_forge/packages/voice_forge/lib/src/llm/llm.dart` (`ToolDef`, `LlmToolCall`, `LlmReply`, `replyWithTools`) with the tool loop + per-turn knowledge injection in `agent_session.dart` (`configure(tools:, toolExecutor:, knowledgeProvider:)`); the ClinicGuard tools (`get_available_slots`, `book_appointment`, `search_knowledge`) and RAG retrieval are wired in `examples/clinicguard_agent/bin/agent.dart`. If the provider rejects `tools`, the session falls back to plain chat completions automatically. Booking mid-call sets a flag so the post-call `_maybeBookAppointment` JSON path is skipped.
- `lib/config.dart` holds `API_BASE_URL` (FastAPI control plane), `VOICE_FORGE_SIGNALING_URL` (voice_forge agent), Supabase URL + anon key — all overridable via `--dart-define`; the Supabase key is publishable by design, do not treat as secrets.
- Sign up / login (email+password via Supabase Auth) lives in `lib/screens/auth_screen.dart` + `lib/state/auth_state.dart`; guest mode ("Continue as guest") works without an account, and the auth form hides itself when Supabase is unconfigured. Signup auto-creates a patient profile (`owner_id` = auth user id) through `POST /patients`. The History tab (`lib/screens/history_screen.dart`) lists sessions via `GET /sessions?owner_id=` when signed in, unfiltered as guest. Before testing signup, disable email confirmation in the Supabase dashboard (Auth → Sign In / Providers), and re-apply `server/supabase/schema.sql` (it now includes the `bookings` table + a `with check` insert policy on `patients`).

## Repo conventions

- Git repo has no commits/CI yet — first commit should exclude `server/.env` and `server/models/`.
- Demo-only project: fake patient data, not HIPAA-compliant. Keep prompts/transcripts to test data.
