---
name: add-new-provider
description: Use when adding or switching an STT, TTS, or LLM backend (STT_BACKEND, TTS_BACKEND, LLM_BACKEND) in the ClinicGuard server, or adding provider-specific settings to server/config.py. Follow this checklist in order — each step is cross-coupled with the next.
---

# Adding a new provider (STT / TTS / LLM)

Adding a backend touches ~6 files in a strict order. Missing step 5 (LLM only) produces a silent fallback bug in summaries. Run every step from `server/` (settings load `.env` relative to cwd).

## Checklist

1. **`server/config.py`** — add `Settings` fields: a `<name>_backend`-style switch only if introducing a new backend category, plus the provider's key/model/voice fields. Match the existing comment style (e.g. the `# --- STT ---` blocks).

2. **`server/.env.example`** — add the new vars with one-line docs. Never touch the real `.env`.

3. **`server/plugins/<name>_<kind>.py`** — new subclass (e.g. `livekit.agents.stt.STT` / `tts.TTS`). Use `whisper_stt.py` / `piper_tts.py` as the template: module-level model cache + `threading.Lock`, `asyncio.to_thread` for blocking inference, offline-first downloads, `prewarm()` for local models. Register nothing here — the factory does it.

4. **`server/agent.py`** — add a branch in the matching factory `build_llm()` / `build_tts()` / `build_stt()` using a **lazy import** inside the function; add the `_prewarm()` hook if the new model is local.

5. **LLM only: `server/triage/summarizer.py`** — update `_client()` (~line 37) and `_default_model()` (~line 46). This is the dupe LLM switch that is routinely forgotten; if it stays on the old backend, summaries silently fall back.

6. **`server/pyproject.toml`** — add the SDK dependency, then `uv sync`.

7. **Verify** — run the `verify-stack` skill (server path: `uv run python agent.py console` and uvicorn + `curl localhost:8000/health`).

## Fallback interaction

If the new backend is an LLM, consider wiring it into `LLM_FALLBACK_BACKEND` for 429 auto-failover (see `fallback_llm.py`). Default `llm_backend` is `opencode`; README may still read Groq-first — trust `config.py` + `.env.example`.