-- Voice Clinical Dispatcher - Supabase schema (run in Supabase SQL editor)
-- RLS: patients own their data; clinicians (role 'clinician' in app_metadata) can read all.

create extension if not exists "uuid-ossp";
-- RAG knowledge base: needs pgvector. If this fails, run `create extension vector;`
-- in the Supabase dashboard SQL editor (free plan supports it).
create extension if not exists vector;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'patient' check (role in ('patient', 'clinician')),
  created_at timestamptz not null default now()
);

create table if not exists public.patients (
  id text primary key,
  owner_id uuid references auth.users(id) on delete set null,
  name text not null,
  age text,
  sex text,
  known_conditions text,
  allergies text,
  created_at timestamptz not null default now()
);

create table if not exists public.sessions (
  room_id text primary key,
  patient_id text references public.patients(id) on delete set null,
  language text,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  assigned_to uuid references public.profiles(id) on delete set null,
  queue_status text not null default 'waiting' check (queue_status in ('waiting', 'in_progress', 'completed'))
);

create table if not exists public.transcripts (
  id bigint generated always as identity primary key,
  room_id text not null references public.sessions(room_id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  text text not null,
  language text,
  is_final boolean not null default true,
  created_at double precision not null
);
create index if not exists idx_transcripts_room on public.transcripts (room_id, created_at);

create table if not exists public.triage_results (
  id bigint generated always as identity primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  urgency_level text not null check (urgency_level in ('low', 'medium', 'high', 'emergency')),
  reason text,
  chief_complaint text,
  symptoms jsonb not null default '[]',
  vitals jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create table if not exists public.ehr_summaries (
  id bigint generated always as identity primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  summary jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id text primary key,
  patient_id text references public.patients(id) on delete set null,
  room_id text references public.sessions(room_id) on delete set null,
  name text,
  slot text not null,
  reason text,
  status text not null default 'confirmed',
  created_at timestamptz not null default now()
);

alter table public.bookings enable row level security;

drop policy if exists "bookings_access" on public.bookings;
create policy "bookings_access" on public.bookings
  for all using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );

-- ---- Follow-up check-ins ----
create table if not exists public.follow_ups (
  id bigint generated always as identity primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  session_room_id text references public.sessions(room_id) on delete set null,
  urgency_level text not null check (urgency_level in ('medium', 'high')),
  reason text,
  summary_snapshot jsonb not null default '{}',
  scheduled_for timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'completed', 'dismissed')),
  created_at timestamptz not null default now()
);

alter table public.follow_ups enable row level security;

drop policy if exists "follow_ups_access" on public.follow_ups;
create policy "follow_ups_access" on public.follow_ups
  for all using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );

-- DEMO ONLY: expose follow_ups to realtime
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'follow_ups'
  ) then
    alter publication supabase_realtime add table public.follow_ups;
  end if;
end $$;

-- ---- RAG knowledge base (pgvector) ----
-- embedding is an *unconstrained* vector so the embedding model's dimensions
-- stay configurable (EMBEDDING_MODEL in server/.env). Add a HNSW index if the
-- corpus grows past ~10k chunks:
--   create index on public.knowledge_chunks using hnsw (embedding vector_cosine_ops);
-- search_vector is a *generated* tsvector column (auto-maintained, backfilled
-- automatically when this column is added) powering the keyword/full-text
-- search path — no query-time embedding call needed.
create table if not exists public.knowledge_chunks (
  id bigint generated always as identity primary key,
  title text not null,
  category text not null default 'general',
  content text not null,
  source text not null default '',
  embedding vector,
  search_vector tsvector generated always as
    (to_tsvector('english', title || ' ' || content)) stored,
  created_at timestamptz not null default now()
);
-- Migration for deployments where knowledge_chunks already existed without
-- tsvector (generated columns are backfilled automatically when added).
-- Must run BEFORE the GIN index below (which references search_vector).
alter table public.knowledge_chunks
  add column if not exists search_vector tsvector generated always as
    (to_tsvector('english', title || ' ' || content)) stored;

create index if not exists idx_knowledge_search on public.knowledge_chunks
  using gin (search_vector);

-- DEMO ONLY: knowledge base is public read (matches the unauthenticated demo).
alter table public.knowledge_chunks enable row level security;
drop policy if exists "knowledge_read_all" on public.knowledge_chunks;
create policy "knowledge_read_all" on public.knowledge_chunks
  for select using (true);

-- Cosine-similarity search. filter_category = '' means no filter.
create or replace function public.match_knowledge_chunks(
  query_embedding vector,
  match_count int default 5,
  filter_category text default ''
)
returns table (
  id bigint,
  title text,
  category text,
  content text,
  source text,
  similarity float
)
language sql stable security definer set search_path = public as $$
  select
    kc.id,
    kc.title,
    kc.category,
    kc.content,
    kc.source,
    1 - (kc.embedding <=> query_embedding) as similarity
  from public.knowledge_chunks kc
  where kc.embedding is not null
    and (filter_category = '' or kc.category = filter_category)
  order by kc.embedding <=> query_embedding
  limit match_count;
$$;

-- Keyword / full-text search: NO query-time embedding call (fast, direct
-- Supabase API retrieval). Uses the generated search_vector column.
create or replace function public.search_knowledge_keyword(
  query_text text,
  match_count int default 5,
  filter_category text default ''
)
returns table (
  id bigint,
  title text,
  category text,
  content text,
  source text,
  similarity float
)
language sql stable security definer set search_path = public as $$
  select
    kc.id,
    kc.title,
    kc.category,
    kc.content,
    kc.source,
    ts_rank(kc.search_vector, websearch_to_tsquery('english', query_text)) as similarity
  from public.knowledge_chunks kc
  where kc.search_vector @@ websearch_to_tsquery('english', query_text)
    and (filter_category = '' or kc.category = filter_category)
  order by similarity desc
  limit match_count;
$$;

-- ---- Row Level Security ----
alter table public.profiles enable row level security;
alter table public.patients enable row level security;
alter table public.sessions enable row level security;
alter table public.transcripts enable row level security;
alter table public.triage_results enable row level security;
alter table public.ehr_summaries enable row level security;

create or replace function public.is_clinician()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((auth.jwt() -> 'app_metadata' -> 'role')::text, '"patient"') = '"clinician"';
$$;

-- profiles: users manage their own; clinicians can read all
drop policy if exists "profiles_own" on public.profiles;
create policy "profiles_own" on public.profiles
  for all using (auth.uid() = id);
drop policy if exists "profiles_clinician_read" on public.profiles;
create policy "profiles_clinician_read" on public.profiles
  for select using (public.is_clinician());

-- patients: owner or clinician (with check lets users insert their own records)
drop policy if exists "patients_own" on public.patients;
create policy "patients_own" on public.patients
  for all using (auth.uid() = owner_id or public.is_clinician())
  with check (auth.uid() = owner_id or public.is_clinician());
drop policy if exists "patients_read_all" on public.patients;
create policy "patients_read_all" on public.patients
  for select using (true);

-- sessions/transcripts/triage/summaries: clinician or linked patient owner
drop policy if exists "sessions_access" on public.sessions;
create policy "sessions_access" on public.sessions
  for all using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );
-- clinicians can claim/unclaim sessions (update assigned_to and queue_status)
drop policy if exists "sessions_clinician_claim" on public.sessions;
create policy "sessions_clinician_claim" on public.sessions
  for update using (public.is_clinician())
  with check (public.is_clinician());
drop policy if exists "transcripts_access" on public.transcripts;
create policy "transcripts_access" on public.transcripts
  for select using (
    public.is_clinician()
    or room_id in (
      select s.room_id from public.sessions s
      join public.patients p on p.id = s.patient_id
      where p.owner_id = auth.uid()
    )
  );
drop policy if exists "triage_access" on public.triage_results;
create policy "triage_access" on public.triage_results
  for select using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );
drop policy if exists "summaries_access" on public.ehr_summaries;
create policy "summaries_access" on public.ehr_summaries
  for select using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );

-- DEMO ONLY: let the unauthenticated demo app receive EHR summaries over realtime.
-- Remove before any production use.
drop policy if exists "summaries_demo_anon_read" on public.ehr_summaries;
create policy "summaries_demo_anon_read" on public.ehr_summaries
  for select using (true);

-- DEMO ONLY: expose inserts on ehr_summaries to the realtime subscription.
-- Idempotent: only adds the table if it isn't already in the publication
-- (ALTER PUBLICATION ... DROP TABLE IF EXISTS needs PG15+, so use a DO block).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'ehr_summaries'
  ) then
    alter publication supabase_realtime add table public.ehr_summaries;
  end if;
end $$;

-- trigger: auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''), 'patient')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
