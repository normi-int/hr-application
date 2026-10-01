# Recruitment (HR)

Candidate tracker for HR: drop CVs and portfolios, shortlist / keep / reject, schedule and record interviews, then pass / keep / reject. Same stack and accounts as Maintenance and Store Visit: one `index.html` on GitHub Pages, Supabase project `clprrwuizmlsddxmlvrh`.

Live URL (after setup): `https://normi-int.github.io/hr-application/`

## Setup (one time)

1. **Database** — Supabase Dashboard → SQL Editor → New query → paste `supabase/hr_0001_init.sql` → Run, then the same for `supabase/hr_0002_candidate_codes.sql` (candidate codes like `TE-BOH-001`) and `supabase/hr_0003_faster_bridge.sql` (one permission check per file action; blocks Supabase Storage uploads).
   Creates the `hr_*` tables and all permissions. Safe to re-run.
2. **Google Drive (file storage)** — signed in as the **HR Google account**:
   1. In Google Drive, create a folder, e.g. **HR – Candidates (Confidential)**. Keep sharing **Restricted** and share it with nobody. Copy its ID from the URL (`drive.google.com/drive/folders/`**`THIS_PART`**).
   2. Go to script.google.com → **New project** → paste `drive-bridge/Code.gs` → put the folder ID (or the whole folder link) in `ROOT_FOLDER_ID_RAW` → Save.
   3. **Deploy → New deployment → Web app** · Execute as: **Me** · Who has access: **Anyone** → Deploy → authorise.
   4. Copy the Web app URL and paste it into `index.html` → `DRIVE_BRIDGE_URL`.
   Files are stored **only** in Google Drive — never in Supabase Storage (uploads there are blocked by `hr_0003`).
   5. (Faster first open) In the script editor pick **installKeepWarm** → **Run**, once.
3. **GitHub** — create repo `normi-int/hr-application`, upload `index.html` (plus `supabase/` and `drive-bridge/` for reference).
   Settings → Pages → Build and deployment → *Deploy from a branch* → `main` / root → Save.
4. **Access** — sign in as an owner → **👥 Access** → add each person by username or email and pick a role.
   The account must already exist (create it the usual way, as for Maintenance / Store Visit).

## Roles

| Role | Can do |
|---|---|
| **admin** | Everything, plus manage access, reopen closed candidates, delete candidates. Owners are always admin. |
| **hr** | Add candidates, upload files, schedule & record interviews, make decisions, comment. |
| **reviewer** | View everything, shortlist / keep / reject, decide after interview, comment. |

Global admins of the other apps do **not** automatically see candidates — CVs are confidential, so everyone except owners must be added here.

## Flow

New → **Shortlist / Keep for reference / Reject** → Shortlisted → **Schedule interview** → **Record interview** (comments + interview form) → **Pass / Keep for reference / Reject**.
Kept candidates can be revived later; a second interview round is supported. Rejections need a reason. Every step is written to the candidate's history.

## Master data (edit in Supabase → Table Editor)

- **Candidate codes** = `<brand code>-<department code>-<number>`, e.g. `TE-BOH-001`, numbered per brand + department. Brand codes are in `hr_brands.code` (created automatically from the brand's initials the first time it's used — edit there if you want a different one); department codes in `hr_departments` (FOH, BAR, BOH, PST, OFC). Changing a code affects new candidates only.

- **Brands** = brands in the shared outlets list (`app_config` → `outlets`, same list as Maintenance/Store Visit) **plus** `hr_brands` for brands not in that list yet (seeded: Mensho Tokyo, Bulgogi Syo, Seorae Jib, Real Hakka). Duplicates are merged automatically.
- **Positions** = `hr_positions` (department, position, sort, active). Set `active = false` to hide one.

## Files & privacy

- Files are saved in the HR account's **private Drive folder**: `Brand / HR-00001 – Name – Position / CV - …, Portfolio - …, Interview - …`. The HR account can browse them in Drive as normal; nobody else needs (or gets) Drive access.
- How it works: the app sends each file to the Drive bridge (Apps Script, owned by the HR account) together with the user's Supabase login. The bridge asks Supabase for that user's HR role first and refuses anyone without access, then saves the file and registers it under the user's name. Viewing goes the same way, and the bridge only serves files inside the recruitment folder.
- **Speed:** opening a candidate fetches their CV in the background (logged as `preload`), so *View* is usually instant; files opened once stay in memory until sign-out. Photos/screenshots over 500 KB are resized (max 2200 px, JPEG) in the browser before upload, so a 10–15 MB phone photo becomes ~0.5 MB.
- Only **PDF and images (JPG, PNG, WebP)** can be uploaded — both open inside the app, also on phones. Word, PowerPoint, Excel etc. are refused (save them as PDF first). Max 10 MB per upload, 15 MB for preview.
- Every file view is logged in `hr_access_log` (who, when, which candidate, which file; `preload` = fetched in advance when the candidate was opened). Admins can read it in the Table Editor.
- **Delete candidate** (admin) permanently removes the candidate and history, and moves their Drive files to the HR account's Bin (recoverable there for 30 days). The deletion itself stays in `hr_access_log`.
- All database writes go through functions that check the role and the status flow; the tables have no direct write permission. Safe with a public repo — the key in `index.html` is the publishable key, and the database enforces access.

## Storage limit

Files use the HR Google account's free **15 GB** (shared with that account's Gmail and Photos). Nothing is stored in Supabase Storage, so the 1 GB Supabase limit shared with Maintenance and Store Visit is untouched.
If the HR account ever changes, move ownership of the folder and the bridge script to the new account and redeploy — the stored `gdrive:` file IDs stay valid.

## Notes

- Same login as the other apps, and because all apps are on `normi-int.github.io`, signing in to one signs you in to all (and signing out signs out of all).
- Language ID/EN follows the account (`profiles.lang`), same as Maintenance.
- Bump `APP_VERSION` in `index.html` with each change; it shows in the footer.
