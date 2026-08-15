# ClinicGuard — Voice AI Clinical Triage Dispatcher

Low-latency multilingual (English + Hindi) voice triage demo: **Flutter/iOS** client +
**Python** (LiveKit Agents + FastAPI) backend, built entirely on free tiers ($0/mo).

## Architecture

```
iPhone (Flutter app)
│  WebRTC mic ──┐
│  ┌────────────┴─────────────────────────────┐
│  │ Local barge-in (pure Dart, no native deps)│
│  │  AudioFrameCapture → energy VAD →        │
│  │   (1) instant local duck of agent audio  │
│  │   (2) data msg {"event":"barge_in"}      │
│  └──────────────────────────────────────────┘
│  LiveKit client ⇄ LiveKit Cloud (free)
└───────────────┬────────────────────────────────
                ▼
[ M1 Mac — Python backend ]
  Silero VAD → faster-whisper base (local STT)
  → Groq/OpenRouter LLM (429 failover) → Piper TTS (local)
  data_received → session.interrupt() on barge_in
  FastAPI: /token · /patients · /sessions/{id}/summary
  Pydantic EHR extraction → Supabase (RLS)
```

- **Barge-in (two layers):** the authoritative detector is Silero VAD in the
  Python agent; the Flutter app additionally runs a lightweight energy VAD on
  the mic PCM stream (`app/lib/vad/`) so the agent audio is ducked locally the
  instant the user speaks, plus a data-channel signal that makes the agent call
  `session.interrupt()`. Pure Dart — no Rust/native code needed.
- **VAD / turn detection:** Silero VAD (runs locally, free) — instant interruption.
- **STT:** local `faster-whisper` (`base`, multilingual en+hi, runs on the M1 Mac via
  a custom LiveKit plugin — `server/plugins/whisper_stt.py`). Fallback: Deepgram Nova-3
  streaming (free $200 credit ≈ 34k minutes) via `STT_BACKEND=deepgram`.
- **LLM:** Groq free tier `llama-3.3-70b-versatile` (280 t/s) or OpenRouter `:free` models
  (`openai/gpt-oss-20b:free`), config-switchable with automatic **429 failover +
  cooldown** (`plugins/fallback_llm.py`, `LLM_BACKEND`/`LLM_FALLBACK_BACKEND`).
- **TTS:** local **Piper** (`server/plugins/piper_tts.py` — en_US-lessac-medium +
  hi_IN-rohan-medium, auto voice-switched by script, unlimited/free). Fallback:
  Cartesia Sonic 3.5 (free 20k credits/mo, en+hi).
- **EHR summary:** **Pydantic AI** structured extraction (`triage/extractor.py`,
  `output_type=TriageSummary`) runs **live every 3 turns** and at call end; the
  summary card updates in real time via the data channel AND Supabase realtime
  (`ehr_summaries` inserts). Data-channel push works with zero Supabase config;
  realtime sync kicks in once `SUPABASE_URL` is set.

## Repo layout

```
server/   Python backend (LiveKit Agents + FastAPI)
  agent.py              voice agent entrypoint (VAD→STT→LLM→TTS pipeline)
  config.py             env-driven settings (providers swappable)
  store.py              Supabase storage with in-memory demo fallback
  plugins/whisper_stt.py  custom local faster-whisper STT plugin
  plugins/piper_tts.py    custom local Piper TTS plugin (en+hi auto-switch)
  plugins/fallback_llm.py LLM wrapper with 429 failover + cooldown
  triage/prompts.py     clinical triage system prompt (en/hi)
  triage/tools.py       LLM function tools (register_patient, assign_urgency, ...)
  triage/summarizer.py  structured EHR summary generation
  api/main.py           FastAPI: /token, /patients, /sessions/{id}/summary
  supabase/schema.sql   tables + RLS policies
app/      Flutter client (iOS-first)
  lib/vad/                local barge-in: energy VAD + duck + data signal (no Rust)
  lib/state/call_state.dart   LiveKit room + data-channel event handling
  lib/screens/home_screen.dart triage UI: status, transcripts, summary
```

## Quickstart

### Supported platforms
The same codebase runs on **iOS, Android, web, and macOS** (livekit_client has
first-party support for all four, including the audio-frame capture used for
local barge-in — Swift on iOS/macOS, AudioWorklet on web).

| Platform | Run command | Extra setup |
|---|---|---|
| iOS | `flutter run --dart-define=API_BASE_URL=...` | physical iPhone (mic), permission already in Info.plist |
| Android | same | RECORD_AUDIO permission auto-added by livekit_client |
| **macOS** | `flutter run -d macos --dart-define=API_BASE_URL=http://127.0.0.1:8000` | mic + network entitlements already added |
| **Web** | `flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000` | needs HTTPS or localhost for mic; CORS is enabled on the backend |

Web/macOS tip: `API_BASE_URL=http://127.0.0.1:8000` works directly when the
backend runs on the same machine (no tunnel needed).

### 1. Sign up (all free, no credit card)
- LiveKit Cloud: https://cloud.livekit.io → create project → copy
  `LIVEKIT_URL` (`wss://<project>.livekit.cloud`), API key + secret.
- Deepgram: https://console.deepgram.com → `$200` credit → `DEEPGRAM_API_KEY`.
- Groq: https://console.groq.com → free key → `GROQ_API_KEY`.
- Cartesia: https://play.cartesia.ai → free tier → `CARTESIA_API_KEY`.
- (optional) Supabase: https://supabase.com → run `server/supabase/schema.sql`.

### 2. Run the backend
```bash
cd server
cp .env.example .env      # fill in the keys
uv sync
uv run python agent.py console   # test the voice loop in your terminal first
uv run python agent.py dev       # then: connect LiveKit + hot reload
uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
```

### 3. Run the iOS app
```bash
cd app
flutter pub get
# point the app at your Mac (same Wi-Fi):
flutter run --dart-define=API_BASE_URL=http://<your-mac-lan-ip>:8000
```
Use a **physical iPhone** (simulator has no working mic).

### 4. Demo
Tap **Start triage call**. Scenarios live in `docs/demo-script.md`
(chest pain, allergic reaction, pediatric fever in Hindi).

## Switching providers (fallbacks when free tiers run out)
Everything is config in `server/.env`:
- LLM: `LLM_MODEL` → any Groq model, or point `groq.LLM(base_url=...)` at OpenRouter.
- TTS: `TTS_PROVIDER=fish` (LiveKit Inference, en-only) or swap the Cartesia voice.
- STT: Deepgram credit exhausted → Groq `whisper-large-v3-turbo` ($0.04/hour).

## Security note
This is a personal demo, not HIPAA-compliant. Use fake patient data only.
