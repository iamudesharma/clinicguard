---
name: supabase
description: Use when working with Supabase in this repo — schema.sql, store.py queries, realtime subscriptions, RLS policies, or writing SQL queries against ClinicGuard data. Covers which key to use where, what's demo-only, and the store.py fallback behavior.
---

# Supabase in ClinicGuard

Supabase is the optional persistence layer: if `SUPABASE_URL` + key are unset, the server silently runs an in-memory demo store. Always keep both paths working.

## Schema (`server/supabase/schema.sql`)

Tables: `profiles` (auth-linked, role patient|clinician), `patients` (id text PK, owner_id), `sessions` (room_id PK, patient_id FK), `transcripts` (identity PK, room_id FK → sessions, `created_at` is **double precision epoch**, role check user|assistant), `triage_results` (urgency check low|medium|high|emergency, symptoms/vitals jsonb), `ehr_summaries` (summary jsonb).

Key facts:
- RLS is enabled on all tables. Server writes with the **service key**, which bypasses RLS. The app reads with the **anon key**, which is subject to RLS.
- `summaries_demo_anon_read` policy + `alter publication supabase_realtime add table public.ehr_summaries` are **DEMO ONLY** — the unauthenticated app receives live EHR summaries over realtime. Remove for production.
- `sessions.room_id` is the FK target for transcripts; `store.append_transcript` upserts the session first to satisfy it.

## Server access — always through `server/store.py`

`agent.py` and `api/main.py` must never talk to Supabase directly. `Store` (`get_store()`, store.py:130) is the single seam; every method has an in-memory twin:
- `create_patient` / `get_patient` / `list_patients`
- `save_triage` / `save_summary`
- `get_transcripts` / `append_transcript`

Gotchas:
- `_for_supabase()` (store.py:33) drops client-side `created_at` epoch values — the DB columns use `timestamptz default now()`; only `transcripts.created_at` is a client-supplied `double precision`.
- All Supabase I/O goes through `asyncio.to_thread` (blocking sync client). Keep that pattern.
- Store is a module singleton — created once with settings loaded from `server/.env` (run from `server/`).

## Keys — which one, where

| Context | Key | Config | Notes |
| ------- | --- | ------ | ----- |
| Server writes | `SUPABASE_SERVICE_KEY` | `server/.env` (`supabase_service_key` in config.py) | Secret — bypasses RLS. Never commit. |
| App reads | `SUPABASE_ANON_KEY` | `app/lib/config.dart` (dart-define, publishable default) | Publishable by design — not a secret. |
| SQL editor | — | Supabase dashboard | For schema/RLS work. |

App init: `app/lib/main.dart:12` (`Supabase.initialize`). Realtime: `app/lib/state/call_state.dart:156-176` subscribes to channel `ehr-live`, postgres_changes on `ehr_summaries` inserts → updates the summary card mid-call.

## Common queries

```sql
-- latest summary per patient
select patient_id, summary, created_at from public.ehr_summaries
order by created_at desc limit 10;

-- full call transcript for a room (schema order)
select role, text, language from public.transcripts
where room_id = '<room_id>' order by created_at;

-- triage history with urgency
select patient_id, urgency_level, chief_complaint, symptoms from public.triage_results
order by created_at desc;
```

Note `transcripts.created_at` is epoch (double precision) — order by it directly, and filter with numeric comparisons, not `now()`.

## Rules

- Never expose the service key to the app or docs; only the anon key is publishable (`lib/config.dart`).
- Adding a table for realtime updates requires adding it to the `supabase_realtime` publication + a select policy for anon.
- RLS changes must be tested with the anon key (the app path), not just the service key.
- When schema changes, update `server/supabase/schema.sql` (idempotent `create table if not exists` + `create or replace`) AND `store.py`'s in-memory twin in the same change.
- Verify: `uv run python agent.py console`, `curl localhost:8000/sessions/<id>/summary`, and `flutter test` (app side).