"""EHR summary generation via Structured Outputs (JSON schema) + Pydantic.

Uses the LLM provider configured by ``LLM_BACKEND`` (groq | openrouter | opencode | gemini), all
OpenAI-compatible, so a single client path covers them.
"""

from __future__ import annotations

import json
from typing import Literal
from uuid import uuid4

from openai import OpenAI
from pydantic import BaseModel, Field

from config import get_settings


class TriageSummary(BaseModel):
    patient_name: str = Field(description="Patient name if known, else 'Unknown'")
    patient_age: str = ""
    language: str = Field(description="Language the conversation happened in (en/hi)")
    chief_complaint: str = ""
    symptoms: list[str] = []
    vitals: dict[str, str] = {}
    urgency_level: Literal["low", "medium", "high", "emergency"] = "low"
    urgency_reason: str = ""
    flagged_conditions: list[str] = Field(
        default_factory=list, description="Red-flag conditions to escalate to a clinician"
    )
    recommended_actions: list[str] = Field(
        default_factory=list, description="Clear next steps given to the patient"
    )
    referral: Literal["self_care", "clinic", "urgent_care", "emergency"] = "clinic"
    notes: str = Field(default="", description="Free-text SOAP-style note for the clinician")


# OpenCode Zen routes/validates requests by these client headers; without them
# it answers FreeUsageLimitError even with a valid key (same as the Dart agent).
def _opencode_headers() -> dict[str, str]:
    return {
        "x-opencode-client": "cli",
        "x-opencode-session": uuid4().hex,
        "x-opencode-project": uuid4().hex,
        "x-opencode-request": uuid4().hex,
        "User-Agent": "opencode/latest/cli",
    }


def _client() -> OpenAI:
    s = get_settings()
    if s.llm_backend == "openrouter":
        return OpenAI(base_url="https://openrouter.ai/api/v1", api_key=s.openrouter_api_key)
    if s.llm_backend == "opencode":
        return OpenAI(
            base_url=s.opencode_base_url,
            api_key=s.opencode_api_key,
            default_headers=_opencode_headers(),
        )
    if s.llm_backend == "gemini":
        return OpenAI(base_url=s.gemini_base_url, api_key=s.gemini_api_key)
    return OpenAI(base_url="https://api.groq.com/openai/v1", api_key=s.groq_api_key)


def _default_model() -> str:
    s = get_settings()
    if s.llm_backend == "openrouter":
        return s.openrouter_model
    if s.llm_backend == "opencode":
        return s.opencode_model
    if s.llm_backend == "gemini":
        return s.gemini_model
    return s.llm_model


def generate_summary(
    transcript: list[dict],
    *,
    urgency_hint: str = "",
    model: str = "",
) -> TriageSummary:
    s = get_settings()
    if not model:
        model = _default_model()

    dialogue = "\n".join(
        f"{'Patient' if t.get('role') == 'user' else 'Assistant'}: {t.get('text', '')}"
        for t in transcript
        if t.get("text")
    )
    if not dialogue:
        raise ValueError("no transcript to summarize")

    schema = TriageSummary.model_json_schema()
    try:
        resp = _client().chat.completions.create(
            model=model,
            temperature=0.2,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You generate structured clinical triage summaries from voice triage "
                        "conversations. The conversation may mix English and Hindi (Devanagari or "
                        "romanized). Extract facts only; do not invent vitals. If the transcript does "
                        "not contain a value, leave the field empty. Notes must be brief and factual."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"Assistant-recorded urgency hint: {urgency_hint or 'not set'}\n\n"
                        f"Transcript:\n{dialogue}"
                    ),
                },
            ],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "triage_summary",
                    "schema": schema,
                    "strict": True,
                },
            },
        )
        content = resp.choices[0].message.content
    except Exception:  # noqa: BLE001 - some providers (e.g. DeepSeek via Zen) lack strict json_schema
        resp = _client().chat.completions.create(
            model=model,
            temperature=0.2,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "Output ONLY a JSON object matching this schema (no markdown): "
                        f"{json.dumps(schema)}\n"
                        "Extract facts from the conversation; empty strings for unknown values."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"Assistant-recorded urgency hint: {urgency_hint or 'not set'}\n\n"
                        f"Transcript:\n{dialogue}"
                    ),
                },
            ],
        )
        content = resp.choices[0].message.content or ""
        content = content.strip()
        if content.startswith("```"):
            content = content.strip("`")
            if content.startswith("json"):
                content = content[4:]
    return TriageSummary.model_validate_json(content)
