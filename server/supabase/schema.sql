-- Voice Clinical Dispatcher - Supabase schema (run in Supabase SQL editor)
-- RLS: patients own their data; clinicians (role 'clinician' in app_metadata) can read all.

create extension if not exists "uuid-ossp";

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
  ended_at timestamptz
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
create policy "profiles_own" on public.profiles
  for all using (auth.uid() = id);
create policy "profiles_clinician_read" on public.profiles
  for select using (public.is_clinician());

-- patients: owner or clinician
create policy "patients_own" on public.patients
  for all using (auth.uid() = owner_id or public.is_clinician());
create policy "patients_read_all" on public.patients
  for select using (true);

-- sessions/transcripts/triage/summaries: clinician or linked patient owner
create policy "sessions_access" on public.sessions
  for all using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );
create policy "transcripts_access" on public.transcripts
  for select using (
    public.is_clinician()
    or room_id in (
      select s.room_id from public.sessions s
      join public.patients p on p.id = s.patient_id
      where p.owner_id = auth.uid()
    )
  );
create policy "triage_access" on public.triage_results
  for select using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );
create policy "summaries_access" on public.ehr_summaries
  for select using (
    public.is_clinician()
    or patient_id in (select id from public.patients where owner_id = auth.uid())
  );

-- DEMO ONLY: let the unauthenticated demo app receive EHR summaries over realtime.
-- Remove before any production use.
create policy "summaries_demo_anon_read" on public.ehr_summaries
  for select using (true);

-- DEMO ONLY: expose inserts on ehr_summaries to the realtime subscription.
alter publication supabase_realtime add table public.ehr_summaries;

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
