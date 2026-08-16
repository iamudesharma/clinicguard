"""Pydantic AI based EHR extraction from triage conversations.

Uses the LLM provider configured by ``LLM_BACKEND`` (groq | openrouter | gemini) via an
OpenAI-compatible client, with a Pydantic output type for strict JSON extraction.
"""

from __future__ import annotations

import logging

from openai import AsyncOpenAI
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from config import get_settings
from triage.summarizer import TriageSummary

logger = logging.getLogger("extractor")

_SYSTEM_PROMPT = (
    "You generate structured clinical triage summaries from voice triage "
    "conversations. The conversation may mix English and Hindi (Devanagari or "
    "romanized). Extract facts only; do not invent vitals. If the transcript does "
    "not contain a value, leave the field empty. Notes must be brief and factual."
)


def _build_model() -> OpenAIChatModel:
    s = get_settings()
    if s.llm_backend == "openrouter":
        return OpenAIChatModel(
            s.openrouter_model,
            provider=OpenAIProvider(
                base_url="https://openrouter.ai/api/v1",
                api_key=s.openrouter_api_key,
            ),
        )
    if s.llm_backend == "gemini":
        return OpenAIChatModel(
            s.gemini_model,
            provider=OpenAIProvider(
                base_url=s.gemini_base_url,
                api_key=s.gemini_api_key,
            ),
        )
    return OpenAIChatModel(
        s.llm_model,
        provider=OpenAIProvider(
            base_url="https://api.groq.com/openai/v1",
            api_key=s.groq_api_key,
        ),
    )


def _dialogue_text(transcript: list[dict]) -> str:
    return "\n".join(
        f"{'Patient' if t.get('role') == 'user' else 'Assistant'}: {t.get('text', '')}"
        for t in transcript
        if t.get("text")
    )


async def extract_summary(
    transcript: list[dict],
    *,
    urgency_hint: str = "",
    model: OpenAIChatModel | None = None,
) -> TriageSummary:
    """Extract a structured TriageSummary from a transcript using pydantic-ai."""
    dialogue = _dialogue_text(transcript)
    if not dialogue:
        raise ValueError("no transcript to summarize")

    agent = Agent(
        model=model or _build_model(),
        output_type=TriageSummary,
        system_prompt=_SYSTEM_PROMPT,
    )
    prompt = f"Assistant-recorded urgency hint: {urgency_hint or 'not set'}\n\nTranscript:\n{dialogue}"
    result = await agent.run(prompt)
    if result.output is None:
        raise ValueError("extractor returned no output")
    return result.output
