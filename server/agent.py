"""Voice AI Clinical Dispatcher - LiveKit Agents entrypoint.

Run:
    uv run python agent.py console     # test in terminal
    uv run python agent.py dev         # connect to LiveKit + hot reload
    uv run python agent.py start       # production-ish run
"""

from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass

from livekit.agents import (
    Agent,
    AgentServer,
    AgentSession,
    JobContext,
    JobExecutorType,
    cli,
    inference,
    stt as agents_stt,
)
from livekit.agents import APIConnectOptions
from livekit.agents.voice.agent_session import SessionConnectOptions
from livekit.agents.voice.events import (
    AgentStateChangedEvent,
    CloseEvent,
    ConversationItemAddedEvent,
    UserInputTranscribedEvent,
)
from livekit.plugins import cartesia, deepgram, groq, silero

from config import get_settings
from plugins.whisper_stt import WhisperSTT
from store import get_store
from triage.extractor import extract_summary
from triage.prompts import SYSTEM_PROMPT
from triage.summarizer import TriageSummary, generate_summary
from triage.tools import (
    TriageData,
    add_symptom,
    assign_urgency,
    lookup_patient,
    record_vitals,
    register_patient,
)

logger = logging.getLogger("triage-dispatch")
settings = get_settings()

DATA_TOPIC = "agent.events"


@dataclass
class EventRelay:
    """Pushes session events (transcripts, state, summary) to the app over the data channel."""

    room: object

    async def _publish(self, payload: dict) -> None:
        try:
            lp = getattr(self.room, "local_participant", None)
            if lp is not None:
                await lp.publish_data(
                    json.dumps(payload).encode("utf-8"), topic=DATA_TOPIC
                )
        except Exception as exc:  # noqa: BLE001 - telemetry must never break the call
            logger.debug("data publish failed: %s", exc)


def build_llm():
    """Groq or OpenRouter, with optional 429 auto-failover to the other provider."""
    from livekit.plugins import openai as openai_plugin

    def _groq():
        return groq.LLM(
            model=settings.llm_model,
            api_key=settings.groq_api_key,
            temperature=settings.llm_temperature,
        )

    def _openrouter():
        return openai_plugin.LLM(
            model=settings.openrouter_model,
            api_key=settings.openrouter_api_key,
            base_url="https://openrouter.ai/api/v1",
            temperature=settings.llm_temperature,
        )

    def _opencode():
        return openai_plugin.LLM(
            model=settings.opencode_model,
            api_key=settings.opencode_api_key,
            base_url=settings.opencode_base_url,
            temperature=settings.llm_temperature,
        )

    backends = {
        "groq": (_groq, settings.groq_api_key),
        "openrouter": (_openrouter, settings.openrouter_api_key),
        "opencode": (_opencode, settings.opencode_api_key),
    }

    primary_factory, primary_key = backends.get(settings.llm_backend, backends["groq"])
    fallback_entry = backends.get(settings.llm_fallback_backend)

    primary = primary_factory()
    if settings.llm_fallback_backend and fallback_entry is not None:
        fallback = fallback_entry[0]() if fallback_entry[1] else None
    else:
        fallback = None

    if settings.llm_fallback_backend and fallback is None:
        logger.warning(
            "LLM fallback (%s) requested but its API key is missing - running without failover",
            settings.llm_fallback_backend,
        )

    if fallback is not None:
        from plugins.fallback_llm import FallbackLLM

        return FallbackLLM(
            primary=primary,
            fallback=fallback,
            cooldown_seconds=settings.llm_cooldown_seconds,
        )
    return primary


def build_tts():
    """piper = fast local TTS (~150ms/sentence, more robotic); kokoro = best local
    quality (~1.5-2.5s/sentence on CPU); cartesia/fish = cloud fallbacks."""
    if settings.tts_backend == "piper":
        from plugins.piper_tts import PiperTTS

        return PiperTTS(
            voices={
                "en": settings.piper_en_voice,
                "hi": settings.piper_hi_voice,
            }
        )
    if settings.tts_backend == "kokoro":
        from plugins.kokoro_tts import KokoroTTS

        return KokoroTTS(
            voices={
                "en": settings.kokoro_en_voice,
                "hi": settings.kokoro_hi_voice,
            }
        )
    if settings.tts_backend == "fish":
        return inference.TTS(
            "fishaudio/s2.1-pro-free",
            voice=settings.fish_voice_id,
        )
    return cartesia.TTS(
        model=settings.cartesia_model,
        api_key=settings.cartesia_api_key,
        voice=settings.cartesia_voice_id,
    )


def build_stt():
    """whisper = local faster-whisper (StreamAdapter provides VAD segmentation),
    deepgram = cloud streaming fallback."""
    if settings.stt_backend == "whisper":
        return agents_stt.StreamAdapter(
            stt=WhisperSTT(
                model=settings.whisper_model,
                language=settings.whisper_language or None,
                compute_type=settings.whisper_compute_type,
                beam_size=settings.whisper_beam_size,
            ),
            # shorter silence threshold -> faster final transcripts for turn detection
            vad=silero.VAD.load(min_silence_duration=0.35),
        )
    return deepgram.STT(
        model=settings.deepgram_model,
        language=settings.deepgram_language,
        detect_language=settings.deepgram_detect_language,
    )


async def _on_user_transcribed(
    ctx: JobContext, relay: EventRelay, userdata: TriageData, event: UserInputTranscribedEvent
) -> None:
    text = event.transcript
    if event.is_final:
        userdata.transcript.append({"role": "user", "text": text})
        userdata.language = event.language or userdata.language
        userdata.turn_count += 1
        await get_store().append_transcript(
            ctx.room.name, "user", text, language=userdata.language
        )
        if userdata.turn_count % 3 == 0:
            # live EHR preview every few turns (fire-and-forget)
            asyncio.create_task(_maybe_extract_live(ctx, relay, userdata))
    await relay._publish(
        {
            "type": "user_transcript",
            "text": text,
            "is_final": event.is_final,
            "language": event.language,
            "item_id": event.item_id,
        }
    )


async def _on_conversation_item_added(
    ctx: JobContext, relay: EventRelay, userdata: TriageData, event: ConversationItemAddedEvent
) -> None:
    item = event.item
    if getattr(item, "type", "") == "message" and getattr(item, "role", "") == "assistant":
        text = getattr(item, "text", "") or ""
        if text:
            userdata.transcript.append({"role": "assistant", "text": text})
            await get_store().append_transcript(
                ctx.room.name, "assistant", text, language=userdata.language
            )
            await relay._publish(
                {"type": "assistant_text", "text": text, "item_id": item.id}
            )


async def _on_state_changed(relay: EventRelay, event: AgentStateChangedEvent) -> None:
    await relay._publish({"type": "agent_state", "state": event.new_state.value})


async def _on_data_received(session: AgentSession, packet) -> None:
    """Handle client-originated data messages (e.g. local barge-in signal)."""
    if getattr(packet, "topic", None) != DATA_TOPIC:
        return
    try:
        payload = json.loads(packet.data.decode("utf-8"))
    except Exception:  # noqa: BLE001
        return
    if payload.get("event") != "barge_in":
        return
    if session.agent_state == "speaking":
        logger.info("barge-in received from client - interrupting")
        try:
            await session.interrupt()
        except Exception as exc:  # noqa: BLE001
            logger.debug("interrupt failed: %s", exc)


async def _push_summary(
    relay: EventRelay, userdata: TriageData, summary: TriageSummary
) -> None:
    store = get_store()
    if userdata.patient_id:
        await store.save_summary(userdata.patient_id, summary.model_dump())
    await relay._publish({"type": "summary", "summary": summary.model_dump()})


async def _maybe_extract_live(
    ctx: JobContext, relay: EventRelay, userdata: TriageData
) -> None:
    """Every few turns, generate a live EHR preview and push it to the app."""
    if not userdata.transcript:
        return
    if userdata.extraction_lock.locked():
        return  # previous extraction still running
    async with userdata.extraction_lock:
        try:
            summary = await extract_summary(
                userdata.transcript,
                urgency_hint=f"{userdata.urgency}: {userdata.urgency_reason}",
            )
        except Exception as exc:  # noqa: BLE001
            logger.debug("live extraction failed: %s", exc)
            return
        await _push_summary(relay, userdata, summary)
        logger.info("live summary pushed (%d turns)", userdata.turn_count)


async def _finalize_session(ctx: JobContext, userdata: TriageData, relay: EventRelay) -> None:
    """Persist triage state and generate the final structured EHR summary."""
    store = get_store()
    if userdata.patient_id and userdata.urgency:
        await store.save_triage(
            userdata.patient_id,
            {
                "urgency_level": userdata.urgency,
                "reason": userdata.urgency_reason,
                "chief_complaint": userdata.chief_complaint,
                "symptoms": userdata.symptoms,
                "vitals": userdata.vitals,
            },
        )
    try:
        summary = await extract_summary(
            userdata.transcript,
            urgency_hint=f"{userdata.urgency}: {userdata.urgency_reason}",
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("pydantic-ai extraction failed (%s); falling back to direct extraction", exc)
        try:
            summary = await asyncio.to_thread(
                generate_summary,
                userdata.transcript,
                urgency_hint=f"{userdata.urgency}: {userdata.urgency_reason}",
            )
        except Exception as exc2:  # noqa: BLE001
            logger.warning("summary generation failed: %s", exc2)
            await relay._publish({"type": "summary_error", "error": str(exc2)})
            return
    await _push_summary(relay, userdata, summary)


def _prewarm(proc: JobProcess) -> None:
    """Load the Whisper model and Piper voices once per process so the first turn
    has no cold-start lag."""
    if settings.stt_backend == "whisper":
        WhisperSTT(model=settings.whisper_model).prewarm()
    if settings.tts_backend == "piper":
        from plugins.piper_tts import PiperTTS

        PiperTTS().prewarm()
    elif settings.tts_backend == "kokoro":
        from plugins.kokoro_tts import KokoroTTS

        KokoroTTS().prewarm()


server = AgentServer(
    # THREAD executor: sessions share one process -> Whisper model is loaded once
    # and reused (transcribe calls are serialized by the plugin's lock).
    job_executor_type=JobExecutorType.THREAD,
    # first job must wait for the Whisper model to load (~5-40s cold start)
    initialize_process_timeout=120.0,
    setup_fnc=_prewarm,
    # values come from server/.env (pydantic-settings), not shell env vars
    ws_url=settings.livekit_url,
    api_key=settings.livekit_api_key,
    api_secret=settings.livekit_api_secret,
)


@server.rtc_session()
async def entrypoint(ctx: JobContext) -> None:
    logger.info("session started in room %s", ctx.room.name)

    userdata = TriageData()
    relay = EventRelay(ctx.room)

    session = AgentSession(
        vad=silero.VAD.load(),
        stt=build_stt(),
        llm=build_llm(),
        # keep the free-tier quota safe: cap the tool-call loop so a bad turn
        # can't burn 20+ requests (see Groq 429 issue)
        max_tool_steps=5,
        # fail a slow LLM call after LLM_TIMEOUT_SECONDS (15s default) instead
        # of hanging the conversation; the fallback provider picks it up
        conn_options=SessionConnectOptions(
            llm_conn_options=APIConnectOptions(timeout=settings.llm_timeout_seconds),
        ),
        tts=build_tts(),
        userdata=userdata,
    )

    session.on(
        UserInputTranscribedEvent,
        lambda ev: asyncio.create_task(
            _on_user_transcribed(ctx, relay, userdata, ev)
        ),
    )
    session.on(
        ConversationItemAddedEvent,
        lambda ev: asyncio.create_task(
            _on_conversation_item_added(ctx, relay, userdata, ev)
        ),
    )
    session.on(
        AgentStateChangedEvent,
        lambda ev: asyncio.create_task(_on_state_changed(relay, ev)),
    )
    session.on(
        CloseEvent,
        lambda ev: asyncio.create_task(_finalize_session(ctx, userdata, relay)),
    )

    # client-side barge-in signal (instant local ducking + authoritative interrupt)
    ctx.room.on(
        "data_received",
        lambda packet: asyncio.create_task(_on_data_received(session, packet)),
    )

    agent = Agent(
        instructions=SYSTEM_PROMPT,
        tools=[
            register_patient,
            lookup_patient,
            record_vitals,
            add_symptom,
            assign_urgency,
        ],
    )

    await session.start(agent=agent, room=ctx.room)
    await session.generate_reply(instructions=settings.greeting)


if __name__ == "__main__":
    cli.run_app(server)
