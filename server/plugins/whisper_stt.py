"""Custom faster-whisper STT plugin for LiveKit Agents.

Batch-only STT: pair with ``livekit.agents.stt.StreamAdapter`` (which provides the
VAD-driven streaming segmentation) to get realtime behavior. Transcription runs
locally via CTranslate2 (faster-whisper) on the host machine — no API cost.

Usage:
    from livekit.agents import stt
    from livekit.plugins import silero
    from plugins.whisper_stt import WhisperSTT

    whisper = stt.StreamAdapter(
        stt=WhisperSTT(model="base"),          # multilingual: en + hi
        vad=silero.VAD.load(),
    )
"""

from __future__ import annotations

import asyncio
import logging
import re
import threading

import numpy as np
from livekit import rtc
from livekit.agents import stt, utils
from livekit.agents import LanguageCode, APIConnectOptions
from livekit.agents.types import NOT_GIVEN, NotGivenOr
from livekit.agents.utils import is_given

logger = logging.getLogger("whisper-stt")

_VALID_LANG_RE = re.compile(r"^[a-zA-Z]{2,3}(?:-[A-Za-z0-9]+)*$")


def _sanitize_language(lang: str | None) -> str | None:
    """Defend against misparsed env values (inline comments, whitespace)."""
    if not lang:
        return None
    lang = lang.strip()
    if lang.startswith("#") or not _VALID_LANG_RE.fullmatch(lang):
        return None
    return lang

_MODEL_CACHE: dict[tuple[str, str, str], object] = {}
_MODEL_CACHE_LOCK = threading.Lock()


def _load_model(model_name: str, device: str, compute_type: str):
    """Load (and cache) the faster-whisper model. First load downloads weights."""
    key = (model_name, device, compute_type)
    with _MODEL_CACHE_LOCK:
        if key not in _MODEL_CACHE:
            from faster_whisper import WhisperModel

            logger.info("loading faster-whisper model %s (%s)", model_name, compute_type)
            try:
                # offline-first: avoids hanging on flaky networks during a demo
                _MODEL_CACHE[key] = WhisperModel(
                    model_name,
                    device=device,
                    compute_type=compute_type,
                    local_files_only=True,
                )
            except Exception:
                logger.warning(
                    "model %s not in local cache, downloading from HuggingFace "
                    "(run once with network access)",
                    model_name,
                )
                _MODEL_CACHE[key] = WhisperModel(
                    model_name, device=device, compute_type=compute_type
                )
        return _MODEL_CACHE[key]


def _frames_to_mono_16k_f32(frames: list[rtc.AudioFrame]) -> np.ndarray:
    """Concatenate frames, mix to mono, resample to 16 kHz, return float32 in [-1, 1]."""
    arrays: list[np.ndarray] = []
    src_rate = 16000
    for frame in frames:
        src_rate = frame.sample_rate
        data = np.frombuffer(frame.data, dtype=np.int16).astype(np.float32) / 32768.0
        if frame.num_channels > 1:
            data = data.reshape(-1, frame.num_channels).mean(axis=1)
        arrays.append(data)
    if not arrays:
        return np.array([], dtype=np.float32)
    audio = np.concatenate(arrays)

    if src_rate != 16000 and len(audio) > 0:
        n_out = int(round(len(audio) * 16000 / src_rate))
        if n_out < 1:
            return np.array([], dtype=np.float32)
        idx = np.linspace(0.0, len(audio) - 1, n_out)
        audio = np.interp(idx, np.arange(len(audio)), audio).astype(np.float32)
    return audio


class WhisperSTT(stt.STT):
    def __init__(
        self,
        *,
        model: str = "base",
        language: str | None = None,
        device: str = "cpu",
        compute_type: str = "int8",
        beam_size: int = 1,
    ) -> None:
        """Create the local Whisper STT.

        Args:
            model: faster-whisper model name, e.g. "tiny", "base", "small". Use a
                multilingual checkpoint (no ".en" suffix) to support English + Hindi.
            language: Restrict recognition to a language ("en", "hi", ...). None = auto-detect
                per segment.
            device: "cpu" (or "cuda" if available).
            compute_type: "int8" is the fast default on Apple Silicon.
            beam_size: 1 (greedy) is fastest for realtime.
        """
        super().__init__(
            capabilities=stt.STTCapabilities(
                streaming=False,  # streaming is provided by StreamAdapter
                interim_results=False,
                offline_recognize=True,
            )
        )
        self._model_name = model
        self._language = LanguageCode(_sanitize_language(language)) if language else None
        self._device = device
        self._compute_type = compute_type
        self._beam_size = beam_size
        self._model = None
        # faster-whisper is not guaranteed thread-safe across concurrent transcribe calls;
        # serialize them (several sessions may share one plugin instance)
        self._transcribe_lock = threading.Lock()

    @property
    def model(self) -> str:
        return self._model_name

    @property
    def provider(self) -> str:
        return "faster-whisper"

    def update_options(
        self,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        model: NotGivenOr[str] = NOT_GIVEN,
    ) -> None:
        if is_given(language):
            self._language = LanguageCode(_sanitize_language(str(language))) if language else None
        if is_given(model):
            self._model_name = model
            self._model = None  # reload with the new model name

    def prewarm(self) -> None:
        self._model = _load_model(self._model_name, self._device, self._compute_type)

    def _ensure_model(self):
        if self._model is None:
            self._model = _load_model(self._model_name, self._device, self._compute_type)
        return self._model

    def _transcribe_blocking(
        self, audio: np.ndarray, language: str | None
    ) -> tuple[str, str, float]:
        model = self._ensure_model()
        segments, info = model.transcribe(
            audio,
            language=language,
            beam_size=self._beam_size,
            temperature=0.0,
            vad_filter=False,  # segmentation is handled by the StreamAdapter's VAD
            condition_on_previous_text=False,
            without_timestamps=True,
        )
        text = " ".join(s.text for s in segments).strip()
        return text, info.language, float(info.language_probability)

    async def _recognize_impl(
        self,
        buffer: utils.AudioBuffer,
        *,
        language: NotGivenOr[str] = NOT_GIVEN,
        conn_options: APIConnectOptions,
    ) -> stt.SpeechEvent:
        if isinstance(buffer, rtc.AudioFrame):
            frames = [buffer]
        else:
            frames = list(buffer)
        audio = _frames_to_mono_16k_f32(frames)
        # ignore very short buffers (VAD trigger noise)
        if len(audio) < 0.3 * 16000:
            return stt.SpeechEvent(type=stt.SpeechEventType.FINAL_TRANSCRIPT)

        lang: str | None = None
        if is_given(language):
            lang = _sanitize_language(str(LanguageCode(language)))
        elif self._language is not None:
            lang = _sanitize_language(str(self._language))

        with self._transcribe_lock:
            text, detected_lang, confidence = await asyncio.to_thread(
                self._transcribe_blocking, audio, lang
            )

        if not text:
            return stt.SpeechEvent(type=stt.SpeechEventType.FINAL_TRANSCRIPT)

        data = stt.SpeechData(
            language=LanguageCode(detected_lang or lang or "en"),
            text=text,
            confidence=confidence,
        )
        return stt.SpeechEvent(
            type=stt.SpeechEventType.FINAL_TRANSCRIPT, alternatives=[data]
        )
