from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # --- LiveKit ---
    livekit_url: str = ""
    livekit_api_key: str = ""
    livekit_api_secret: str = ""

    # --- STT ---
    # whisper = local faster-whisper on this machine (free, unlimited)
    # deepgram = streaming Nova-3 (uses the free $200 credit)
    stt_backend: str = "whisper"
    whisper_model: str = "base"  # tiny|base|small (multilingual; no ".en" suffix)
    whisper_language: str = ""   # "" = auto-detect per segment (en/hi)
    whisper_compute_type: str = "int8"
    whisper_beam_size: int = 1
    deepgram_api_key: str = ""
    deepgram_model: str = "nova-3"
    deepgram_language: str = "multi"
    deepgram_detect_language: bool = True

    # --- LLM ---
    # groq = Groq free tier; openrouter = OpenRouter (free :free models);
    # opencode = OpenCode Zen API (OpenAI-compatible; needs OPENCODE_API_KEY).
    # LLM_FALLBACK_BACKEND (empty = none) enables 429 auto-failover to the other provider.
    llm_backend: str = "groq"
    llm_fallback_backend: str = ""
    groq_api_key: str = ""
    llm_model: str = "llama-3.3-70b-versatile"
    llm_temperature: float = 0.3
    openrouter_api_key: str = ""
    openrouter_model: str = "openai/gpt-oss-20b:free"
    # OpenCode Zen (https://opencode.ai/auth -> API key; workspace balance needed
    # for paid models; deepseek-v4-flash-free works without balance)
    opencode_api_key: str = ""
    opencode_model: str = "deepseek-v4-flash-free"
    opencode_base_url: str = "https://opencode.ai/zen/v1"
    llm_cooldown_seconds: float = 60.0
    # per-request timeout for LLM calls (s); lower = fail over faster to the fallback
    llm_timeout_seconds: float = 15.0

    # --- TTS ---
    # piper = local piper-tts (fastest, ~150ms/sentence, more robotic)
    # kokoro = local Kokoro-82M v1.0 ONNX (best local quality, ~1.5-2.5s/sentence on CPU)
    # cartesia = cloud Sonic 3.5 (free 20k credits/mo, multilingual)
    # fish = LiveKit Inference fishaudio/s2.1-pro-free (en-only)
    tts_backend: str = "piper"
    # piper voice names; "<...>-low" variants are faster and lighter on RAM
    piper_en_voice: str = "en_US-lessac-medium"
    piper_hi_voice: str = "hi_IN-rohan-medium"
    # kokoro voices (v1.0): en: af_bella/af_heart/am_liam... hi: hf_alpha/hf_beta/hm_omega/hm_psi
    kokoro_en_voice: str = "af_bella"
    kokoro_hi_voice: str = "hf_alpha"
    cartesia_api_key: str = ""
    cartesia_model: str = "sonic-3.5"
    # en-US voice "Jacqueline"; swap for a Hindi-capable voice (see docs.cartesia.ai)
    cartesia_voice_id: str = "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc"
    fish_voice_id: str = "bf322df2096a46f18c579d0baa36f41d"

    # --- Supabase (empty values -> in-memory demo store) ---
    supabase_url: str = ""
    supabase_service_key: str = ""
    supabase_anon_key: str = ""

    # --- API server ---
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    # comma-separated list of allowed browser origins for the web client;
    # "*" = allow any (demo). Only needed for Flutter web.
    cors_origins: str = "*"

    # --- Agent ---
    agent_name: str = "triage-dispatch"
    room_prefix: str = "clinic"
    greeting: str = (
        "Namaste and welcome to the clinic. I am your triage assistant. "
        "I can help you in English or Hindi. Please tell me your name, age, and what is bothering you."
    )


@lru_cache
def get_settings() -> Settings:
    return Settings()
