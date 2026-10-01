/**
 * RECRUITMENT — Google Drive file bridge
 * ---------------------------------------
 * Lets the Recruitment app (GitHub Pages + Supabase) store CVs, portfolios and
 * interview forms in the HR Google account's Drive, in a PRIVATE folder.
 *
 * Every request carries the user's Supabase login token. The bridge asks Supabase
 * (hr_bridge_file / hr_bridge_candidate / hr_role) whether that user may do this
 * before doing anything, so a request without a valid, signed-in HR user is refused.
 * Files are registered in Supabase with the user's own token, so the history shows
 * who uploaded what. Needs supabase/hr_0003_faster_bridge.sql.
 *
 * DEPLOY FROM THE HR GOOGLE ACCOUNT:
 *   1. script.google.com → New project → paste this file → put the folder ID (or its link) in ROOT_FOLDER_ID_RAW below → Save.
 *   2. Deploy → New deployment → type: Web app
 *        Execute as: Me   ·   Who has access: Anyone
 *   3. Authorise when asked, copy the Web app URL, paste it into index.html → DRIVE_BRIDGE_URL.
 *   After editing this file: Deploy → Manage deployments → Edit → Version: New version (URL stays the same).
 *   4. (Faster first open) In the editor pick the function "installKeepWarm" → Run, once.
 *      It pings the bridge every 5 minutes so Google keeps it ready.
 */

const SUPABASE_URL   = 'https://clprrwuizmlsddxmlvrh.supabase.co';
const SUPABASE_KEY   = 'sb_publishable_bY46Emu9VVzYZEhpjxnr2A_9_ranhHt';   // publishable key (same as the app)
const ROOT_FOLDER_ID_RAW = '';  // ID (or full link) of a PRIVATE Drive folder, e.g. "HR – Candidates (Confidential)"
// Accepts a bare ID or a pasted folder link; strips "?..." and anything else that isn't part of the ID.
const ROOT_FOLDER_ID = (function (s) {
  s = String(s || '').trim();
  const m = /folders\/([A-Za-z0-9_-]+)/.exec(s) || /^([A-Za-z0-9_-]+)/.exec(s);
  return m ? m[1] : '';
})(ROOT_FOLDER_ID_RAW);
const MAX_MB = 10;              // max upload per file
const VIEW_MAX_MB = 15;         // max file size the in-app viewer will load
const ALLOWED = /\.(pdf|jpe?g|png|webp)$/i;   // PDF and images only

/* ============================ entry points ============================ */

function doPost(e) {
  try {
    if (!ROOT_FOLDER_ID) throw new Error('Drive bridge is not configured (ROOT_FOLDER_ID is empty).');
    const req = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (!req.token) throw new Error('Not signed in.');
    // Each action makes ONE permission check in Supabase (it used to be up to three).
    let data;
    switch (req.action) {
      case 'upload': data = upload_(req); break;
      case 'view':   data = view_(req); break;
      case 'trash':  data = trash_(req); break;
      default: throw new Error('Unknown action.');
    }
    return json_({ ok: true, data: data });
  } catch (err) {
    return json_({ ok: false, error: String((err && err.message) || err) });
  }
}

// Called every 5 minutes by a timer (see installKeepWarm) so Google keeps the bridge ready.
function keepWarm() {
  if (ROOT_FOLDER_ID) DriveApp.getFolderById(ROOT_FOLDER_ID).getName();
  UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/', { headers: { apikey: SUPABASE_KEY }, muteHttpExceptions: true });
}

// Run once from the editor (pick "installKeepWarm" → Run). Safe to run again; it never adds a duplicate.
function installKeepWarm() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'keepWarm') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('keepWarm').timeBased().everyMinutes(5).create();
  keepWarm();
}

function doGet() {
  return json_({ ok: true, service: 'recruitment-drive-bridge', configured: !!ROOT_FOLDER_ID });
}

/* ============================ actions ============================ */

// req: candidateId, kind (cv|portfolio|interview), name, mime, size, data (base64), interviewId?
function upload_(req) {
  if (['cv', 'portfolio', 'interview'].indexOf(req.kind) < 0) throw new Error('Invalid file type.');
  const name = String(req.name || '').trim();
  if (!name || !ALLOWED.test(name)) throw new Error(name + ': only PDF or image files (JPG, PNG, WebP) are allowed.');
  if (!req.data) throw new Error(name + ': file is empty.');
  if (req.data.length * 0.75 > MAX_MB * 1048576) throw new Error(name + ' is larger than ' + MAX_MB + ' MB.');

  // One call: checks the user is admin/hr and returns the candidate's id, name, brand, position.
  const c = sbRpc_(req.token, 'hr_bridge_candidate', { p_candidate: req.candidateId });

  const folder = candidateFolder_(c);
  markInRoot_(folder.getId());
  const prefix = req.kind === 'cv' ? 'CV - ' : req.kind === 'portfolio' ? 'Portfolio - ' : 'Interview - ';
  const blob = Utilities.newBlob(Utilities.base64Decode(req.data), req.mime || 'application/octet-stream', prefix + safeName_(name));
  const file = folder.createFile(blob);
  markInRoot_(file.getId());

  try {
    sbRpc_(req.token, 'hr_add_file', {
      p_candidate: c.id, p_kind: req.kind, p_name: name, p_path: 'gdrive:' + file.getId(),
      p_size: file.getSize(), p_mime: req.mime || null, p_interview: req.interviewId || null
    });
  } catch (e) {
    file.setTrashed(true);   // don't leave orphan files in Drive
    throw e;
  }
  return { driveId: file.getId() };
}

// req: fileId (hr_files.id), logAs: 'view' (default) or 'preload' (fetched in advance by the app)
function view_(req) {
  // One call: checks the user's HR role, returns the file's location and writes the access log.
  const f = sbRpc_(req.token, 'hr_bridge_file', { p_file: req.fileId, p_action: req.logAs === 'preload' ? 'preload' : 'view' });
  const driveId = String(f.path || '').replace(/^gdrive:/, '');
  if (driveId === f.path) throw new Error('This file is not stored in Google Drive.');
  const file = DriveApp.getFileById(driveId);
  if (!inRoot_(file)) throw new Error('File is outside the recruitment folder.');
  if (file.getSize() > VIEW_MAX_MB * 1048576) throw new Error('File is too large to preview (over ' + VIEW_MAX_MB + ' MB). The HR account can open it in Drive.');
  const blob = file.getBlob();
  return { name: f.name, mime: f.mime || blob.getContentType(), data: Utilities.base64Encode(blob.getBytes()) };
}

// Admin only, after hr_delete_candidate. req: candidateId, paths: ["gdrive:<id>", ...]
function trash_(req) {
  if (sbRpc_(req.token, 'hr_role', {}) !== 'admin') throw new Error('Only admins can delete.');
  let n = 0;
  const folders = {};
  (req.paths || []).forEach(function (p) {
    const id = String(p).replace(/^gdrive:/, '');
    if (id === p) return;
    try {
      const file = DriveApp.getFileById(id);
      if (!inRoot_(file)) return;
      const parents = file.getParents();
      while (parents.hasNext()) { const pf = parents.next(); folders[pf.getId()] = pf; }
      file.setTrashed(true); n++;
    } catch (e) { /* already gone */ }
  });
  // Trash the candidate's own folder once it is empty.
  Object.keys(folders).forEach(function (k) {
    const f = folders[k];
    if (req.candidateId && f.getName().indexOf(req.candidateId + ' ') === 0 && !f.getFiles().hasNext()) f.setTrashed(true);
  });
  return { trashed: n };
}

/* ============================ Drive helpers ============================ */

function candidateFolder_(c) {
  const root = DriveApp.getFolderById(ROOT_FOLDER_ID);
  const bIt = root.getFoldersByName(c.brand);
  const brandFolder = bIt.hasNext() ? bIt.next() : root.createFolder(c.brand);
  const it = brandFolder.searchFolders('title contains "' + c.id + '"');
  while (it.hasNext()) { const f = it.next(); if (f.getName().indexOf(c.id + ' ') === 0) return f; }
  return brandFolder.createFolder(c.id + ' – ' + safeName_(c.name) + ' – ' + safeName_(c.position));
}

// True if the file sits (up to 4 levels deep) inside ROOT_FOLDER_ID.
// Walking up the folders costs several Drive calls, so a positive answer is remembered for 6 hours.
function inRoot_(file) {
  const cache = CacheService.getScriptCache(), key = 'inroot_' + file.getId();
  if (cache.get(key)) return true;
  const ok = inRootWalk_(file);
  if (ok) cache.put(key, '1', 21600);
  return ok;
}
function markInRoot_(id) { CacheService.getScriptCache().put('inroot_' + id, '1', 21600); }
function inRootWalk_(file) {
  let level = [];
  const it = file.getParents();
  while (it.hasNext()) level.push(it.next());
  for (let depth = 0; depth < 4 && level.length; depth++) {
    const next = [];
    for (let i = 0; i < level.length; i++) {
      if (level[i].getId() === ROOT_FOLDER_ID) return true;
      const p = level[i].getParents();
      while (p.hasNext()) next.push(p.next());
    }
    level = next;
  }
  return false;
}

function safeName_(s) { return String(s || '').trim().replace(/[\\/:*?"<>|]+/g, '_').slice(0, 120); }

/* ============================ Supabase helpers ============================ */

function sbHeaders_(token) { return { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + token }; }

function sbRpc_(token, fn, args) {
  const r = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', headers: sbHeaders_(token),
    payload: JSON.stringify(args || {}), muteHttpExceptions: true
  });
  return sbResult_(r);
}

function sbGet_(token, pathAndQuery) {
  const r = UrlFetchApp.fetch(SUPABASE_URL + '/rest/v1/' + pathAndQuery, {
    method: 'get', headers: sbHeaders_(token), muteHttpExceptions: true
  });
  return sbResult_(r) || [];
}

function sbResult_(r) {
  const code = r.getResponseCode(), text = r.getContentText();
  if (code === 401 || /JWT/i.test(code >= 300 ? text : '')) throw new Error('Session ended — please sign in again.');
  if (code >= 300) {
    let msg = text;
    try { const j = JSON.parse(text); msg = j.message || j.error || text; } catch (e) {}
    throw new Error(msg);
  }
  if (!text) return null;
  return JSON.parse(text);
}

function json_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
