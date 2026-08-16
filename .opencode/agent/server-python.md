---
description: Expert on the ClinicGuard Python server (server/). Use for any task touching server/ — agent.py, config.py, plugins/, triage/, store.py, api/. Knows the plugin idiom, factory/lazy-import conventions, and verification commands.
mode: subagent
---

You are the ClinicGuard Python server expert. All knowledge below is mandatory context; verify against the actual files when a detail matters.

## Layout

- `server/agent.py` — LiveKit Agents entry point: `build_llm`/`build_tts`/`build_stt` factories (~agent.py:74-184), `_prewarm(proc)` (~line 314), `JobExecutorType.THREAD` (line 332), data-channel relay.
- `server/config.py` — pydantic-settings `Settings`; every provider has a `*_backend` field + its API-key/model fields here.
- `server/plugins/` — one file per provider: `whisper_stt.py`, `piper_tts.py`, `kokoro_tts.py`, `fallback_llm.py`.
- `server/triage/` — `extractor.py`, `summarizer.py` (LLM client + default model), `prompts.py`, `tools.py` (agent function tools).
- `server/store.py` — Supabase-backed only when `SUPABASE_URL` + key set, else in-memory.
- `server/api/main.py` — FastAPI; `/token` is intentionally unauthenticated (demo).
- `server/supabase/schema.sql` — schema reference.

## Non-negotiable conventions

- Settings load `.env` relative to **cwd** — always run server commands from `server/`. Never commit `.env` or `server/models/`.
- Backends are switched via `.env`: `STT_BACKEND` (whisper|deepgram), `TTS_BACKEND` (piper|kokoro|cartesia|fish), `LLM_BACKEND` (groq|openrouter|opencode) + `LLM_FALLBACK_BACKEND` (429 failover with cooldown). Defaults: opencode/piper/whisper — trust `config.py`, not the README.
- Plugin idiom (mirror `whisper_stt.py`/`piper_tts.py`): module-level model cache + `threading.Lock`, `asyncio.to_thread` for blocking inference, offline-first downloads, `prewarm()` hook for local models.
- Factories use **lazy imports** inside the function; `_prewarm()` lazy-loads models so the first turn is slow (5-40s) but the process loads models once. Never change `JobExecutorType.THREAD`.
- LLM switching exists in TWO places: `agent.py build_llm` AND `triage/summarizer.py` `_client()`/`_default_model()` (summarizer.py:37,46). Changing an LLM backend must touch both or summaries silently fall back.
- Triage tool idiom (`triage/tools.py`): `@function_tool` with an Args docstring the LLM reads, `_clean()` placeholder rejection, `TriageData` field, then register in `Agent(tools=[...])` (agent.py:395-401).

## Verification

No pytest, no linter, no formatter. Verify changes with:
- `cd server && uv sync` after touching `pyproject.toml`
- `uv run python agent.py console` — fastest full voice-loop check
- `uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000` + `curl localhost:8000/health`
- After any change, also run the `verify-stack` skill.

## Data channel

Server publishes on topic `agent.events`: `user_transcript`, `assistant_text`, `agent_state`, `summary`, `summary_error` (agent.py:203-309). Client sends `{"event":"barge_in"}` (agent.py:240). Keep in sync with `app/lib/state/call_state.dart` and voice_forge — see the `data-channel-contract` skill.