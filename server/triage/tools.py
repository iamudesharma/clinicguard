"""Clinical tools exposed to the LLM. Persisted through the store layer."""

from __future__ import annotations

import asyncio
import re
import uuid
from dataclasses import dataclass, field

from livekit.agents import RunContext, function_tool

from store import get_store

# Values the LLM produces instead of real patient data (seen in the wild) - they
# burn rate limit on tool loops. Anything matching is treated as "unknown".
_PLACEHOLDER_RE = re.compile(
    r"\b(patient'?s?|unknown|n/?a|not provided|not given|not sure|when it started|"
    r"patient-reported|chief complaint|blood pressure|heart rate|respiratory rate|"
    r"oxygen saturation|temperature|severity|onset)\b",
    re.IGNORECASE,
)

_URGENCY_LEVELS = {"low", "medium", "high", "emergency"}


def _clean(value: str) -> str:
    """Strip placeholder junk from an LLM-provided value; "" means unknown."""
    v = value.strip()
    if not v or _PLACEHOLDER_RE.search(v):
        return ""
    return v


@dataclass
class TriageData:
    patient_id: str = ""
    patient_name: str = ""
    patient_age: str = ""
    language: str = "en"
    urgency: str = ""
    urgency_reason: str = ""
    chief_complaint: str = ""
    symptoms: list[dict] = field(default_factory=list)
    vitals: dict[str, str] = field(default_factory=dict)
    transcript: list[dict] = field(default_factory=list)
    turn_count: int = 0
    extraction_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # stable per-session reference used to seed the patient record id
    session_ref: str = field(
        default_factory=lambda: f"PAT-{uuid.uuid4().hex[:6].upper()}"
    )


def _state(context: RunContext) -> TriageData:
    return context.userdata


@function_tool
async def lookup_patient(context: RunContext, patient_id: str) -> dict:
    """Look up an existing patient record by ID. Returns demographics, allergies, and conditions,
    or an empty result if the patient does not exist yet.
    Args:
        patient_id: The patient identifier (e.g. PAT-1001).
    """
    _state(context).patient_id = patient_id
    patient = await get_store().get_patient(patient_id)
    if patient is None:
        return {"found": False, "patient_id": patient_id}
    return {"found": True, "patient": patient}


@function_tool
async def register_patient(
    context: RunContext,
    name: str,
    age: str,
    sex: str = "",
    known_conditions: str = "",
    allergies: str = "",
) -> dict:
    """Register a new patient at the start of triage.
    Args:
        name: Patient full name.
        age: Patient age, with unit (e.g. '34 years' or '5 months').
        sex: male / female / other, if provided.
        known_conditions: Existing medical conditions, if any.
        allergies: Known allergies, if any.
    """
    st = _state(context)
    name, age = _clean(name), _clean(age)
    if not name or not age:
        raise ValueError(
            "Patient name and age are required - ask the patient for them before registering."
        )
    st.patient_name, st.patient_age = name, age
    data = {
        "id": st.patient_id or st.session_ref,
        "name": name,
        "age": age,
        "sex": _clean(sex),
        "known_conditions": _clean(known_conditions),
        "allergies": _clean(allergies),
    }
    saved = await get_store().create_patient(data)
    st.patient_id = saved.get("id") or data["id"]
    return {"patient_id": st.patient_id, "registered": True}


@function_tool
async def record_vitals(
    context: RunContext,
    blood_pressure: str = "",
    heart_rate: str = "",
    temperature: str = "",
    spo2: str = "",
    respiratory_rate: str = "",
) -> dict:
    """Record vital signs reported by the patient (strings with units, empty if unknown).
    Args:
        blood_pressure: e.g. '120/80 mmHg'
        heart_rate: e.g. '88 bpm'
        temperature: e.g. '101.3 F'
        spo2: e.g. '96%'
        respiratory_rate: e.g. '18 /min'
    """
    st = _state(context)
    recorded = 0
    for k, v in {
        "blood_pressure": blood_pressure,
        "heart_rate": heart_rate,
        "temperature": temperature,
        "spo2": spo2,
        "respiratory_rate": respiratory_rate,
    }.items():
        v = _clean(v)
        if v:
            st.vitals[k] = v
            recorded += 1
    return {"recorded": recorded, "vitals": st.vitals}


@function_tool
async def add_symptom(
    context: RunContext,
    symptom: str,
    onset: str = "",
    severity: str = "",
) -> dict:
    """Add a symptom to the running triage picture.
    Args:
        symptom: Description of the symptom.
        onset: When it started (e.g. '2 hours ago', 'since morning').
        severity: Patient-reported severity 1-10 if given.
    """
    st = _state(context)
    symptom = _clean(symptom)
    if not symptom:
        raise ValueError("Please ask the patient to describe their symptom first.")
    st.symptoms.append(
        {"symptom": symptom, "onset": _clean(onset), "severity": _clean(severity)}
    )
    if not st.chief_complaint:
        st.chief_complaint = symptom
    return {"symptom_count": len(st.symptoms)}


@function_tool
async def assign_urgency(
    context: RunContext,
    urgency_level: str,
    reason: str,
) -> dict:
    """Assign the triage urgency level once enough information is gathered.
    Args:
        urgency_level: one of low, medium, high, emergency.
        reason: Short justification in the patient's language.
    """
    st = _state(context)
    urgency_level = urgency_level.strip().lower()
    if urgency_level not in _URGENCY_LEVELS:
        raise ValueError(
            f"urgency_level must be one of {sorted(_URGENCY_LEVELS)}"
        )
    st.urgency = urgency_level
    st.urgency_reason = _clean(reason) or "no reason given"
    if st.patient_id:
        await get_store().save_triage(
            st.patient_id,
            {
                "urgency_level": urgency_level,
                "reason": st.urgency_reason,
                "chief_complaint": st.chief_complaint,
                "symptoms": st.symptoms,
                "vitals": st.vitals,
            },
        )
    return {"urgency_level": urgency_level, "saved": bool(st.patient_id)}


@function_tool
async def save_transcript(context: RunContext, text: str, role: str = "user") -> dict:
    """Internal: persist a spoken turn. Called by the session automatically - not for patient use."""
    st = _state(context)
    st.transcript.append({"role": role, "text": text})
    return {"ok": True}
