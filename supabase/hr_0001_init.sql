-- ============================================================
-- HR / Recruitment app — schema v1
-- Same Supabase project as Maintenance & Store Visit.
-- Run: Supabase Dashboard -> SQL Editor -> New query -> paste -> Run
-- Safe to re-run (creates only what is missing, replaces functions/policies).
--
-- Design:
--   * Reading: any user with an HR role (owner = automatic admin).
--   * Writing: ONLY through the hr_* functions below, which check the role,
--     enforce the status flow and write the activity log in one step.
--     There are deliberately no insert/update/delete policies on the tables.
--   * Files: private bucket "hr-files", no public URLs.
-- ============================================================

-- ---------- access ----------
create table if not exists public.hr_access (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('admin', 'hr', 'reviewer')),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Current user's HR role: 'admin' | 'hr' | 'reviewer' | null.
-- Global owners are always HR admin; everyone else needs an hr_access row.
create or replace function public.hr_role()
returns text language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.profiles where id = auth.uid() and role = 'owner') then 'admin'
    else (select a.role from public.hr_access a where a.user_id = auth.uid())
  end
$$;

create or replace function public.hr_require(p_roles text[])
returns text language plpgsql stable security definer set search_path = public as $$
declare r text := public.hr_role();
begin
  if r is null or not (r = any(p_roles)) then
    raise exception 'You do not have permission for this action.';
  end if;
  return r;
end $$;

-- ---------- master data ----------
create table if not exists public.hr_positions (
  id         bigint generated always as identity primary key,
  department text not null,
  position   text not null,
  sort       int  not null default 0,
  active     boolean not null default true,
  unique (department, position)
);

-- Extra brands not (yet) in the shared outlets list (app_config key 'outlets').
-- The app shows outlets-list brands + these, de-duplicated.
create table if not exists public.hr_brands (
  name   text primary key,
  active boolean not null default true
);

insert into public.hr_positions (department, position, sort) values
  ('FOH', 'Area Manager', 1), ('FOH', 'Restaurant Manager', 2), ('FOH', 'Supervisor', 3),
  ('FOH', 'Captain', 4), ('FOH', 'Host', 5), ('FOH', 'Cashier', 6), ('FOH', 'Server', 7),
  ('Bar', 'Barista', 10),
  ('BOH', 'Head Chef', 20), ('BOH', 'Sous Chef', 21), ('BOH', 'Jr. Sous Chef', 22),
  ('BOH', 'CDP', 23), ('BOH', 'Cook', 24), ('BOH', 'Steward', 25),
  ('Pastry', 'Pastry Head', 30), ('Pastry', 'Pastry', 31),
  ('Office', 'Operations Manager', 40), ('Office', 'Brand & Marketing Manager', 41),
  ('Office', 'Marketing', 42), ('Office', 'Creative Team', 43)
on conflict (department, position) do nothing;

insert into public.hr_brands (name) values
  ('Mensho Tokyo'), ('Bulgogi Syo'), ('Seorae Jib'), ('Real Hakka')
on conflict (name) do nothing;

-- ---------- candidates ----------
create sequence if not exists public.hr_candidate_seq;

create table if not exists public.hr_candidates (
  id             text primary key default ('HR-' || lpad(nextval('public.hr_candidate_seq')::text, 5, '0')),
  created_at     timestamptz not null default now(),
  created_by     uuid,
  name           text not null check (length(trim(name)) > 0),
  phone          text,
  email          text,
  -- digits only, 62xxx -> 0xxx, used for duplicate detection
  phone_norm     text generated always as (
    case when regexp_replace(coalesce(phone, ''), '\D', '', 'g') like '62%'
         then '0' || substr(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 3)
         else regexp_replace(coalesce(phone, ''), '\D', '', 'g') end
  ) stored,
  brand          text not null,
  department     text not null,
  position       text not null,
  source         text,
  notes          text,
  portfolio_link text,
  status         text not null default 'NEW' check (status in (
                   'NEW', 'SHORTLISTED', 'KEEP_SCREENING', 'REJECTED_SCREENING',
                   'INTERVIEW_SCHEDULED', 'INTERVIEWED', 'PASSED', 'KEEP_INTERVIEW', 'REJECTED_INTERVIEW')),
  interview_at       timestamptz,
  interviewer        text,
  interview_location text,
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);
create index if not exists hr_candidates_status_idx on public.hr_candidates (status);
create index if not exists hr_candidates_phone_idx  on public.hr_candidates (phone_norm);
create index if not exists hr_candidates_email_idx  on public.hr_candidates (email);

create table if not exists public.hr_interviews (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   text not null references public.hr_candidates(id) on delete cascade,
  round          int  not null,
  interview_at   timestamptz,
  interviewer    text,
  recommendation text,
  comment        text not null,
  recorded_by    uuid,
  recorded_by_name text,
  recorded_at    timestamptz not null default now()
);
create index if not exists hr_interviews_cand_idx on public.hr_interviews (candidate_id);

create table if not exists public.hr_files (
  id           uuid primary key default gen_random_uuid(),
  candidate_id text not null references public.hr_candidates(id) on delete cascade,
  interview_id uuid references public.hr_interviews(id) on delete set null,
  kind         text not null check (kind in ('cv', 'portfolio', 'interview')),
  name         text not null,
  path         text not null unique,        -- storage path in bucket hr-files
  size         bigint,
  mime         text,
  uploaded_by  uuid,
  uploaded_at  timestamptz not null default now()
);
create index if not exists hr_files_cand_idx on public.hr_files (candidate_id);

create table if not exists public.hr_activity (
  id           bigint generated always as identity primary key,
  candidate_id text not null references public.hr_candidates(id) on delete cascade,
  at           timestamptz not null default now(),
  user_id      uuid,
  user_name    text,
  action       text not null,
  from_status  text,
  to_status    text,
  comment      text
);
create index if not exists hr_activity_cand_idx on public.hr_activity (candidate_id);

-- Who opened which file, and candidate deletions. Kept even after a candidate is deleted.
create table if not exists public.hr_access_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  user_id      uuid,
  user_name    text,
  action       text not null,              -- 'view' | 'delete_candidate'
  candidate_id text,
  file_name    text
);

-- ---------- Row Level Security (read-only; writes go through functions) ----------
alter table public.hr_access      enable row level security;
alter table public.hr_positions   enable row level security;
alter table public.hr_brands      enable row level security;
alter table public.hr_candidates  enable row level security;
alter table public.hr_interviews  enable row level security;
alter table public.hr_files       enable row level security;
alter table public.hr_activity    enable row level security;
alter table public.hr_access_log  enable row level security;

drop policy if exists hr_access_read     on public.hr_access;
drop policy if exists hr_positions_read  on public.hr_positions;
drop policy if exists hr_brands_read     on public.hr_brands;
drop policy if exists hr_candidates_read on public.hr_candidates;
drop policy if exists hr_interviews_read on public.hr_interviews;
drop policy if exists hr_files_read      on public.hr_files;
drop policy if exists hr_activity_read   on public.hr_activity;
drop policy if exists hr_access_log_read on public.hr_access_log;

create policy hr_access_read     on public.hr_access     for select to authenticated using (user_id = auth.uid() or public.hr_role() = 'admin');
create policy hr_positions_read  on public.hr_positions  for select to authenticated using (public.hr_role() is not null);
create policy hr_brands_read     on public.hr_brands     for select to authenticated using (public.hr_role() is not null);
create policy hr_candidates_read on public.hr_candidates for select to authenticated using (public.hr_role() is not null);
create policy hr_interviews_read on public.hr_interviews for select to authenticated using (public.hr_role() is not null);
create policy hr_files_read      on public.hr_files      for select to authenticated using (public.hr_role() is not null);
create policy hr_activity_read   on public.hr_activity   for select to authenticated using (public.hr_role() is not null);
create policy hr_access_log_read on public.hr_access_log for select to authenticated using (public.hr_role() = 'admin');

-- ---------- storage ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('hr-files', 'hr-files', false, 10485760)   -- 10 MB per file
on conflict (id) do update set public = false, file_size_limit = 10485760;

drop policy if exists hr_files_obj_read   on storage.objects;
drop policy if exists hr_files_obj_insert on storage.objects;
drop policy if exists hr_files_obj_delete on storage.objects;

create policy hr_files_obj_read on storage.objects for select to authenticated
  using (bucket_id = 'hr-files' and public.hr_role() is not null);
create policy hr_files_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'hr-files' and public.hr_role() in ('admin', 'hr'));
create policy hr_files_obj_delete on storage.objects for delete to authenticated
  using (bucket_id = 'hr-files' and public.hr_role() = 'admin');

-- ============================================================
-- Internal helpers (not callable from the app)
-- ============================================================
create or replace function public.hr_me_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select coalesce(nullif(trim(name), ''), email) from public.profiles where id = auth.uid()), 'unknown')
$$;

create or replace function public.hr_log(p_id text, p_action text, p_from text, p_to text, p_comment text)
returns void language sql security definer set search_path = public as $$
  insert into public.hr_activity (candidate_id, user_id, user_name, action, from_status, to_status, comment)
  values (p_id, auth.uid(), public.hr_me_name(), p_action, p_from, p_to, nullif(trim(coalesce(p_comment, '')), ''));
$$;

-- Validates the move, updates status, logs it. Returns the previous status.
create or replace function public.hr_transition(p_id text, p_from text[], p_to text, p_comment text, p_action text)
returns text language plpgsql security definer set search_path = public as $$
declare v_from text;
begin
  select status into v_from from public.hr_candidates where id = p_id for update;
  if v_from is null then raise exception 'Candidate not found.'; end if;
  if not (v_from = any(p_from)) then
    raise exception 'This candidate is now %. Please refresh and try again.', v_from;
  end if;
  if p_to like 'REJECTED%' and coalesce(trim(p_comment), '') = '' then
    raise exception 'Please add a reason for rejecting.';
  end if;
  update public.hr_candidates set status = p_to, updated_at = now(), updated_by = auth.uid() where id = p_id;
  perform public.hr_log(p_id, p_action, v_from, p_to, p_comment);
  return v_from;
end $$;

revoke execute on function public.hr_me_name() from public, anon, authenticated;
revoke execute on function public.hr_log(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.hr_transition(text, text[], text, text, text) from public, anon, authenticated;

-- ============================================================
-- App functions (called with sb.rpc)
-- ============================================================

create or replace function public.hr_create_candidate(p jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  perform public.hr_require(array['admin', 'hr']);
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Candidate name is required.'; end if;
  if coalesce(trim(p->>'brand'), '') = '' then raise exception 'Please choose a brand.'; end if;
  if not exists (select 1 from public.hr_positions
                 where department = p->>'department' and position = p->>'position' and active) then
    raise exception 'Please choose a valid position.';
  end if;
  insert into public.hr_candidates
    (created_by, name, phone, email, brand, department, position, source, notes, portfolio_link, updated_by)
  values
    (auth.uid(), trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(lower(trim(p->>'email')), ''),
     trim(p->>'brand'), p->>'department', p->>'position', nullif(trim(p->>'source'), ''),
     nullif(trim(p->>'notes'), ''), nullif(trim(p->>'portfolio_link'), ''), auth.uid())
  returning id into v_id;
  perform public.hr_log(v_id, 'Candidate added', null, 'NEW', p->>'notes');
  return v_id;
end $$;

-- Register a file after the app uploaded it to hr-files/<candidate id>/...
create or replace function public.hr_add_file(p_candidate text, p_kind text, p_name text, p_path text,
                                              p_size bigint, p_mime text, p_interview uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  perform public.hr_require(array['admin', 'hr']);
  if not exists (select 1 from public.hr_candidates where id = p_candidate) then raise exception 'Candidate not found.'; end if;
  if p_kind not in ('cv', 'portfolio', 'interview') then raise exception 'Invalid file type.'; end if;
  -- Supabase Storage paths start with "<candidate id>/"; Google Drive files are stored as "gdrive:<file id>"
  -- (registered by the Drive bridge, which checks the file sits in the private recruitment folder).
  if not (position((p_candidate || '/') in p_path) = 1 or p_path ~ '^gdrive:[A-Za-z0-9_-]{10,}$') then
    raise exception 'Invalid file path.';
  end if;
  insert into public.hr_files (candidate_id, interview_id, kind, name, path, size, mime, uploaded_by)
  values (p_candidate, p_interview, p_kind, p_name, p_path, p_size, p_mime, auth.uid())
  returning id into v_id;
  perform public.hr_log(p_candidate, 'File added', null, null,
    case p_kind when 'cv' then 'CV: ' when 'portfolio' then 'Portfolio: ' else 'Interview form: ' end || p_name);
  return v_id;
end $$;

create or replace function public.hr_screening(p_id text, p_to text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.hr_require(array['admin', 'hr', 'reviewer']);
  if p_to not in ('SHORTLISTED', 'KEEP_SCREENING', 'REJECTED_SCREENING') then raise exception 'Invalid status.'; end if;
  perform public.hr_transition(p_id, array['NEW', 'KEEP_SCREENING', 'SHORTLISTED'], p_to, p_comment, 'Screening decision');
end $$;

create or replace function public.hr_schedule(p_id text, p_at timestamptz, p_interviewer text, p_location text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cur text; v_note text;
begin
  perform public.hr_require(array['admin', 'hr']);
  if p_at is null then raise exception 'Please pick the interview date and time.'; end if;
  if coalesce(trim(p_interviewer), '') = '' then raise exception 'Please fill in the interviewer.'; end if;
  select status into v_cur from public.hr_candidates where id = p_id;
  v_note := 'Interview ' || to_char(p_at at time zone 'Asia/Jakarta', 'DD Mon YYYY HH24:MI') || ' with ' || trim(p_interviewer)
            || coalesce(' @ ' || nullif(trim(p_location), ''), '')
            || coalesce(E'\n' || nullif(trim(p_comment), ''), '');
  perform public.hr_transition(p_id, array['SHORTLISTED', 'INTERVIEW_SCHEDULED', 'INTERVIEWED', 'KEEP_INTERVIEW'],
    'INTERVIEW_SCHEDULED', v_note,
    case when v_cur = 'INTERVIEW_SCHEDULED' then 'Interview rescheduled' else 'Interview scheduled' end);
  update public.hr_candidates
     set interview_at = p_at, interviewer = trim(p_interviewer), interview_location = nullif(trim(p_location), '')
   where id = p_id;
end $$;

-- Returns the new interview id (so the app can attach the interview form to it).
create or replace function public.hr_record_interview(p_id text, p_recommendation text, p_comment text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_c record; v_iid uuid; v_round int;
begin
  perform public.hr_require(array['admin', 'hr']);
  if coalesce(trim(p_comment), '') = '' then raise exception 'Please add your interview comments.'; end if;
  perform public.hr_transition(p_id, array['INTERVIEW_SCHEDULED'], 'INTERVIEWED', p_comment, 'Interview recorded');
  select interview_at, interviewer into v_c from public.hr_candidates where id = p_id;
  select count(*) + 1 into v_round from public.hr_interviews where candidate_id = p_id;
  insert into public.hr_interviews (candidate_id, round, interview_at, interviewer, recommendation, comment, recorded_by, recorded_by_name)
  values (p_id, v_round, v_c.interview_at, v_c.interviewer, nullif(trim(p_recommendation), ''), trim(p_comment), auth.uid(), public.hr_me_name())
  returning id into v_iid;
  return v_iid;
end $$;

create or replace function public.hr_interview_decision(p_id text, p_to text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.hr_require(array['admin', 'hr', 'reviewer']);
  if p_to not in ('PASSED', 'KEEP_INTERVIEW', 'REJECTED_INTERVIEW') then raise exception 'Invalid status.'; end if;
  perform public.hr_transition(p_id, array['INTERVIEW_SCHEDULED', 'INTERVIEWED', 'KEEP_INTERVIEW'], p_to, p_comment, 'Interview decision');
end $$;

create or replace function public.hr_comment(p_id text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.hr_require(array['admin', 'hr', 'reviewer']);
  if coalesce(trim(p_comment), '') = '' then raise exception 'Comment is empty.'; end if;
  if not exists (select 1 from public.hr_candidates where id = p_id) then raise exception 'Candidate not found.'; end if;
  perform public.hr_log(p_id, 'Comment', null, null, p_comment);
  update public.hr_candidates set updated_at = now(), updated_by = auth.uid() where id = p_id;
end $$;

create or replace function public.hr_reopen(p_id text, p_comment text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.hr_require(array['admin']);
  perform public.hr_transition(p_id,
    array['SHORTLISTED', 'KEEP_SCREENING', 'REJECTED_SCREENING', 'INTERVIEW_SCHEDULED', 'INTERVIEWED',
          'PASSED', 'KEEP_INTERVIEW', 'REJECTED_INTERVIEW'],
    'NEW', p_comment, 'Reopened');
end $$;

-- Called by the app right before it opens a file in the viewer.
create or replace function public.hr_log_view(p_file uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f record;
begin
  perform public.hr_require(array['admin', 'hr', 'reviewer']);
  select candidate_id, name into f from public.hr_files where id = p_file;
  if f is null then raise exception 'File not found.'; end if;
  insert into public.hr_access_log (user_id, user_name, action, candidate_id, file_name)
  values (auth.uid(), public.hr_me_name(), 'view', f.candidate_id, f.name);
end $$;

-- Permanently delete a candidate (e.g. candidate asks for their data to be removed).
-- Returns the storage paths; the app then removes those files from the bucket.
create or replace function public.hr_delete_candidate(p_id text, p_reason text)
returns text[] language plpgsql security definer set search_path = public as $$
declare v_paths text[]; v_name text;
begin
  perform public.hr_require(array['admin']);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Please give a reason for deleting.'; end if;
  select name into v_name from public.hr_candidates where id = p_id;
  if v_name is null then raise exception 'Candidate not found.'; end if;
  select coalesce(array_agg(path), '{}') into v_paths from public.hr_files where candidate_id = p_id;
  insert into public.hr_access_log (user_id, user_name, action, candidate_id, file_name)
  values (auth.uid(), public.hr_me_name(), 'delete_candidate', p_id, v_name || ' — ' || trim(p_reason));
  delete from public.hr_candidates where id = p_id;
  return v_paths;
end $$;

-- ---------- access management (HR admin only) ----------
create or replace function public.hr_list_users()
returns table (user_id uuid, email text, name text, username text, hr_role text, is_owner boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.hr_require(array['admin']);
  return query
    select p.id, p.email::text, p.name::text, p.username::text,
           case when p.role = 'owner' then 'admin' else a.role end,
           (p.role = 'owner')
      from public.profiles p
      left join public.hr_access a on a.user_id = p.id
     where p.role = 'owner' or a.user_id is not null
     order by 6 desc, 3;
end $$;

-- Grant by email or username of an existing account. p_role null = remove access.
create or replace function public.hr_grant(p_login text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  perform public.hr_require(array['admin']);
  select id into v_uid from public.profiles
   where lower(email) = lower(trim(p_login)) or lower(username) = lower(trim(p_login))
   limit 1;
  if v_uid is null then
    raise exception 'No account found for "%". Create the account first (as in the other apps), then add it here.', trim(p_login);
  end if;
  if p_role is null then
    delete from public.hr_access where user_id = v_uid;
  elsif p_role in ('admin', 'hr', 'reviewer') then
    insert into public.hr_access (user_id, role, updated_by, updated_at) values (v_uid, p_role, auth.uid(), now())
    on conflict (user_id) do update set role = excluded.role, updated_by = excluded.updated_by, updated_at = now();
  else
    raise exception 'Invalid role.';
  end if;
end $$;

-- App functions: callable only by signed-in users (the functions check the HR role themselves).
revoke execute on function public.hr_create_candidate(jsonb) from public, anon;
revoke execute on function public.hr_add_file(text, text, text, text, bigint, text, uuid) from public, anon;
revoke execute on function public.hr_screening(text, text, text) from public, anon;
revoke execute on function public.hr_schedule(text, timestamptz, text, text, text) from public, anon;
revoke execute on function public.hr_record_interview(text, text, text) from public, anon;
revoke execute on function public.hr_interview_decision(text, text, text) from public, anon;
revoke execute on function public.hr_comment(text, text) from public, anon;
revoke execute on function public.hr_reopen(text, text) from public, anon;
revoke execute on function public.hr_log_view(uuid) from public, anon;
revoke execute on function public.hr_delete_candidate(text, text) from public, anon;
revoke execute on function public.hr_list_users() from public, anon;
revoke execute on function public.hr_grant(text, text) from public, anon;
grant execute on function public.hr_create_candidate(jsonb) to authenticated;
grant execute on function public.hr_add_file(text, text, text, text, bigint, text, uuid) to authenticated;
grant execute on function public.hr_screening(text, text, text) to authenticated;
grant execute on function public.hr_schedule(text, timestamptz, text, text, text) to authenticated;
grant execute on function public.hr_record_interview(text, text, text) to authenticated;
grant execute on function public.hr_interview_decision(text, text, text) to authenticated;
grant execute on function public.hr_comment(text, text) to authenticated;
grant execute on function public.hr_reopen(text, text) to authenticated;
grant execute on function public.hr_log_view(uuid) to authenticated;
grant execute on function public.hr_delete_candidate(text, text) to authenticated;
grant execute on function public.hr_list_users() to authenticated;
grant execute on function public.hr_grant(text, text) to authenticated;
grant execute on function public.hr_role() to authenticated;
