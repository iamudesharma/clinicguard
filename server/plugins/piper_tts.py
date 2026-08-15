"""Custom Piper TTS plugin for LiveKit Agents.

Sentence-streamed local text-to-speech via piper-tts (espeak-ng + ONNX).
No API cost, runs entirely on the host machine.

Voices are downloaded once from HuggingFace (``rhasspy/piper-voices``) into a
local cache directory, then loaded offline. Language switching is automatic:
text containing Devanagari is spoken with the Hindi voice, everything else
with the default (English) voice.

Usage:
    from plugins.piper_tts import PiperTTS

    tts = PiperTTS()          # defaults: en_US-lessac-medium + hi_IN-rohan-medium
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import threading
from pathlib import Path

from livekit import rtc
from livekit.agents import tts, utils
from livekit.agents.types import NOT_GIVEN, NotGivenOr
from livekit.agents.tts.tts import DEFAULT_API_CONNECT_OPTIONS
from livekit.agents.utils import is_given

logger = logging.getLogger("piper-tts")

_DEVANAGARI_RE = re.compile(r"[\u0900-\u097F]")
HF_REPO = "rhasspy/piper-voices"

_VOICE_LOCK = threading.Lock()
# module-level cache: one loaded voice per (onnx, config) pair, shared across
# sessions/instances so a second session never reloads or duplicates RAM
_VOICE_CACHE: dict[tuple[Path, Path], object] = {}


def _voice_hf_paths(voice_name: str) -> dict[str, str]:
    """Build rhasspy/piper-voices paths from a voice name like
    en_US-lessac-medium -> en/en_US/lessac/medium/en_US-lessac-medium.onnx."""
    parts = voice_name.split("-")
    if len(parts) < 3:
        raise ValueError(f"piper voice name must be <lang>_<XX>-<family>-<quality>, got {voice_name!r}")
    lang, family, quality = parts[0], parts[1], parts[-1]
    base = f"{lang[:2]}/{lang}/{family}/{quality}/{voice_name}"
    return {"onnx": f"{base}.onnx", "config": f"{base}.onnx.json"}


def _ensure_voice_files(
    hf_paths: dict[str, str], cache_dir: Path
) -> tuple[Path, Path]:
    """Download (once) the onnx + config for a voice. Offline-first: if the files
    already exist locally they are used without any network access."""
    from huggingface_hub import hf_hub_download

    onnx_path = cache_dir / Path(hf_paths["onnx"])
    config_path = cache_dir / Path(hf_paths["config"])

    if not (onnx_path.exists() and config_path.exists()):
        logger.info("downloading piper voice %s", hf_paths["onnx"])
        for hf_file in hf_paths.values():
            hf_hub_download(
                repo_id=HF_REPO,
                filename=hf_file,
                local_dir=str(cache_dir),
            )
    return onnx_path, config_path


def _load_piper_voice(model_path: Path, config_path: Path):
    from piper import PiperVoice

    return PiperVoice.load(model_path, config_path)


class PiperTTS(tts.TTS):
    def __init__(
        self,
        *,
        voices: dict[str, str] | None = None,
        default_language: str = "en",
        cache_dir: str | Path | None = None,
    ) -> None:
        """Create the local Piper TTS.

        Args:
            voices: Mapping of language tag -> piper voice name, e.g.
                {"en": "en_US-lessac-medium", "hi": "hi_IN-rohan-medium"}.
                Use "<...>-low" voices (e.g. en_US-lessac-low) for faster
                synthesis and lower RAM on weak machines.
            default_language: Voice used for text without Devanagari script.
            cache_dir: Where voice files are stored (default: ./models/piper).
        """
        if voices is None:
            voices = {
                "en": "en_US-lessac-medium",
                "hi": "hi_IN-rohan-medium",
            }
        if default_language not in voices:
            raise ValueError(f"default_language {default_language!r} not in voices")
        self._voices: dict[str, dict[str, str]] = {
            lang: _voice_hf_paths(name) for lang, name in voices.items()
        }
        self._default_language = default_language
        self._cache_dir = Path(cache_dir or Path(__file__).resolve().parent.parent / "models" / "piper")

        sample_rate = self._read_sample_rate(self._default_language)
        super().__init__(
            capabilities=tts.TTSCapabilities(streaming=False),
            sample_rate=sample_rate,
            num_channels=1,
        )

        self._loaded: dict[str, object] = {}

    @property
    def model(self) -> str:
        return "piper"

    @property
    def provider(self) -> str:
        return "piper-tts"

    def update_options(
        self,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
    ) -> None:
        if is_given(language) and str(language) in self._voices:
            self._default_language = str(language)

    def prewarm(self) -> None:
        """Load all voices eagerly (blocking; call once per process)."""
        for lang in self._voices:
            self._get_voice(lang)

    def _read_sample_rate(self, language: str) -> int:
        """Read the voice sample rate from its config JSON (no model load needed)."""
        hf_paths = self._voices[language]
        cache_path = self._cache_dir / Path(hf_paths["config"])
        if cache_path.exists():
            try:
                with open(cache_path, encoding="utf-8") as f:
                    return int(json.load(f)["audio"]["sample_rate"])
            except Exception:  # noqa: BLE001
                pass
        # fall back to piper's most common sample rate; corrected at load time
        return 22050

    def _get_voice(self, language: str):
        with _VOICE_LOCK:
            key = tuple(self._voices[language].values())
            cache_key = (self._cache_dir / key[0], self._cache_dir / key[1])
            if cache_key not in _VOICE_CACHE:
                onnx_path, config_path = _ensure_voice_files(
                    self._voices[language], self._cache_dir
                )
                logger.info("loading piper voice %s", language)
                voice = _load_piper_voice(onnx_path, config_path)
                _VOICE_CACHE[cache_key] = voice
                if language == self._default_language:
                    # keep base sample rate in sync with the actual voice
                    object.__setattr__(self, "_sample_rate", voice.config.sample_rate)
            return _VOICE_CACHE[cache_key]

    def _language_for_text(self, text: str) -> str:
        if _DEVANAGARI_RE.search(text):
            for lang in self._voices:
                if lang != self._default_language:
                    return lang
        return self._default_language

    def synthesize(
        self,
        text: str,
        *,
        conn_options: utils.APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> tts.ChunkedStream:
        return PiperChunkedStream(tts=self, input_text=text, conn_options=conn_options)


class PiperChunkedStream(tts.ChunkedStream):
    async def _run(self, output_emitter: tts.AudioEmitter) -> None:
        text = self._input_text
        request_id = utils.shortuuid()
        segment_id = utils.shortuuid()

        output_emitter.initialize(
            request_id=request_id,
            sample_rate=self._tts.sample_rate,
            num_channels=1,
            mime_type="audio/pcm",
            stream=False,
        )

        if not text.strip():
            return

        piper_tts = self._tts  # type: ignore[assignment]
        language = piper_tts._language_for_text(text)
        voice = await asyncio.to_thread(piper_tts._get_voice, language)

        def _synthesize() -> list[bytes]:
            chunks = []
            for chunk in voice.synthesize(text):
                chunks.append(chunk.audio_int16_array.tobytes())
            return chunks

        try:
            pcm_chunks = await asyncio.to_thread(_synthesize)
        except Exception as exc:  # noqa: BLE001
            logger.exception("piper synthesis failed: %s", exc)
            raise

        output_emitter.push_timed_transcript(text)
        for pcm in pcm_chunks:
            output_emitter.push(pcm)
        output_emitter.flush()
