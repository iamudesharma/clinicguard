"""Storage layer: Supabase when configured, in-memory demo store otherwise."""

from __future__ import annotations

import asyncio
import math
import re
import time
import uuid
from collections import Counter
from datetime import datetime
from typing import Any

from config import get_settings

_SLOT: "Store | None" = None


class Store:
    def __init__(self, use_supabase: bool) -> None:
        self._use_supabase = use_supabase
        self._supabase = None
        self._memory: dict[str, list[dict[str, Any]]] = {}
        self._sessions: dict[str, dict[str, Any]] = {}
        self._bookings: list[dict[str, Any]] = []
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
        self._sessions.setdefault(
            room_id, {"room_id": room_id, "status": "active", "created_at": time.time()}
        )
        self._mem_append(f"transcripts:{room_id}", row)

    async def update_session(
        self, room_id: str, patient_id: str = "", status: str = ""
    ) -> dict[str, Any]:
        t = self._table("sessions")
        if t is not None:
            row = {"room_id": room_id}
            if patient_id:
                row["patient_id"] = patient_id
            if status:
                row["status"] = status
            await asyncio.to_thread(
                lambda: t.upsert(row, on_conflict="room_id").execute()
            )
            return row
        sess = self._sessions.setdefault(
            room_id, {"room_id": room_id, "status": "active", "created_at": time.time()}
        )
        if patient_id:
            sess["patient_id"] = patient_id
        if status:
            sess["status"] = status
        return sess

    async def create_booking(self, data: dict[str, Any]) -> dict[str, Any]:
        booking_id = f"BK-{uuid.uuid4().hex[:6].upper()}"
        row = {
            "id": booking_id,
            "patient_id": data.get("patient_id", ""),
            "room_id": data.get("room_id", ""),
            "name": data.get("name", ""),
            "slot": data.get("slot", ""),
            "reason": data.get("reason", ""),
            "status": "confirmed",
            "created_at": time.time(),
        }
        t = self._table("bookings")
        if t is not None:
            res = await asyncio.to_thread(t.insert, self._for_supabase(row))
            return res.execute().data[0]
        self._bookings.append(row)
        return row

    async def list_bookings(self, room_id: str = "") -> list[dict[str, Any]]:
        t = self._table("bookings")
        if t is not None:
            try:
                q = t.select("*")
                if room_id:
                    q = q.eq("room_id", room_id)
                res = await asyncio.to_thread(q.order, "created_at", desc=True)
                return res.execute().data
            except Exception:
                # Fallback for APIs without .order() — and return [] when the
                # table is missing from the schema cache (e.g. schema.sql not
                # re-applied yet) instead of crashing the sessions endpoint.
                try:
                    res = await asyncio.to_thread(t.select, "*")
                    rows = res.execute().data
                    if room_id:
                        rows = [r for r in rows if r.get("room_id") == room_id]
                    return sorted(
                        rows,
                        key=lambda r: r.get("created_at") or 0,
                        reverse=True,
                    )
                except Exception:
                    return []
        rows = self._bookings
        if room_id:
            rows = [r for r in rows if r.get("room_id") == room_id]
        return sorted(rows, key=lambda r: r.get("created_at") or 0, reverse=True)

    async def list_patients(self) -> list[dict[str, Any]]:
        t = self._table("patients")
        if t is not None:
            res = await asyncio.to_thread(t.select, "*")
            return res.execute().data
        return list(self._memory.get("patients", []))

    # ---- Queue (clinician dashboard) ----

    async def list_queue_sessions(
        self, status: str = "", limit: int = 50
    ) -> list[dict[str, Any]]:
        """Sessions for the clinician queue, ordered by urgency."""
        t = self._table("sessions")
        if t is not None:
            q = t.select("*, patients(name)")
            if status:
                q = q.eq("queue_status", status)
            res = await asyncio.to_thread(q.order, "created_at", desc=True)
            rows = res.execute().data
        else:
            rows = list(self._sessions.values())
            if status:
                rows = [r for r in rows if r.get("queue_status") == status]

        # Batch-fetch triage_results for urgency
        patient_ids = list({r.get("patient_id") or "" for r in rows if r.get("patient_id")})
        triage_map: dict[str, dict[str, Any]] = {}
        if patient_ids and t is not None:
            for i in range(0, len(patient_ids), 100):
                chunk = patient_ids[i : i + 100]
                try:
                    res = await asyncio.to_thread(
                        self._table("triage_results").select("*").in_, "patient_id", chunk
                    )
                    for tr in res.execute().data:
                        pid = tr.get("patient_id", "")
                        # Keep latest triage per patient
                        if pid not in triage_map or (tr.get("created_at") or 0) > (
                            triage_map[pid].get("created_at") or 0
                        ):
                            triage_map[pid] = tr
                except Exception:
                    pass
        elif patient_ids:
            for tr in self._memory.get("triage_results", []):
                pid = tr.get("patient_id", "")
                if pid in patient_ids:
                    triage_map[pid] = tr

        urgency_order = {"emergency": 0, "high": 1, "medium": 2, "low": 3}
        out: list[dict[str, Any]] = []
        for r in rows:
            pid = r.get("patient_id") or ""
            tr = triage_map.get(pid, {})
            patient_name = ""
            if t is not None:
                try:
                    pres = await asyncio.to_thread(
                        self._table("patients").select("name").eq, "id", pid
                    )
                    pdata = pres.execute().data
                    if pdata:
                        patient_name = pdata[0].get("name", "")
                except Exception:
                    pass
            else:
                for p in self._memory.get("patients", []):
                    if p.get("id") == pid:
                        patient_name = p.get("name", "")
                        break

            out.append({
                "room_id": r.get("room_id", ""),
                "patient_id": pid,
                "patient_name": patient_name,
                "status": r.get("status", ""),
                "queue_status": r.get("queue_status", "waiting"),
                "assigned_to": r.get("assigned_to"),
                "urgency_level": tr.get("urgency_level", ""),
                "chief_complaint": tr.get("chief_complaint", ""),
                "symptoms": tr.get("symptoms", []),
                "vitals": tr.get("vitals", {}),
                "created_at": r.get("created_at", ""),
            })

        out.sort(key=lambda x: urgency_order.get(x.get("urgency_level", ""), 4))
        return out[:limit]

    async def claim_session(self, room_id: str, clinician_id: str) -> dict[str, Any] | None:
        """Assign a session to a clinician. Returns updated session or None if already claimed."""
        t = self._table("sessions")
        if t is not None:
            res = await asyncio.to_thread(
                lambda: t.update({
                    "assigned_to": clinician_id,
                    "queue_status": "in_progress",
                }).eq("room_id", room_id).is_("assigned_to", None).execute()
            )
            if not res.data:
                return None
            return res.data[0] if res.data else None
        sess = self._sessions.get(room_id)
        if sess is None:
            return None
        if sess.get("assigned_to"):
            return None
        sess["assigned_to"] = clinician_id
        sess["queue_status"] = "in_progress"
        return sess

    async def unclaim_session(self, room_id: str, clinician_id: str) -> dict[str, Any] | None:
        """Release a session back to the queue. Returns updated session or None."""
        t = self._table("sessions")
        if t is not None:
            res = await asyncio.to_thread(
                lambda: t.update({
                    "assigned_to": None,
                    "queue_status": "waiting",
                }).eq("room_id", room_id).eq("assigned_to", clinician_id).execute()
            )
            return res.data[0] if res.data else None
        sess = self._sessions.get(room_id)
        if sess and sess.get("assigned_to") == clinician_id:
            sess["assigned_to"] = None
            sess["queue_status"] = "waiting"
            return sess
        return None

    # ---- Triage (structured data from Dart agent) ----

    async def upsert_vitals(self, patient_id: str, vitals: dict[str, Any]) -> None:
        """Upsert vitals into triage_results for a patient."""
        t = self._table("triage_results")
        if t is not None:
            # Try update first, insert if no row exists
            res = await asyncio.to_thread(
                lambda: t.update({"vitals": vitals}).eq("patient_id", patient_id).execute()
            )
            if not res.data:
                await asyncio.to_thread(
                    lambda: t.insert({
                        "patient_id": patient_id,
                        "urgency_level": "low",
                        "vitals": vitals,
                        "symptoms": [],
                    }).execute()
                )
            return
        # In-memory: find or create
        for tr in self._memory.get("triage_results", []):
            if tr.get("patient_id") == patient_id:
                tr["vitals"] = {**(tr.get("vitals") or {}), **vitals}
                return
        self._mem_append("triage_results", {
            "patient_id": patient_id,
            "urgency_level": "low",
            "vitals": vitals,
            "symptoms": [],
        })

    async def append_symptom(self, patient_id: str, symptom: dict[str, Any]) -> None:
        """Append a symptom to triage_results.symptoms array."""
        t = self._table("triage_results")
        if t is not None:
            # Fetch current symptoms, append, update
            res = await asyncio.to_thread(
                lambda: t.select("symptoms").eq("patient_id", patient_id).execute()
            )
            if res.data:
                current = res.data[0].get("symptoms") or []
                current.append(symptom)
                await asyncio.to_thread(
                    lambda: t.update({"symptoms": current}).eq("patient_id", patient_id).execute()
                )
            else:
                await asyncio.to_thread(
                    lambda: t.insert({
                        "patient_id": patient_id,
                        "urgency_level": "low",
                        "symptoms": [symptom],
                        "vitals": {},
                    }).execute()
                )
            return
        for tr in self._memory.get("triage_results", []):
            if tr.get("patient_id") == patient_id:
                tr.setdefault("symptoms", []).append(symptom)
                return
        self._mem_append("triage_results", {
            "patient_id": patient_id,
            "urgency_level": "low",
            "symptoms": [symptom],
            "vitals": {},
        })

    async def set_urgency(self, patient_id: str, urgency_level: str, reason: str = "") -> None:
        """Set urgency level and reason in triage_results."""
        t = self._table("triage_results")
        if t is not None:
            res = await asyncio.to_thread(
                lambda: t.update({
                    "urgency_level": urgency_level,
                    "reason": reason,
                }).eq("patient_id", patient_id).execute()
            )
            if not res.data:
                await asyncio.to_thread(
                    lambda: t.insert({
                        "patient_id": patient_id,
                        "urgency_level": urgency_level,
                        "reason": reason,
                        "symptoms": [],
                        "vitals": {},
                    }).execute()
                )
            return
        for tr in self._memory.get("triage_results", []):
            if tr.get("patient_id") == patient_id:
                tr["urgency_level"] = urgency_level
                tr["reason"] = reason
                return
        self._mem_append("triage_results", {
            "patient_id": patient_id,
            "urgency_level": urgency_level,
            "reason": reason,
            "symptoms": [],
            "vitals": {},
        })

    # ---- Bookings (cancel/reschedule) ----

    async def update_booking(self, booking_id: str, data: dict[str, Any]) -> dict[str, Any] | None:
        """Update a booking's slot, reason, or status."""
        t = self._table("bookings")
        if t is not None:
            updates = {k: v for k, v in data.items() if k in ("slot", "reason", "status")}
            res = await asyncio.to_thread(
                lambda: t.update(updates).eq("id", booking_id).execute()
            )
            return res.data[0] if res.data else None
        for b in self._bookings:
            if b.get("id") == booking_id:
                b.update({k: v for k, v in data.items() if k in ("slot", "reason", "status")})
                return b
        return None

    async def cancel_booking(self, booking_id: str) -> dict[str, Any] | None:
        """Soft-cancel a booking (set status to cancelled)."""
        return await self.update_booking(booking_id, {"status": "cancelled"})

    # ---- Follow-ups ----

    async def create_follow_up(self, data: dict[str, Any]) -> dict[str, Any]:
        """Schedule a follow-up check-in."""
        t = self._table("follow_ups")
        row = {
            "patient_id": data["patient_id"],
            "session_room_id": data.get("session_room_id", ""),
            "urgency_level": data["urgency_level"],
            "reason": data.get("reason", ""),
            "summary_snapshot": data.get("summary_snapshot", {}),
            "scheduled_for": data["scheduled_for"],
            "status": "pending",
        }
        if t is not None:
            res = await asyncio.to_thread(lambda: t.insert(self._for_supabase(row)).execute())
            return res.data[0] if res.data else row
        row["id"] = len(self._memory.get("follow_ups", [])) + 1
        self._mem_append("follow_ups", row)
        return row

    async def list_follow_ups(
        self, patient_id: str = "", status: str = "pending"
    ) -> list[dict[str, Any]]:
        """List follow-ups, optionally filtered by patient and status."""
        t = self._table("follow_ups")
        if t is not None:
            q = t.select("*")
            if patient_id:
                q = q.eq("patient_id", patient_id)
            if status:
                q = q.eq("status", status)
            res = await asyncio.to_thread(q.order, "scheduled_for", desc=False)
            return res.execute().data
        rows = self._memory.get("follow_ups", [])
        if patient_id:
            rows = [r for r in rows if r.get("patient_id") == patient_id]
        if status:
            rows = [r for r in rows if r.get("status") == status]
        return rows

    async def update_follow_up(self, follow_up_id: int, data: dict[str, Any]) -> dict[str, Any] | None:
        """Update follow-up status (complete or dismiss)."""
        t = self._table("follow_ups")
        if t is not None:
            updates = {k: v for k, v in data.items() if k in ("status",)}
            res = await asyncio.to_thread(
                lambda: t.update(updates).eq("id", follow_up_id).execute()
            )
            return res.data[0] if res.data else None
        for fu in self._memory.get("follow_ups", []):
            if fu.get("id") == follow_up_id:
                fu.update({k: v for k, v in data.items() if k in ("status",)})
                return fu
        return None

    # ---- RAG knowledge base ----

    async def upsert_knowledge(self, chunks: list[dict[str, Any]]) -> int:
        """Insert knowledge chunks (embedding must already be computed).

        Batched (50 rows/call): Supabase's default statement timeout kills
        single large inserts of 2048-dim vectors.
        """
        if not chunks:
            return 0
        t = self._table("knowledge_chunks")
        if t is not None:
            rows = [
                {
                    "title": c.get("title", ""),
                    "category": c.get("category", "general"),
                    "content": c.get("content", ""),
                    "source": c.get("source", ""),
                    "embedding": c.get("embedding", []),
                }
                for c in chunks
            ]
            inserted = 0
            for i in range(0, len(rows), 50):
                batch = rows[i : i + 50]
                await asyncio.to_thread(lambda: t.insert(batch).execute())
                inserted += len(batch)
            return inserted
        self._memory.setdefault("knowledge_chunks", []).extend(chunks)
        return len(chunks)

    async def count_knowledge(self) -> int:
        t = self._table("knowledge_chunks")
        if t is not None:
            try:
                res = await asyncio.to_thread(
                    lambda: t.select("id", count="exact").execute()
                )
                return int(res.count or 0)
            except Exception:
                return 0
        return len(self._memory.get("knowledge_chunks", []))

    @staticmethod
    def _tokenize(text: str) -> Counter[str]:
        return Counter(re.findall(r"[a-z0-9]{3,}", text.lower()))

    async def search_knowledge(
        self, query: str, k: int = 3, category: str = ""
    ) -> list[dict[str, Any]]:
        """Search the knowledge base through the Supabase API.

        Default mode (``RAG_SEARCH_MODE=keyword``) is Postgres full-text search
        via the ``search_knowledge_keyword`` RPC — no query-time embedding call,
        so retrieval adds only one fast API round trip. ``vector`` embeds the
        query then runs the pgvector RPC; ``hybrid`` merges both. Without
        Supabase, falls back to TF-IDF-ish scoring over the in-memory store.
        """
        if not query.strip():
            return []
        if self._table("knowledge_chunks") is not None:
            mode = get_settings().rag_search_mode
            if mode == "vector":
                return await self._search_vector(query, k, category)
            if mode == "hybrid":
                merged: dict[Any, dict[str, Any]] = {}
                for row in await self._search_keyword(query, k, category) + await self._search_vector(query, k, category):
                    merged.setdefault(row.get("id"), row)
                return list(merged.values())[:k]
            return await self._search_keyword(query, k, category)
        # In-memory fallback: lightweight TF-IDF-ish token scoring so the demo
        # still answers without Supabase. Rare query terms weigh more than
        # common ones (fever/cough vs the/what).
        corpus = self._memory.get("knowledge_chunks", [])
        n = max(1, len(corpus))
        doc_freq: Counter[str] = Counter()
        for c in corpus:
            doc_freq.update(set(self._tokenize(f"{c.get('title', '')} {c.get('content', '')}")))
        q_counts = self._tokenize(query)
        scored: list[tuple[float, dict[str, Any]]] = []
        for c in corpus:
            if category and c.get("category", "general") != category:
                continue
            hay = self._tokenize(f"{c.get('title', '')} {c.get('content', '')}")
            score = 0.0
            for term, qf in q_counts.items():
                tf = hay.get(term, 0)
                if not tf:
                    continue
                idf = 1.0 + math.log(n / (doc_freq[term] + 1))
                score += qf * tf * idf
            if score > 0:
                scored.append(
                    (score, {key: c.get(key) for key in ("title", "category", "content", "source")})
                )
        scored.sort(key=lambda p: p[0], reverse=True)
        return [row for _, row in scored[:k]]

    async def _search_keyword(
        self, query: str, k: int, category: str
    ) -> list[dict[str, Any]]:
        """Postgres full-text search via Supabase RPC (no embeddings)."""
        try:
            res = await asyncio.to_thread(
                lambda: self._supabase.rpc(
                    "search_knowledge_keyword",
                    {
                        "query_text": query,
                        "match_count": k,
                        "filter_category": category or "",
                    },
                ).execute()
            )
            return list(res.data)
        except Exception:
            return []

    async def _search_vector(
        self, query: str, k: int, category: str
    ) -> list[dict[str, Any]]:
        """Semantic search: embed the query, then the pgvector RPC."""
        from rag.embeddings import embed_query

        try:
            qv = await asyncio.to_thread(embed_query, query)
        except Exception:
            return []
        try:
            res = await asyncio.to_thread(
                lambda: self._supabase.rpc(
                    "match_knowledge_chunks",
                    {
                        "query_embedding": qv,
                        "match_count": k,
                        "filter_category": category or "",
                    },
                ).execute()
            )
            return list(res.data)
        except Exception:
            return []

    async def list_sessions(
        self, patient_id: str = "", owner_id: str = ""
    ) -> list[dict[str, Any]]:
        """Sessions for the history screen, newest first."""
        t = self._table("sessions")
        if t is not None:
            if owner_id:
                try:
                    q = t.select("*, patients!inner(owner_id)").eq(
                        "patients.owner_id", owner_id
                    )
                    if patient_id:
                        q = q.eq("patient_id", patient_id)
                    res = await asyncio.to_thread(q.execute)
                    rows = list(res.data)
                    owner_filtered = True
                except Exception:
                    q = t.select("*")
                    if patient_id:
                        q = q.eq("patient_id", patient_id)
                    res = await asyncio.to_thread(q.execute)
                    rows = list(res.data)
                    owner_filtered = False
            else:
                q = t.select("*")
                if patient_id:
                    q = q.eq("patient_id", patient_id)
                res = await asyncio.to_thread(q.execute)
                rows = list(res.data)
                owner_filtered = True
        else:
            rows = list(self._sessions.values())
            if patient_id:
                rows = [r for r in rows if r.get("patient_id") == patient_id]
            owner_filtered = False

        ids = list({r.get("patient_id") or "" for r in rows})
        if t is not None:
            patients: dict[str, dict[str, Any]] = {}
            for i in range(0, len(ids), 100):
                chunk = ids[i : i + 100]
                res = await asyncio.to_thread(
                    self._table("patients").select("*").in_, "id", chunk
                )
                for p in res.execute().data:
                    patients[p.get("id", "")] = p
        else:
            patients = {p.get("id", ""): p for p in self._memory.get("patients", [])}

        # Count transcripts + bookings per room in two batched queries instead
        # of one round trip per session row (N+1 made /sessions time out with
        # more than a handful of sessions).
        room_ids = list({r.get("room_id", "") for r in rows if r.get("room_id")})
        transcript_counts: dict[str, int] = {}
        booking_counts: dict[str, int] = {}
        if t is not None:
            for i in range(0, len(room_ids), 100):
                chunk = room_ids[i : i + 100]
                try:
                    res = await asyncio.to_thread(
                        self._table("transcripts").select("room_id").in_, "room_id", chunk
                    )
                    for row in res.execute().data:
                        rid = row.get("room_id", "")
                        transcript_counts[rid] = transcript_counts.get(rid, 0) + 1
                except Exception:
                    pass
                try:
                    res = await asyncio.to_thread(
                        self._table("bookings").select("room_id").in_, "room_id", chunk
                    )
                    for row in res.execute().data:
                        rid = row.get("room_id", "")
                        booking_counts[rid] = booking_counts.get(rid, 0) + 1
                except Exception:
                    pass
        else:
            for rid in room_ids:
                transcript_counts[rid] = len(
                    self._memory.get(f"transcripts:{rid}", [])
                )
                booking_counts[rid] = len(
                    [b for b in self._bookings if b.get("room_id") == rid]
                )

        if owner_id and not owner_filtered:
            rows = [
                r
                for r in rows
                if patients.get(r.get("patient_id") or "", {}).get("owner_id")
                == owner_id
            ]

        out: list[dict[str, Any]] = []
        for r in rows:
            room_id = r.get("room_id", "")
            pid = r.get("patient_id") or ""
            created = r.get("created_at")
            if isinstance(created, (int, float)):
                created = datetime.fromtimestamp(float(created)).isoformat()
            out.append(
                {
                    "room_id": room_id,
                    "patient_id": pid,
                    "patient_name": patients.get(pid, {}).get("name", ""),
                    "status": r.get("status", ""),
                    "created_at": created or "",
                    "transcript_count": transcript_counts.get(room_id, 0),
                    "booking_count": booking_counts.get(room_id, 0),
                }
            )

        def _sort_key(r: dict[str, Any]) -> float:
            try:
                return datetime.fromisoformat(r["created_at"]).timestamp()
            except (ValueError, TypeError):
                return 0.0

        out.sort(key=_sort_key, reverse=True)
        return out


def get_store() -> Store:
    global _SLOT
    if _SLOT is None:
        s = get_settings()
        use_sb = bool(s.supabase_url and s.supabase_service_key)
        _SLOT = Store(use_supabase=use_sb)
    return _SLOT
