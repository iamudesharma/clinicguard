"""FastAPI control plane: LiveKit tokens, patients, transcripts, summaries.

Run:  uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from livekit.api import AccessToken, VideoGrants
from pydantic import BaseModel, Field

from config import get_settings
from store import get_store
from triage.summarizer import generate_summary

app = FastAPI(title="Voice Clinical Dispatcher API", version="0.1.0")

_settings = get_settings()
_origins = [o.strip() for o in _settings.cors_origins.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,  # ["*"] works for demos; restrict before production
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


class TokenRequest(BaseModel):
    user_id: str = "patient"
    room: str = ""
    ttl: int = Field(default=600, ge=60, le=86400)


class TokenResponse(BaseModel):
    token: str
    room: str
    url: str


class PatientCreate(BaseModel):
    id: str = ""
    name: str
    age: str = ""
    sex: str = ""
    known_conditions: str = ""
    allergies: str = ""


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/token", response_model=TokenResponse)
async def create_token(req: TokenRequest) -> TokenResponse:
    s = get_settings()
    if not (s.livekit_api_key and s.livekit_api_secret and s.livekit_url):
        raise HTTPException(503, "LiveKit not configured (set LIVEKIT_URL/API_KEY/API_SECRET)")
    room = req.room or f"{s.room_prefix}-{uuid.uuid4().hex[:8]}"
    token = (
        AccessToken(s.livekit_api_key, s.livekit_api_secret)
        .with_identity(req.user_id)
        .with_ttl(timedelta(seconds=req.ttl))
        .with_grants(VideoGrants(room_join=True, room=room, can_publish=True))
        .to_jwt()
    )
    return TokenResponse(token=token, room=room, url=s.livekit_url)


@app.post("/patients")
async def create_patient(data: PatientCreate) -> dict:
    payload = data.model_dump()
    if not payload["id"]:
        payload["id"] = f"PAT-{uuid.uuid4().hex[:6].upper()}"
    return await get_store().create_patient(payload)


@app.get("/patients")
async def list_patients() -> list[dict]:
    return await get_store().list_patients()


@app.get("/patients/{patient_id}")
async def get_patient(patient_id: str) -> dict:
    patient = await get_store().get_patient(patient_id)
    if patient is None:
        raise HTTPException(404, "patient not found")
    return patient


@app.get("/sessions/{room_id}/transcripts")
async def get_transcripts(room_id: str) -> list[dict]:
    return await get_store().get_transcripts(room_id)


@app.get("/sessions/{room_id}/summary")
async def get_summary(room_id: str) -> dict:
    """Generate an on-demand EHR summary from stored transcripts (POST-call recovery path)."""
    transcript = await get_store().get_transcripts(room_id)
    lines = [{"role": t["role"], "text": t["text"]} for t in transcript]
    if not lines:
        raise HTTPException(404, "no transcripts for this room")
    try:
        summary = generate_summary(lines)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"summary failed: {exc}") from exc
    return summary.model_dump()
