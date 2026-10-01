-- ============================================================
-- HR / Recruitment — faster Google Drive bridge (one database call per file action)
-- Run AFTER hr_0001 and hr_0002:  Supabase → SQL Editor → New query → paste → Run.
-- Safe to re-run. Changes nothing in existing data. Also blocks uploads to Supabase Storage.
--
-- Before: the bridge made 3 separate calls for every View (role? which file? log it)
--         and 3 for every upload. Each call from Google to Supabase costs ~0.3–0.5 s.
-- Now:    1 call for View, 2 for upload (check + register).
-- ============================================================

-- View / preload: checks the user's HR role, returns the file's location and writes the access log.
-- p_action: 'view' (opened in the viewer) or 'preload' (fetched in advance when the candidate was opened).
create or replace function public.hr_bridge_file(p_file uuid, p_action text default 'view')
returns jsonb language plpgsql security definer set search_path = public as $$
declare f record;
begin
  perform public.hr_require(array['admin', 'hr', 'reviewer']);
  select candidate_id, name, path, mime into f from public.hr_files where id = p_file;
  if f is null then raise exception 'File not found.'; end if;
  insert into public.hr_access_log (user_id, user_name, action, candidate_id, file_name)
  values (auth.uid(), public.hr_me_name(),
          case when p_action = 'preload' then 'preload' else 'view' end,
          f.candidate_id, f.name);
  return jsonb_build_object('path', f.path, 'name', f.name, 'mime', f.mime);
end $$;

-- Upload: checks the user may upload (admin / hr) and returns what the bridge needs for the Drive folder name.
create or replace function public.hr_bridge_candidate(p_candidate text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c record;
begin
  perform public.hr_require(array['admin', 'hr']);
  select id, name, brand, position into c from public.hr_candidates where id = p_candidate;
  if c is null then raise exception 'Candidate not found.'; end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'brand', c.brand, 'position', c.position);
end $$;

revoke execute on function public.hr_bridge_file(uuid, text) from public, anon;
revoke execute on function public.hr_bridge_candidate(text) from public, anon;
grant execute on function public.hr_bridge_file(uuid, text) to authenticated;
grant execute on function public.hr_bridge_candidate(text) to authenticated;

-- Files live ONLY in Google Drive: block any upload to the unused Supabase Storage bucket "hr-files".
drop policy if exists hr_files_obj_insert on storage.objects;

-- Check
select proname from pg_proc where proname in ('hr_bridge_file', 'hr_bridge_candidate') order by 1;
