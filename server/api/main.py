"""FastAPI control plane: LiveKit tokens, patients, transcripts, summaries.

Run:  uv run uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from livekit.api import AccessToken, VideoGrants
from pydantic import BaseModel, Field

from config import get_settings
from store import get_store
from triage.summarizer import generate_summary

app = FastAPI(title="Voice Clinical Dispatcher API", version="0.1.0")

# On-demand summary cache: generation takes ~60s on free-tier LLMs; cache per
# room for 10 minutes so the history detail page loads instantly on revisits.
_summary_cache: dict[str, tuple[float, dict]] = {}
_SUMMARY_TTL_SECONDS = 600

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
    owner_id: str = ""  # Supabase auth user id; empty for guest/demo calls


class BookingCreate(BaseModel):
    patient_id: str = ""
    room_id: str = ""
    name: str = ""
    slot: str
    reason: str = ""


class RagSearchRequest(BaseModel):
    query: str
    k: int = Field(default=3, ge=1, le=10)
    category: str = ""


class RagChunk(BaseModel):
    title: str
    category: str = "general"
    content: str
    source: str = ""


class RagIngestRequest(BaseModel):
    chunks: list[RagChunk]


def demo_slots() -> list[dict]:
    """Next 2 calendar days at 09:00, 11:00, 15:00 local time."""
    slots: list[dict] = []
    for offset in (1, 2):
        day = date.today() + timedelta(days=offset)
        weekday = day.strftime("%a")
        prefix = "Tomorrow" if offset == 1 else weekday
        for hour in (9, 11, 15):
            dt = datetime(day.year, day.month, day.day, hour, 0, 0)
            slots.append(
                {
                    "datetime": dt.strftime("%Y-%m-%dT%H:%M:00"),
                    "label": f"{prefix} {hour:02d}:00",
                }
            )
    return slots


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/slots")
async def get_slots() -> dict:
    return {"slots": demo_slots()}


@app.post("/bookings", status_code=201)
async def create_booking(data: BookingCreate) -> dict:
    return await get_store().create_booking(data.model_dump())


@app.get("/bookings")
async def list_bookings(room_id: str = "") -> list[dict]:
    return await get_store().list_bookings(room_id)


# ---- RAG knowledge base (pgvector) ----

@app.get("/rag/status")
async def rag_status() -> dict:
    """Chunk count + search mode + embeddings provider info."""
    from rag import embeddings

    return {
        "chunks": await get_store().count_knowledge(),
        "search_mode": _settings.rag_search_mode,
        "embedding_model": embeddings.model_name() if embeddings.is_configured() else "",
        "embedding_configured": embeddings.is_configured(),
    }


@app.post("/rag/search")
async def rag_search(req: RagSearchRequest) -> dict:
    """Semantic search over the knowledge base -> top-k chunks for grounding."""
    if not req.query.strip():
        return {"results": []}
    results = await get_store().search_knowledge(req.query, k=req.k, category=req.category)
    return {"results": results}


@app.post("/rag/ingest")
async def rag_ingest(req: RagIngestRequest) -> dict:
    """Embed + store knowledge chunks (used by scripts/rag_build.py)."""
    from rag import embeddings

    if not embeddings.is_configured():
        raise HTTPException(
            503, "no embeddings provider configured (see EMBEDDING_* / OPENAI_API_KEY)"
        )
    chunks = [c.model_dump() for c in req.chunks]
    try:
        vectors = embeddings.embed_texts([c["content"] for c in chunks])
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"embedding failed: {exc}") from exc
    for chunk, vec in zip(chunks, vectors):
        chunk["embedding"] = vec
    inserted = await get_store().upsert_knowledge(chunks)
    return {"inserted": inserted, "total": await get_store().count_knowledge()}


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


@app.get("/sessions")
async def list_sessions(patient_id: str = "", owner_id: str = "") -> list[dict]:
    """List sessions for the history screen, newest first."""
    return await get_store().list_sessions(patient_id=patient_id, owner_id=owner_id)


@app.get("/sessions/{room_id}/transcripts")
async def get_transcripts(room_id: str) -> list[dict]:
    return await get_store().get_transcripts(room_id)


class TranscriptAppend(BaseModel):
    role: str  # user | assistant
    text: str
    language: str = ""


@app.post("/sessions/{room_id}/transcripts")
async def append_transcript(room_id: str, data: TranscriptAppend) -> dict:
    """Transcript persistence for the voice_forge (LiveKit-free) agent path."""
    if data.role not in ("user", "assistant"):
        raise HTTPException(422, "role must be user or assistant")
    await get_store().append_transcript(
        room_id, data.role, data.text, language=data.language
    )
    return {"status": "ok"}


class SessionUpdate(BaseModel):
    patient_id: str = ""
    status: str = ""


@app.put("/sessions/{room_id}")
async def update_session(room_id: str, data: SessionUpdate) -> dict:
    """Link a session to a patient and/or mark it ended (voice_forge agent bridge)."""
    await get_store().update_session(room_id, **{k: v for k, v in data.model_dump().items() if v})
    return {"status": "ok"}


@app.get("/sessions/{room_id}/summary")
async def get_summary(room_id: str) -> dict:
    """Generate an on-demand EHR summary from stored transcripts (POST-call recovery path)."""
    import time as _time

    cached = _summary_cache.get(room_id)
    if cached is not None and _time.time() - cached[0] < _SUMMARY_TTL_SECONDS:
        return cached[1]
    transcript = await get_store().get_transcripts(room_id)
    lines = [{"role": t["role"], "text": t["text"]} for t in transcript]
    if not lines:
        raise HTTPException(404, "no transcripts for this room")
    try:
        summary = generate_summary(lines)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"summary failed: {exc}") from exc
    payload = summary.model_dump()
    _summary_cache[room_id] = (_time.time(), payload)
    return payload
