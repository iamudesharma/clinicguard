<div align="center">

# 🏥 ClinicGuard — Voice AI Clinical Triage Dispatcher

**Low-latency, multilingual (English + Hindi) voice triage demo.**
Flutter client (iOS · Android · Web · macOS) + Python voice agent — built entirely on free tiers.

![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-voice_forge-0175C2?logo=dart)
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

> **LiveKit-free (default):** the app now talks to **voice_forge** — a 100% Dart
> voice-agent framework in this repo (`voice_forge/`) that replaces LiveKit
> Cloud + `livekit.agents`. No accounts, no tokens: a single Dart binary runs
> the whole agent (webrtc_dart + sherpa-onnx VAD/STT/TTS) in ~90 MB RAM.
> The Python backend remains the control plane (patients, summaries, Supabase).
> The legacy LiveKit path still works; see [voice_forge/README.md](voice_forge/README.md).

## 🧠 Features

- **Instant barge-in** — server-side Silero VAD is authoritative: when you talk
  over the agent it interrupts in ~2 ms (verified end-to-end). A pure-Dart
  energy VAD (`app/lib/vad/`) remains for local ducking experiments.
- **Local STT** — sherpa-onnx Whisper (multilingual, auto-detects en/hi) on the
  voice_forge agent; the Python path uses a custom `faster-whisper` plugin.
- **Local TTS** — sherpa-onnx Piper (en + hi voices); the Python path adds
  optional **Kokoro-82M ONNX**.
- **Multiple LLM providers** — Groq, OpenRouter, or **OpenCode Zen** (OpenAI-compatible),
  with automatic **429 failover + cooldown**.
- **Live EHR extraction** — Pydantic-AI structured output every 3 turns and at call end;
  the summary card updates in real time over the data channel **and** Supabase realtime.
- **Clinical tool chain** — `register_patient`, `record_vitals`, `add_symptom`,
  `assign_urgency` with placeholder-input rejection.
- **One codebase, four platforms** — iOS, Android, Web, macOS.

## 🏗 Architecture

**LiveKit-free path (default):**

```
Flutter app (iOS/Android/web/macOS)          [voice_forge_flutter package]
│  mic → WebRTC (flutter_webrtc) ──ws /signal──►  voice_forge Dart agent
│  data channel "agent.events" ◄──────────────┤  webrtc_dart (SFU-free P2P)
│  (user_transcript / assistant_text /         │  Opus → Silero VAD → Whisper STT
│   agent_state / summary / barge_in)          │  → Groq/OpenAI LLM → Piper TTS
└──────────────┬───────────────────────────────┘  transcripts POST /sessions/{id}/transcripts
               ▼
[ Python FastAPI control plane ]  patients · summaries · Supabase (EHR realtime)
```

**Legacy LiveKit path** (still functional):

```
Flutter app ── LiveKit client ⇄ LiveKit Cloud (free) ── Python backend (LiveKit Agents + FastAPI)
```

## 📁 Repo layout

```
server/   Python backend (control plane + legacy LiveKit agent)
  agent.py                voice agent entrypoint (legacy LiveKit path)
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
  rag/embeddings.py       embeddings client (EMBEDDING_* > OpenAI > free OpenRouter nemotron-3-embed-1b)
  scripts/rag_build.py    RAG pipeline: fetch MedQuAD (CC BY 4.0) + curated snippets → embed → Supabase pgvector
  rag_data/               curated ClinicGuard snippets + downloaded MedQuAD (gitignored)
  api/main.py             FastAPI: /token, /patients, /sessions/{id}/summary, /transcripts, /rag/{status,search,ingest}
  supabase/schema.sql     tables + RLS policies
voice_forge/  100% Dart voice-agent framework (LiveKit-free, see voice_forge/README.md)
  packages/voice_forge            transport + speech (sherpa-onnx) + LLM + session loop
  packages/voice_forge_flutter    VoiceCallController (flutter_webrtc client)
  examples/clinicguard_agent    THIS project's triage agent (greeting, summary, EHR bridge)
  examples/poc_server|client    transport + agent POCs with self-tests
app/      Flutter client (iOS, Android, Web, macOS)
  lib/vad/                pure-Dart energy VAD (local ducking experiments)
  lib/state/call_state.dart   VoiceCallController + agent.events handling
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
**RAG embeddings** use OpenRouter's free `nvidia/nemotron-3-embed-1b` when `OPENROUTER_API_KEY` is set (no extra cost); the knowledge base itself is MedQuAD (CC BY 4.0) + curated ClinicGuard snippets.

### 2. Run the backend

**LiveKit-free path (recommended):**

```bash
cd voice_forge
./scripts/fetch_native.sh && ./scripts/fetch_models.sh   # once: sherpa lib + models
cd examples/clinicguard_agent
dart run bin/agent.dart &        # 1) voice triage agent (ws://:8765/signal)

cd ../../server
cp .env.example .env             # fill in the Groq key (or set GROQ_API_KEY in env)
uv sync
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000   # 2) control plane
```

**Legacy LiveKit path** (optional — same as before):

```bash
cd server
uv run python agent.py console   # 1) verify the voice loop in your terminal
uv run python agent.py dev       # 2) connect the agent to LiveKit Cloud
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000   # 3) control plane
```

### 3. Run the app

| Platform | Command | Notes |
|---|---|---|
| **Web** | `flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000` | localhost works with mic; CORS enabled |
| **macOS** | `flutter run -d macos --dart-define=API_BASE_URL=http://127.0.0.1:8000` | entitlements pre-configured |
| **iOS** | `flutter run --dart-define=API_BASE_URL=http://<mac-lan-ip>:8000 --dart-define=VOICE_FORGE_SIGNALING_URL=ws://<mac-lan-ip>:8765/signal` | physical iPhone (simulator has no mic) |
| **Android** | same as iOS | RECORD_AUDIO permission auto-added |

The voice_forge agent endpoint defaults to `ws://127.0.0.1:8765/signal`; point
`VOICE_FORGE_SIGNALING_URL` at your machine's LAN IP when running on a phone.
Running the app on a phone not on the same Wi-Fi? See `docs/tunneling.md`
(tunnel the voice_forge `/signal` WS + the FastAPI `/summary` endpoint).

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
- The voice_forge `/signal` WebSocket and FastAPI `/token`/`/summary` endpoints
  are intentionally unauthenticated for the demo — add a Supabase JWT check
  before any production use (`docs/tunneling.md` covers this).
- `server/.env` and `server/models/` are gitignored — never commit keys or weights.
- The Supabase publishable key in `app/lib/config.dart` is public by design.

## 🧩 Acknowledgements

- [voice_forge](voice_forge/) — our 100% Dart agent framework (webrtc_dart, sherpa-onnx, opus_codec_dart, flutter_webrtc)
- [LiveKit Agents](https://github.com/livekit/agents) — legacy voice pipeline framework
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) · [faster-whisper](https://github.com/SYSTRAN/faster-whisper) · [piper-tts](https://github.com/rhasspy/piper) · [Kokoro-82M](https://github.com/hexgrad/kokoro) · [pydantic-ai](https://github.com/pydantic/pydantic-ai)
- [OpenCode Zen](https://opencode.ai) — LLM gateway

## 📄 License

[MIT](LICENSE)
