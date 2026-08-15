"""Custom Kokoro-82M v1.0 (ONNX) TTS plugin for LiveKit Agents.

Apache-2.0, 82M params, runs locally via onnxruntime — same class as
faster-whisper. Better voice quality than Piper; slower on CPU
(~1.5-2.5s per sentence on an 8GB M1 vs Piper's ~150ms), so use Piper when
sub-400ms latency is the priority and Kokoro when voice quality matters.

Voices: en (af_bella etc.) + hi (hf_alpha/hf_beta/hm_omega/hm_psi), auto-switched
by Devanagari script detection.

Model files (auto-downloaded once to server/models/kokoro/):
  kokoro-v1.0.onnx + voices-v1.0.bin  (kokoro-onnx official release)
"""

from __future__ import annotations

import asyncio
import logging
import re
import threading
import urllib.request
from pathlib import Path

import numpy as np
from livekit import rtc
from livekit.agents import tts, utils
from livekit.agents.tts.tts import DEFAULT_API_CONNECT_OPTIONS

logger = logging.getLogger("kokoro-tts")

_DEVANAGARI_RE = re.compile(r"[\u0900-\u097F]")
_SAMPLE_RATE = 24000

# official kokoro-onnx v1.0 release files (fp32, works with the Python package)
_RELEASE_URLS = {
    "kokoro-v1.0.onnx": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
    "voices-v1.0.bin": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
}

_ENGINE_LOCK = threading.Lock()
_ENGINE: object | None = None


def _ensure_files(cache_dir: Path) -> tuple[Path, Path]:
    model_path = cache_dir / "kokoro-v1.0.onnx"
    voices_path = cache_dir / "voices-v1.0.bin"
    if not (model_path.exists() and voices_path.exists()):
        cache_dir.mkdir(parents=True, exist_ok=True)
        for name, url in _RELEASE_URLS.items():
            target = cache_dir / name
            if not target.exists():
                logger.info("downloading kokoro file %s", name)
                urllib.request.urlretrieve(url, target)  # noqa: S310 - fixed release URL
    return model_path, voices_path


def _get_engine(model_path: Path, voices_path: Path):
    global _ENGINE
    with _ENGINE_LOCK:
        if _ENGINE is None:
            from kokoro_onnx import Kokoro

            logger.info("loading kokoro v1.0 engine")
            _ENGINE = Kokoro(str(model_path), str(voices_path))
        return _ENGINE


class KokoroTTS(tts.TTS):
    def __init__(
        self,
        *,
        voices: dict[str, str] | None = None,
        languages: dict[str, str] | None = None,
        default_language: str = "en",
        cache_dir: str | Path | None = None,
    ) -> None:
        """Create the local Kokoro TTS.

        Args:
            voices: language tag -> voice name, e.g. {"en": "af_bella", "hi": "hf_alpha"}.
            languages: language tag -> kokoro lang code, e.g. {"en": "en-us", "hi": "hi"}.
            default_language: voice used for text without Devanagari script.
            cache_dir: where model files live (default: ./models/kokoro).
        """
        if voices is None:
            voices = {"en": "af_bella", "hi": "hf_alpha"}
        if languages is None:
            languages = {"en": "en-us", "hi": "hi"}
        if default_language not in voices:
            raise ValueError(f"default_language {default_language!r} not in voices")
        self._voices = voices
        self._languages = languages
        self._default_language = default_language
        self._cache_dir = Path(cache_dir or Path(__file__).resolve().parent.parent / "models" / "kokoro")

        super().__init__(
            capabilities=tts.TTSCapabilities(streaming=False),
            sample_rate=_SAMPLE_RATE,
            num_channels=1,
        )

    @property
    def model(self) -> str:
        return "kokoro-82m-v1.0"

    @property
    def provider(self) -> str:
        return "kokoro-onnx"

    def prewarm(self) -> None:
        """Load the engine eagerly (blocking; call once per process)."""
        model_path, voices_path = _ensure_files(self._cache_dir)
        _get_engine(model_path, voices_path)

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
        return KokoroChunkedStream(tts=self, input_text=text, conn_options=conn_options)


class KokoroChunkedStream(tts.ChunkedStream):
    async def _run(self, output_emitter: tts.AudioEmitter) -> None:
        text = self._input_text
        request_id = utils.shortuuid()

        output_emitter.initialize(
            request_id=request_id,
            sample_rate=self._tts.sample_rate,
            num_channels=1,
            mime_type="audio/pcm",
            stream=False,
        )
        if not text.strip():
            return

        kokoro = self._tts  # type: ignore[assignment]
        lang = kokoro._language_for_text(text)
        voice = kokoro._voices[lang]
        lang_code = kokoro._languages[lang]

        model_path, voices_path = _ensure_files(kokoro._cache_dir)
        engine = _get_engine(model_path, voices_path)

        def _synthesize() -> bytes:
            audio, sr = engine.create(text, voice=voice, lang=lang_code, speed=1.0)
            if sr != _SAMPLE_RATE or audio.dtype != np.float32:
                raise RuntimeError(f"unexpected kokoro output: rate={sr} dtype={audio.dtype}")
            return (np.clip(audio, -1.0, 1.0) * 32767.0).astype(np.int16).tobytes()

        pcm = await asyncio.to_thread(_synthesize)
        output_emitter.push_timed_transcript(text)
        output_emitter.push(pcm)
        output_emitter.flush()
