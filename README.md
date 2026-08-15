<div align="center">

# 🏥 ClinicGuard — Voice AI Clinical Triage Dispatcher

**Low-latency, multilingual (English + Hindi) voice triage demo.**
Flutter client (iOS · Android · Web · macOS) + Python voice agent — built entirely on free tiers.

![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)
![Python](https://img.shields.io/badge/Python-3.13-3776AB?logo=python)
![LiveKit](https://img.shields.io/badge/LiveKit-Agents-00B8A9)
![License](https://img.shields.io/badge/License-MIT-green)

</div>

---

## ✨ What it does

A patient speaks to a **clinical triage assistant** in English or Hindi. The agent asks
one question at a time, follows a clinical safety protocol, runs **structured triage
tools** (register patient, record vitals, assign urgency), and generates a **live EHR
summary card** — all with instant **barge-in** (talk over the agent to interrupt it).

The full voice pipeline runs on **free tiers and local models** — no per-call cost.

## 🧠 Features

- **Instant barge-in, two layers** — server-side Silero VAD (authoritative) + a pure-Dart
  energy VAD on the phone that ducks the agent audio locally the moment you speak and
  signals the agent to interrupt (`session.interrupt()`). No native/Rust code.
- **Local STT** — custom `faster-whisper` plugin (multilingual `base`, auto-detects en/hi).
- **Local TTS** — custom Piper plugin (en + hi voices, auto-switched by script);
  optional **Kokoro-82M v1.0 ONNX** backend for higher quality.
- **Multiple LLM providers** — Groq, OpenRouter, or **OpenCode Zen** (OpenAI-compatible),
  with automatic **429 failover + cooldown**.
- **Live EHR extraction** — Pydantic-AI structured output every 3 turns and at call end;
  the summary card updates in real time over the data channel **and** Supabase realtime.
- **Clinical tool chain** — `register_patient`, `record_vitals`, `add_symptom`,
  `assign_urgency` with placeholder-input rejection.
- **One codebase, four platforms** — iOS, Android, Web, macOS.

## 🏗 Architecture

```
Flutter app (iOS/Android/web/macOS)
│  WebRTC mic ──┐
│  ┌────────────┴─────────────────────────────┐
│  │ Local barge-in (pure Dart)               │
│  │  AudioFrameCapture → energy VAD →       │
│  │   (1) instant local duck of agent audio │
│  │   (2) data msg {"event":"barge_in"}     │
│  └──────────────────────────────────────────┘
│  LiveKit client ⇄ LiveKit Cloud (free)
└───────────────┬────────────────────────────────
                ▼
[ Python backend (LiveKit Agents + FastAPI) ]
  Silero VAD → faster-whisper (local STT)
  → Groq/OpenRouter/OpenCode-Zen LLM (429 failover)
  → Piper/Kokoro TTS (local)
  data_received → session.interrupt() on barge-in
  FastAPI: /token · /patients · /sessions/{id}/summary
  Pydantic-AI EHR extraction → Supabase (RLS)
```

## 📁 Repo layout

```
server/   Python backend (LiveKit Agents + FastAPI)
  agent.py                voice agent entrypoint (VAD→STT→LLM→TTS pipeline)
  config.py               env-driven settings (every provider is swappable)
  store.py                Supabase storage with in-memory demo fallback
  plugins/whisper_stt.py  custom local faster-whisper STT plugin
  plugins/piper_tts.py    custom local Piper TTS plugin (en+hi auto-switch)
  plugins/kokoro_tts.py   optional Kokoro-82M v1.0 ONNX TTS plugin
  plugins/fallback_llm.py LLM wrapper with 429 failover + cooldown
  triage/prompts.py       clinical triage system prompt (en/hi)
  triage/tools.py         LLM function tools (register_patient, assign_urgency, ...)
  triage/summarizer.py    structured EHR summary generation (Groq/OpenRouter/Zen)
  triage/extractor.py     Pydantic-AI live EHR extraction
  api/main.py             FastAPI: /token, /patients, /sessions/{id}/summary
  supabase/schema.sql     tables + RLS policies
app/      Flutter client (iOS, Android, Web, macOS)
  lib/vad/                local barge-in: energy VAD + duck + data signal (no Rust)
  lib/state/call_state.dart   LiveKit room + data-channel event handling
  lib/screens/home_screen.dart  triage UI: status, transcripts, live EHR summary
docs/     demo script + tunneling guide
```

## 🚀 Quickstart

### Prerequisites

- Python 3.13 + [uv](https://docs.astral.sh/uv/)
- Flutter 3.x
- A Mac (or any machine) to run the Python backend — the demo models run locally

### 1. Sign up (all free, no credit card)

| Service | Needed for | Sign up |
|---|---|---|
| **LiveKit Cloud** | realtime voice transport | https://cloud.livekit.io → create project → **Project Settings → Keys** (`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`) |
| **Groq** | LLM (free tier) | https://console.groq.com → API Keys |
| **OpenCode Zen** *(optional, recommended)* | LLM via your subscription — `deepseek-v4-flash` models | https://opencode.ai/auth → copy API key |
| **OpenRouter** *(optional)* | LLM fallback | https://openrouter.ai → Keys |
| **Supabase** *(optional)* | persistence + realtime EHR sync | https://supabase.com → run `server/supabase/schema.sql` |

No signup needed for **Whisper** (STT), **Piper/Kokoro** (TTS) — models auto-download on first run.

### 2. Run the backend

```bash
cd server
cp .env.example .env      # fill in the keys
uv sync

uv run python agent.py console   # 1) verify the voice loop in your terminal
uv run python agent.py dev       # 2) connect the agent to LiveKit Cloud
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000   # 3) control plane
```

### 3. Run the app

| Platform | Command | Notes |
|---|---|---|
| **Web** | `flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000` | localhost works with mic; CORS enabled |
| **macOS** | `flutter run -d macos --dart-define=API_BASE_URL=http://127.0.0.1:8000` | entitlements pre-configured |
| **iOS** | `flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8000` | physical iPhone (simulator has no mic) |
| **Android** | same as iOS | RECORD_AUDIO permission auto-added |

Running the app on a phone not on the same Wi-Fi? See `docs/tunneling.md`
(Cloudflare Tunnel / ngrok — only the `/token` endpoint needs exposure).

### 4. Run the demo

Tap **Start triage call** and speak. Scripted scenarios (chest pain, allergic
reaction, pediatric fever in Hindi) are in `docs/demo-script.md`.

## ⚙️ Switching providers

Everything is config in `server/.env`:

```ini
# STT: whisper (local) | deepgram (cloud, $200 credit)
STT_BACKEND=whisper

# LLM: groq | openrouter | opencode (Zen API)
LLM_BACKEND=opencode
LLM_FALLBACK_BACKEND=groq
OPENCODE_MODEL=deepseek-v4-flash-free      # or deepseek-v4-flash (needs credits)

# TTS: piper (fastest) | kokoro (best local quality) | cartesia | fish
TTS_BACKEND=piper
```

## 🧪 Testing

```bash
# server: no formal test suite — verify with console mode + the API
uv run python agent.py console

# app: the repo's tests
flutter test
flutter analyze
```

## 🔒 Security notes

- This is a **demo**, not HIPAA-compliant. Use fake patient data only.
- `/token` is intentionally unauthenticated for the demo — add a Supabase JWT check before
  any production use (`docs/tunneling.md` covers this).
- `server/.env` and `server/models/` are gitignored — never commit keys or weights.
- The Supabase publishable key in `app/lib/config.dart` is public by design.

## 🧩 Acknowledgements

- [LiveKit Agents](https://github.com/livekit/agents) — voice pipeline framework
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) · [piper-tts](https://github.com/rhasspy/piper) · [Kokoro-82M](https://github.com/hexgrad/kokoro) · [pydantic-ai](https://github.com/pydantic/pydantic-ai)
- [OpenCode Zen](https://opencode.ai) — LLM gateway

## 📄 License

[MIT](LICENSE)
