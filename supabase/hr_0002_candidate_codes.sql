-- ============================================================
-- HR / Recruitment — candidate codes v2:  <BRAND>-<DEPT>-<NNN>
--   e.g. TE-BOH-001, TE-BOH-002, LB-FOH-001 (numbering per brand + department)
-- Run AFTER hr_0001_init.sql:  Supabase → SQL Editor → New query → paste → Run.
-- Safe to re-run. Existing candidates keep their old HR-xxxxx code.
--
-- Change a code: Table Editor → hr_brands (column "code") or hr_departments.
-- New brands get an automatic code the first time a candidate is added
-- (initials of the first two words, e.g. "Mensho Tokyo" → MT), which you can edit.
-- ============================================================

-- ---------- brand codes ----------
alter table public.hr_brands add column if not exists code text;
create unique index if not exists hr_brands_code_uq on public.hr_brands (upper(code)) where code is not null;

-- Brands from the shared outlets list get their code automatically on first use
-- (Toby's Estate → TE, Lo & Behold → LB) and are stored here with active = false,
-- so they don't show twice in the dropdown.
update public.hr_brands set code = 'MT' where name = 'Mensho Tokyo' and code is null;
update public.hr_brands set code = 'BS' where name = 'Bulgogi Syo'  and code is null;
update public.hr_brands set code = 'SJ' where name = 'Seorae Jib'   and code is null;
update public.hr_brands set code = 'RH' where name = 'Real Hakka'   and code is null;

-- ---------- department codes ----------
create table if not exists public.hr_departments (
  name text primary key,
  code text not null
);
create unique index if not exists hr_departments_code_uq on public.hr_departments (upper(code));
insert into public.hr_departments (name, code) values
  ('FOH', 'FOH'), ('Bar', 'BAR'), ('BOH', 'BOH'), ('Pastry', 'PST'), ('Office', 'OFC')
on conflict (name) do nothing;
alter table public.hr_departments enable row level security;
drop policy if exists hr_departments_read on public.hr_departments;
create policy hr_departments_read on public.hr_departments for select to authenticated using (public.hr_role() is not null);

-- ---------- per-prefix counters ----------
create table if not exists public.hr_id_counters (
  prefix text primary key,
  last   int  not null default 0
);
alter table public.hr_id_counters enable row level security;   -- no policies: functions only

-- ids are now set by hr_create_candidate, not by a column default
alter table public.hr_candidates alter column id drop default;

-- ---------- code helpers (internal) ----------
-- "Toby's Estate Coffee Roasters" → TE, "Lo & Behold" → LB, "Kopi" → KO
create or replace function public.hr_auto_code(p_name text)
returns text language sql immutable as $$
  with w as (
    select array_remove(regexp_split_to_array(upper(regexp_replace(coalesce(p_name, ''), '[''’`]', '', 'g')), '[^A-Z0-9]+'), '') as a
  )
  select case
    when coalesce(array_length(a, 1), 0) = 0 then 'XX'
    when array_length(a, 1) = 1 then left(a[1], 2)
    else left(a[1], 1) || left(a[2], 1)
  end from w
$$;

-- Returns the brand's code, creating a stored one (unique) the first time.
create or replace function public.hr_brand_code(p_brand text)
returns text language plpgsql security definer set search_path = public as $$
declare v text; base text; n int := 1;
begin
  select code into v from public.hr_brands where lower(name) = lower(trim(p_brand)) and code is not null limit 1;
  if v is not null then return upper(v); end if;
  base := public.hr_auto_code(p_brand);
  v := base;
  while exists (select 1 from public.hr_brands where upper(code) = v) loop
    n := n + 1; v := base || n;
  end loop;
  insert into public.hr_brands (name, code, active) values (trim(p_brand), v, false)
  on conflict (name) do update set code = coalesce(public.hr_brands.code, excluded.code)
  returning upper(code) into v;
  return v;
end $$;

create or replace function public.hr_dept_code(p_dept text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select upper(code) from public.hr_departments where lower(name) = lower(trim(p_dept))),
    left(upper(regexp_replace(coalesce(p_dept, ''), '[^A-Za-z0-9]', '', 'g')), 3)
  )
$$;

create or replace function public.hr_next_id(p_brand text, p_dept text)
returns text language plpgsql security definer set search_path = public as $$
declare v_prefix text; v_n int;
begin
  v_prefix := public.hr_brand_code(p_brand) || '-' || public.hr_dept_code(p_dept);
  insert into public.hr_id_counters (prefix, last) values (v_prefix, 1)
  on conflict (prefix) do update set last = public.hr_id_counters.last + 1
  returning last into v_n;
  return v_prefix || '-' || lpad(v_n::text, 3, '0');
end $$;

revoke execute on function public.hr_brand_code(text) from public, anon, authenticated;
revoke execute on function public.hr_dept_code(text) from public, anon, authenticated;
revoke execute on function public.hr_next_id(text, text) from public, anon, authenticated;

-- ---------- create candidate with the new code ----------
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
  v_id := public.hr_next_id(p->>'brand', p->>'department');
  insert into public.hr_candidates
    (id, created_by, name, phone, email, brand, department, position, source, notes, portfolio_link, updated_by)
  values
    (v_id, auth.uid(), trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(lower(trim(p->>'email')), ''),
     trim(p->>'brand'), p->>'department', p->>'position', nullif(trim(p->>'source'), ''),
     nullif(trim(p->>'notes'), ''), nullif(trim(p->>'portfolio_link'), ''), auth.uid());
  perform public.hr_log(v_id, 'Candidate added', null, 'NEW', p->>'notes');
  return v_id;
end $$;
revoke execute on function public.hr_create_candidate(jsonb) from public, anon;
grant execute on function public.hr_create_candidate(jsonb) to authenticated;

-- Check: brand and department codes in use
select name, code, active from public.hr_brands order by code;
select name, code from public.hr_departments order by code;
