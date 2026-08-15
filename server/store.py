"""Storage layer: Supabase when configured, in-memory demo store otherwise."""

from __future__ import annotations

import asyncio
import time
from typing import Any

from config import get_settings

_SLOT: "Store | None" = None


class Store:
    def __init__(self, use_supabase: bool) -> None:
        self._use_supabase = use_supabase
        self._supabase = None
        self._memory: dict[str, list[dict[str, Any]]] = {}
        if use_supabase:
            from supabase import create_client

            s = get_settings()
            self._supabase = create_client(s.supabase_url, s.supabase_service_key)

    def _table(self, table: str) -> Any:
        if self._supabase is not None:
            return self._supabase.table(table)
        return None

    def _mem_append(self, table: str, row: dict[str, Any]) -> None:
        self._memory.setdefault(table, []).append(row)

    @staticmethod
    def _for_supabase(row: dict[str, Any]) -> dict[str, Any]:
        """Drop client-side epoch timestamps; the DB columns use timestamptz defaults."""
        return {k: v for k, v in row.items() if k != "created_at"}

    async def create_patient(self, data: dict[str, Any]) -> dict[str, Any]:
        row = {**data, "created_at": time.time()}
        t = self._table("patients")
        if t is not None:
            res = await asyncio.to_thread(t.insert, self._for_supabase(row))
            return res.execute().data[0]
        self._mem_append("patients", row)
        return row

    async def get_patient(self, patient_id: str) -> dict[str, Any] | None:
        t = self._table("patients")
        if t is not None:
            res = await asyncio.to_thread(t.select("*").eq, "id", patient_id)
            rows = res.execute().data
            return rows[0] if rows else None
        for row in self._memory.get("patients", []):
            if row.get("id") == patient_id:
                return row
        return None

    async def save_triage(self, patient_id: str, data: dict[str, Any]) -> None:
        row = {
            "patient_id": patient_id,
            "urgency_level": data.get("urgency_level", "low"),
            "reason": data.get("reason"),
            "chief_complaint": data.get("chief_complaint"),
            "symptoms": data.get("symptoms", []),
            "vitals": data.get("vitals", {}),
            "created_at": time.time(),
        }
        t = self._table("triage_results")
        if t is not None:
            await asyncio.to_thread(lambda: t.insert(self._for_supabase(row)).execute())
            return
        self._mem_append("triage_results", row)

    async def save_summary(self, patient_id: str, summary: dict[str, Any]) -> None:
        row = {"patient_id": patient_id, "summary": summary, "created_at": time.time()}
        t = self._table("ehr_summaries")
        if t is not None:
            await asyncio.to_thread(lambda: t.insert(self._for_supabase(row)).execute())
            return
        self._mem_append("ehr_summaries", row)

    async def get_transcripts(self, room_id: str) -> list[dict[str, Any]]:
        t = self._table("transcripts")
        if t is not None:
            res = await asyncio.to_thread(
                t.select("*").eq, "room_id", room_id
            )
            return sorted(res.execute().data, key=lambda r: r.get("created_at", 0))
        return list(self._memory.get(f"transcripts:{room_id}", []))

    async def append_transcript(
        self,
        room_id: str,
        role: str,
        text: str,
        language: str = "",
        is_final: bool = True,
    ) -> None:
        if not text.strip():
            return
        row = {
            "room_id": room_id,
            "role": role,
            "text": text,
            "language": language,
            "is_final": is_final,
            "created_at": time.time(),
        }
        t = self._table("transcripts")
        if t is not None:
            # ensure the FK target exists (sessions.room_id)
            sessions = self._table("sessions")
            await asyncio.to_thread(
                lambda: sessions.upsert(
                    {"room_id": room_id, "status": "active"}, on_conflict="room_id"
                ).execute()
            )
            await asyncio.to_thread(lambda: t.insert(row).execute())
            return
        self._mem_append(f"transcripts:{room_id}", row)

    async def list_patients(self) -> list[dict[str, Any]]:
        t = self._table("patients")
        if t is not None:
            res = await asyncio.to_thread(t.select, "*")
            return res.execute().data
        return list(self._memory.get("patients", []))


def get_store() -> Store:
    global _SLOT
    if _SLOT is None:
        s = get_settings()
        use_sb = bool(s.supabase_url and s.supabase_service_key)
        _SLOT = Store(use_supabase=use_sb)
    return _SLOT
