
// ══════════════════════════════════════════════
//  STATE
// ══════════════════════════════════════════════
const STATE = {
  mode: 'preview',
  ghPat: '',
  ghOwner: 'Chazdyn', ghRepo: 'Anything', ghBranch: 'main',
  ghConnected: false,
  twitchClientId: 'zd09p34hzxm6jbhvhlcujem2ypid0m',
  twitchClientSecret: '',
  twitchUsername: 'chazdyn',
  twitchToken: null, twitchConnected: false, twitchPollTimer: null,
  isLive: false, liveBadgeOn: false,
  showFullUrls: false,
  config: {},
  clips: [{url:'',title:'',file:null},{url:'',title:'',file:null},{url:'',title:'',file:null}],
  schedule: {
    Mon:{live:false,time:''},
    Tue:{live:true, time:'8pm'},
    Wed:{live:false,time:''},
    Thu:{live:true, time:'8pm'},
    Fri:{live:true, time:'9pm'},
    Sat:{live:true, time:'7pm'},
    Sun:{live:false,time:'Family'}
  },
  assets: [],
  backups: [],
  changelog: [],
  pendingChanges: {}
};

// ══════════════════════════════════════════════
//  INIT
// ══════════════════════════════════════════════
function init() {
  loadFromStorage();
  renderClipsEditor();
  renderScheduleEditor();
  renderChangelog();
  renderBackupsList();
  updateDashboard();
  setPreviewSrc('preview');

  // drag-and-drop on asset zone
  const zone = document.getElementById('asset-drop-zone');
  zone.addEventListener('dragover', e => { e.preventDefault(); zone.classList.add('drag-over'); });
  zone.addEventListener('dragleave', () => zone.classList.remove('drag-over'));
  zone.addEventListener('drop', e => {
    e.preventDefault(); zone.classList.remove('drag-over');
    handleFileDrop(e.dataTransfer.files);
  });
}

function loadFromStorage() {
  const saved = localStorage.getItem('controldyn_state');
  if (saved) {
    try {
      const s = JSON.parse(saved);
      const { ghPat, ghOwner, ghRepo, ghBranch, twitchClientId, twitchClientSecret, twitchUsername, ...rest } = s;
      Object.assign(STATE, rest);
    } catch(e) {}
  }
}

function saveToStorage() {
  const toSave = {...STATE};
  // don't save token in memory — just creds
  delete toSave.twitchToken;
  localStorage.setItem('controldyn_state', JSON.stringify(toSave));
}

// ══════════════════════════════════════════════
//  NAVIGATION
// ══════════════════════════════════════════════
function showSection(id) {
  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  const sec = document.getElementById('section-' + id);
  if (sec) sec.classList.add('active');
  // highlight nav — exact match to avoid 'thicc' matching 'thicc-settings' etc.
  document.querySelectorAll('.nav-item').forEach(n => {
    const oc = n.getAttribute('onclick') || '';
    const match = oc.match(/showSection\('([^']+)'\)/);
    if (match && match[1] === id) n.classList.add('active');
  });
  if (id === 'assets') refreshAssets();
  if (id === 'thicc') renderTHICC();
  if (id === 'index-editor') loadIndexEditor(false);
}

// ══════════════════════════════════════════════
//  MODE TOGGLE
// ══════════════════════════════════════════════
function setMode(mode) {
  STATE.mode = mode;
  document.getElementById('btn-preview-mode').classList.toggle('active', mode === 'preview');
  document.getElementById('btn-live-mode').classList.toggle('active', mode === 'live');
}

// ══════════════════════════════════════════════
//  FIELD CHANGES
// ══════════════════════════════════════════════
function onFieldChange(key, value) {
  STATE.pendingChanges[key] = value;
  logChange('edit', `${key} updated`, typeof value === 'string' ? value.substring(0, 60) : JSON.stringify(value).substring(0, 60));
}

// ══════════════════════════════════════════════
//  SAVE SECTIONS (writes to localStorage config, applies to site)
// ══════════════════════════════════════════════
function saveSection(section) {
  Object.assign(STATE.config, STATE.pendingChanges);
  markDraftUpdated();
  STATE.pendingChanges = {};
  // apply clips & schedule from editors
  if (section === 'clips') STATE.config.clips = STATE.clips;
  if (section === 'schedule') STATE.config.schedule = STATE.schedule;
  if (section === 'hero') STATE.config.isLive = document.getElementById('hero-live-badge').checked;
  localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
  saveToStorage();
  toast('Changes saved to preview', 'success');
  logChange('edit', section + ' section saved');
  updateDashboard();
}

// ══════════════════════════════════════════════
//  GITHUB API
// ══════════════════════════════════════════════
function ghHeaders() {
  return { 'Authorization': 'Bearer ' + STATE.ghPat, 'Content-Type': 'application/json', 'Accept': 'application/vnd.github.v3+json' };
}
function ghBase() { return `https://api.github.com/repos/${STATE.ghOwner}/${STATE.ghRepo}`; }

function getLocalIndexPath() {
  return location.pathname.includes('/assets/') ? '../index.html' : 'index.html';
}
function normalizeSitePath(path) {
  if (!path) return path;
  if (/^(https?:|data:|blob:|mailto:|tel:|#)/i.test(path)) return path;
  return path.replace(/^\.\.\//, '');
}
function markDraftUpdated() {
  STATE.config = STATE.config || {};
  STATE.config._draftUpdated = new Date().toISOString();
}
function buildConfigSeedScript(config) {
  const configJsonStr = JSON.stringify(config || {});
  const payload = JSON.stringify(configJsonStr);
  const _sc = '\u003c/script>';
  return '\n<script data-controldyn>(function(){try{var live=JSON.parse(' + payload + ');var raw=localStorage.getItem("chazdyn_config");var cur=raw?JSON.parse(raw):null;var liveTime=Date.parse(live._lastDeploy||0)||0;var draftTime=cur?(Date.parse(cur._draftUpdated||0)||0):0;if(!cur||draftTime<=liveTime){localStorage.setItem("chazdyn_config",JSON.stringify(live));}}catch(e){localStorage.setItem("chazdyn_config",' + payload + ');}})();' + _sc;
}

async function saveGitHubCreds() {
  // Use input field value if one was entered
  const input = document.getElementById('gh-pat-input');
  if (input && input.value.trim()) STATE.ghPat = input.value.trim();
  try {
    const r = await fetch(ghBase(), { headers: ghHeaders() });
    if (r.ok) {
      updateGhStatus(true);
      document.getElementById('gh-reauth').style.display = 'none';
      if (input) input.value = '';
      refreshAssets(); syncControlDynFromLive();
    } else {
      updateGhStatus(false);
      document.getElementById('gh-reauth').style.display = 'block';
    }
  } catch(e) {
    updateGhStatus(false);
    document.getElementById('gh-reauth').style.display = 'block';
  }
}

function updateGhStatus(ok) {
  STATE.ghConnected = ok;
  const el = document.getElementById('gh-status');
  if (el) { el.className = 'conn-badge ' + (ok ? 'connected' : 'disconnected'); el.innerHTML = `<span class="conn-dot"></span>${ok ? 'Connected' : 'Not connected'}`; }
  setDot('cdot-gh', ok ? 'ok' : 'err');
  saveToStorage();
}

// Get file SHA from GitHub
async function getFileSha(path) {
  try {
    const r = await fetch(`${ghBase()}/contents/${path}?ref=${STATE.ghBranch}`, { headers: ghHeaders() });
    if (!r.ok) return null;
    const d = await r.json();
    return d.sha;
  } catch(e) { return null; }
}

// Commit a file to GitHub
async function commitFile(path, content, message, isBinary = false) {
  if (!STATE.ghConnected) { toast('Connect GitHub first', 'error'); return false; }
  // Strip emoji — some PAT permission levels reject emoji in commit messages
  const safeMsg = message.replace(/[\u{1F000}-\u{1FFFF}\u{2600}-\u{27BF}]/gu, '').trim();
  try {
    const sha = await getFileSha(path);
    const encoded = isBinary ? content : btoa(unescape(encodeURIComponent(content)));
    const body = { message: safeMsg, branch: STATE.ghBranch, content: encoded };
    if (sha) body.sha = sha;
    const r = await fetch(`${ghBase()}/contents/${path}`, {
      method: 'PUT', headers: ghHeaders(), body: JSON.stringify(body)
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      const detail = err.message || r.statusText || r.status;
      toast(`GitHub error ${r.status}: ${detail}`, 'error');
      logChange('error', `commitFile failed (${r.status}): ${detail}`);
      return false;
    }
    return true;
  } catch(e) {
    toast('Commit error: ' + e.message, 'error');
    logChange('error', 'commitFile exception: ' + e.message);
    return false;
  }
}

// Read a file from GitHub
async function readFile(path) {
  try {
    const r = await fetch(`${ghBase()}/contents/${path}?ref=${STATE.ghBranch}`, { headers: ghHeaders() });
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      toast(`Cannot read ${path}: ${err.message || r.status}`, 'error');
      return null;
    }
    const d = await r.json();
    return decodeURIComponent(escape(atob(d.content.replace(/\n/g,''))));
  } catch(e) {
    toast('Read error: ' + e.message, 'error');
    return null;
  }
}


// ══════════════════════════════════════════════
//  LIVE DATA SYNC
// ══════════════════════════════════════════════
function extractScriptPayload(html, attr, storageKey) {
  const re = new RegExp("<script\\s+" + attr + "[^>]*>\\s*localStorage\\.setItem\\([\"']" + storageKey + "[\"']\\s*,\\s*([\\s\\S]*?)\\);?\\s*<\\/script>", 'i');
  const m = html.match(re);
  if (!m) return null;
  try { return JSON.parse(JSON.parse(m[1])); }
  catch(e) {
    try { return JSON.parse(m[1]); }
    catch(_) { return null; }
  }
}

function extractDefaultMembers(html) {
  const m = html.match(/const\s+DEFAULT_MEMBERS\s*=\s*(\[[\s\S]*?\]);/);
  if (!m) return null;
  try { return (new Function('return ' + m[1]))(); }
  catch(e) { console.warn('Could not parse DEFAULT_MEMBERS:', e); return null; }
}

async function syncControlDynFromLive() {
  if (!STATE.ghConnected) return;
  try {
    const [indexHtml, thiccHtml] = await Promise.all([readFile('index.html'), readFile('thicc/index.html')]);
    let changed = false;
    if (indexHtml) {
      const liveConfig = extractScriptPayload(indexHtml, 'data-controldyn', 'chazdyn_config');
      if (liveConfig && typeof liveConfig === 'object') {
        STATE.config = {...STATE.config, ...liveConfig};
        localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
        applyConfigToEditor(STATE.config);
        changed = true;
      }
    }
    if (thiccHtml) {
      const liveMembers = extractScriptPayload(thiccHtml, 'data-thicc-deploy', 'chazdyn_thicc') || (STATE.config && Array.isArray(STATE.config.thiccMembers) ? STATE.config.thiccMembers : null) || extractDefaultMembers(thiccHtml);
      if (Array.isArray(liveMembers) && liveMembers.length) {
        localStorage.setItem('chazdyn_thicc', JSON.stringify(liveMembers));
        renderTHICC();
        changed = true;
      }
    }
    if (changed) {
      saveToStorage();
      updateDashboard();
      toast('Pulled current live fields into Control.Dyn', 'success');
      logChange('sync', 'Loaded current live site fields');
    }
  } catch(e) {
    console.warn('Live sync failed:', e);
    toast('Could not pull live fields: ' + e.message, 'warning');
  }
}

function setVal(id, value) {
  const el = document.getElementById(id);
  if (!el || value === undefined || value === null) return;
  if (el.type === 'checkbox') el.checked = !!value;
  else el.value = Array.isArray(value) ? value.join(', ') : value;
}

function applyConfigToEditor(c) {
  setVal('hero-live-badge', c.isLive);
  setVal('hero-eyebrow', c.heroEyebrow);
  setVal('hero-tagline', c.heroTagline);
  setVal('hero-twitch-url', c.twitchUrl);
  setVal('hero-discord-url', c.discordUrl);
  setVal('about-avatar-url', c.avatarUrl);
  setVal('about-short-bio', c.aboutBio);
  setVal('about-long-bio', c.aboutLong);
  setVal('about-tags', c.aboutTags);
  setVal('music-video-url', c.musicVideoUrl);
  setVal('music-yt-url', c.musicYtUrl);
  setVal('music-spotify-url', c.musicSpotUrl);
  setVal('music-sc-url', c.musicScUrl);
  setVal('soc-twitch', c.twitchUrl);
  setVal('soc-discord', c.discordUrl);
  setVal('soc-tiktok', c.tiktokUrl);
  setVal('soc-insta', c.instaUrl);
  setVal('soc-thicc', c.thiccUrl);
  setVal('theme-green', c.accentColor);
  setVal('theme-green-hex', c.accentColor);
  setVal('theme-cyan', c.accent2Color);
  setVal('theme-cyan-hex', c.accent2Color);
  setVal('theme-bg', c.bgColor);
  setVal('theme-bg-hex', c.bgColor);
  setVal('theme-display-font', c.displayFont);
  setVal('theme-body-font', c.bodyFont);
  setVal('thicc-desc', c.thiccDesc);
  setVal('thicc-game', c.thiccGame);
  setVal('thicc-founded', c.thiccFounded);
  setVal('thicc-tag', c.thiccTag);
  setVal('thicc-fullname', c.thiccFullname);
  if (Array.isArray(c.clips)) { STATE.clips = c.clips; renderClipsEditor(); }
  if (c.schedule) { STATE.schedule = c.schedule; renderScheduleEditor(); }
}


// ══════════════════════════════════════════════
//  INDEX.HTML DIRECT EDITOR
// ══════════════════════════════════════════════
async function loadIndexEditor(showToast = true) {
  const ta = document.getElementById('index-html-editor');
  if (!ta) return;
  if (ta.value.trim() && ta.dataset.loaded === '1' && showToast === false) return;
  if (!STATE.ghConnected) {
    try {
      const r = await fetch(getLocalIndexPath() + '?v=' + Date.now());
      ta.value = await r.text();
      ta.dataset.loaded = '1';
      if (showToast) toast('Loaded local index.html preview copy', 'success');
    } catch(e) { if (showToast) toast('Could not load local index.html: ' + e.message, 'error'); }
    return;
  }
  const html = await readFile('index.html');
  if (!html) return;
  ta.value = html;
  ta.dataset.loaded = '1';
  if (showToast) toast('Loaded index.html from GitHub', 'success');
}

function previewIndexEditor() {
  const ta = document.getElementById('index-html-editor');
  if (!ta || !ta.value.trim()) { toast('Load or paste index.html first', 'warning'); return; }
  const blob = new Blob([ta.value], { type: 'text/html' });
  const url = URL.createObjectURL(blob);
  const frame = document.getElementById('preview-frame');
  if (frame) frame.src = url;
  const bar = document.getElementById('preview-url-bar');
  if (bar) bar.textContent = 'Unsaved index.html editor preview';
  showSection('preview');
}

async function saveIndexEditor() {
  const ta = document.getElementById('index-html-editor');
  if (!ta || !ta.value.trim()) { toast('Nothing to save', 'warning'); return; }
  if (!STATE.ghConnected) { toast('Connect GitHub first in Connections', 'error'); return; }
  await createBackup('Pre-index-editor backup');
  const ok = await commitFile('index.html', ta.value, 'Control.Dyn index.html editor save: ' + new Date().toLocaleString());
  if (ok) {
    toast('index.html saved to GitHub', 'success');
    logChange('deploy', 'index.html saved from direct editor');
    setPreviewSrc('preview');
  }
}

// ══════════════════════════════════════════════
//  DEPLOY
// ══════════════════════════════════════════════
async function deployToLive() {
  // Auto-save any pending editor state before deploying
  Object.assign(STATE.config, STATE.pendingChanges);
  STATE.pendingChanges = {};
  STATE.config.clips = STATE.clips;
  STATE.config.schedule = STATE.schedule;
  if (document.getElementById('thicc-roster-editor')) {
    const thiccMembers = collectTHICC();
    STATE.config.thiccMembers = thiccMembers;
    localStorage.setItem('chazdyn_thicc', JSON.stringify(thiccMembers));
  }
  STATE.config.isLive = STATE.liveBadgeOn || !!(document.getElementById('hero-live-badge') && document.getElementById('hero-live-badge').checked);
  STATE.config._lastDeploy = new Date().toISOString();
  localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
  saveToStorage();
  if (!STATE.ghConnected) { toast('Connect GitHub first in Connections', 'error'); return; }
  toast('Creating backup...', 'info');
  await createBackup('Pre-deploy backup');

  toast('Deploying to GitHub...', 'info');
  try {
    // Read current index.html and inject config
    const html = await readFile('index.html');
    if (!html) { toast('Could not read index.html from GitHub', 'error'); return; }

    // Inject config as a guarded localStorage seed. It will not clobber newer Control.Dyn draft edits on refresh.
    const configScript = buildConfigSeedScript(STATE.config);
    let updated = html.replace(/<script data-controldyn>[\s\S]*?<\/script>/,'');
    updated = updated.replace('</head>', configScript + '</head>');

    const ok = await commitFile('index.html', updated, 'Control.Dyn deploy: ' + new Date().toLocaleString());
    if (ok) {
      toast('Deployed successfully!', 'success');
      logChange('deploy', 'Deployed to live', new Date().toLocaleString());
      saveToStorage(); updateDashboard();
    } else {
      toast('Deploy failed — check GitHub permissions', 'error');
      logChange('error', 'Deploy failed');
    }
  } catch(e) { toast('Deploy error: ' + e.message, 'error'); logChange('error', e.message); }
}

async function forceDeploy() {
  if (!STATE.ghConnected) { toast('Connect GitHub first', 'error'); return; }
  try {
    const html = await readFile('index.html');
    if (!html) return;
    const ok = await commitFile('index.html', html + ' ', '♻️ Force refresh: ' + new Date().toLocaleString());
    if (ok) toast('Refresh triggered', 'success');
  } catch(e) { toast('Error: ' + e.message, 'error'); }
}

// ══════════════════════════════════════════════
//  BACKUPS
// ══════════════════════════════════════════════
async function createBackup(label = 'Manual backup') {
  if (!STATE.ghConnected) { toast('Connect GitHub to create cloud backups', 'warning'); createLocalBackup(label); return; }
  try {
    const html = await readFile('index.html');
    if (!html) { createLocalBackup(label); return; }
    const ts = new Date().toISOString().replace(/[:.]/g,'-').slice(0,19);
    const path = `backups/${ts}.html`;
    const ok = await commitFile(path, html, `💾 Backup: ${label} — ${ts}`);
    if (ok) {
      const entry = { ts: new Date().toISOString(), label, path };
      STATE.backups.unshift(entry);
      saveToStorage(); renderBackupsList(); updateDashboard();
      toast('Backup saved to repo', 'success');
      logChange('backup', label, path);
    }
  } catch(e) { createLocalBackup(label); }
}

function createLocalBackup(label) {
  const entry = { ts: new Date().toISOString(), label, local: true, config: JSON.stringify(STATE.config) };
  STATE.backups.unshift(entry);
  if (STATE.backups.length > 30) STATE.backups.pop();
  saveToStorage(); renderBackupsList(); updateDashboard();
  toast('Backup saved locally', 'info');
  logChange('backup', label + ' (local)');
}

async function restoreBackup(idx) {
  const b = STATE.backups[idx];
  if (!b) return;
  if (!confirm(`Restore backup from ${new Date(b.ts).toLocaleString()}? This will overwrite the current live site.`)) return;
  if (b.local) {
    STATE.config = JSON.parse(b.config);
    localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
    toast('Local config restored — deploy to push live', 'success');
    logChange('restore', 'Restored local backup: ' + b.label);
    return;
  }
  try {
    const html = await readFile(b.path);
    if (!html) { toast('Could not read backup', 'error'); return; }
    const ok = await commitFile('index.html', html, `⏮ Rollback to: ${b.label} ${b.ts}`);
    if (ok) { toast('Rollback complete!', 'success'); logChange('restore', 'Rolled back to ' + b.label, b.ts); }
    else toast('Rollback failed', 'error');
  } catch(e) { toast('Error: ' + e.message, 'error'); }
}

function renderBackupsList() {
  const el = document.getElementById('backups-list');
  if (!STATE.backups.length) { el.innerHTML = '<div style="color:var(--muted);font-size:0.82rem">No backups yet.</div>'; return; }
  el.innerHTML = STATE.backups.map((b, i) => `
    <div class="backup-row">
      <div>
        <div class="backup-time">${new Date(b.ts).toLocaleString()}</div>
        <div style="font-size:0.72rem;color:var(--muted)">${b.label}${b.local?' <span style="color:var(--amber)">(local)</span>':' <span style="color:var(--cyan)">(GitHub)</span>'}</div>
      </div>
      <button class="qa-btn ghost" onclick="restoreBackup(${i})">Restore</button>
    </div>
  `).join('');
  document.getElementById('dash-backup-count').textContent = STATE.backups.length;
}


// ══════════════════════════════════════════════
//  IMAGE PREVIEW + CROPPER
// ══════════════════════════════════════════════
const CROP = {
  file:null, img:null, objectUrl:null, onDone:null, mode:'square', aspect:1,
  canvas:null, ctx:null, preview:null, pctx:null, crop:{x:0,y:0,w:0,h:0},
  baseScale:1, zoom:1, scale:1, imgX:0, imgY:0, dragging:false, lastX:0, lastY:0
};
const CROP_MODES = {
  square: { aspect:1, label:'Square 1:1' },
  circle: { aspect:1, label:'Circular' },
  portrait: { aspect:0.8, label:'Portrait 4:5' },
  wide: { aspect:16/9, label:'Wide 16:9' },
  original: { aspect:'original', label:'Original ratio' }
};
function isCropCapableImage(file) { return file && file.type && /^image\/(png|jpe?g|webp)$/i.test(file.type); }
function safeBaseName(file) { return (file.name || 'image').replace(/\.[^.]+$/, '').replace(/[^a-z0-9-_]+/gi, '-').replace(/-+/g, '-').replace(/^-|-$/g, '') || 'image'; }
function croppedFileName(file) { const stamp = new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0,14); return `${safeBaseName(file)}-cropped-${CROP.mode}-${stamp}${CROP.mode === 'circle' ? '.png' : '.jpg'}`; }
function openImageCropper(file, onDone) {
  const modal = document.getElementById('crop-modal');
  const canvas = document.getElementById('crop-canvas');
  const preview = document.getElementById('crop-output-preview');
  const sourcePreview = document.getElementById('crop-source-preview');
  if (!modal || !canvas || !preview || !sourcePreview) { onDone(file); return; }
  CROP.file = file; CROP.onDone = onDone; CROP.canvas = canvas; CROP.ctx = canvas.getContext('2d'); CROP.preview = preview; CROP.pctx = preview.getContext('2d'); CROP.zoom = 1; CROP.mode = 'square'; CROP.aspect = 1;
  document.getElementById('crop-zoom').value = '1';
  document.getElementById('crop-aspect').value = 'square';
  document.getElementById('crop-file-label').textContent = file.name;
  document.getElementById('crop-output-label').textContent = CROP_MODES.square.label;
  const img = new Image();
  CROP.objectUrl = URL.createObjectURL(file);
  sourcePreview.src = CROP.objectUrl;
  img.onload = () => { CROP.img = img; modal.classList.remove('hidden'); modal.setAttribute('aria-hidden','false'); sizeCropCanvas(); setupCropEvents(); resetCropperView(); };
  img.onerror = () => { toast('Could not read image for cropping', 'error'); closeImageCropper(false); onDone(file); };
  img.src = CROP.objectUrl;
}
function closeImageCropper(useOriginal) {
  const modal = document.getElementById('crop-modal');
  if (modal) { modal.classList.add('hidden'); modal.setAttribute('aria-hidden','true'); }
  const original = CROP.file; const cb = CROP.onDone;
  if (CROP.objectUrl) URL.revokeObjectURL(CROP.objectUrl);
  const srcPrev = document.getElementById('crop-source-preview'); if (srcPrev) srcPrev.removeAttribute('src');
  CROP.file = CROP.img = CROP.objectUrl = CROP.onDone = null;
  if (useOriginal && cb && original) cb(original);
}
function confirmOriginalImage() { closeImageCropper(true); }
function sizeCropCanvas() {
  const c = CROP.canvas; if (!c) return;
  const w = Math.min(920, Math.max(420, Math.floor(window.innerWidth * 0.68)));
  c.width = w; c.height = Math.min(560, Math.max(320, Math.floor(window.innerHeight * 0.56)));
  updateCropBox();
}
function currentAspect() { return CROP.aspect === 'original' && CROP.img ? CROP.img.naturalWidth / CROP.img.naturalHeight : CROP.aspect; }
function updateCropBox() {
  const c = CROP.canvas; if (!c || !CROP.img) return;
  const a = currentAspect(); let w = c.width * 0.72; let h = w / a;
  if (h > c.height * 0.74) { h = c.height * 0.74; w = h * a; }
  CROP.crop = { x:(c.width-w)/2, y:(c.height-h)/2, w, h };
}
function setupCropEvents() {
  const c = CROP.canvas; if (c.dataset.cropReady) return; c.dataset.cropReady = '1';
  const point = (ev) => { const r = c.getBoundingClientRect(); const t = ev.touches && ev.touches[0]; const x = (t ? t.clientX : ev.clientX) - r.left; const y = (t ? t.clientY : ev.clientY) - r.top; return { x:x*(c.width/r.width), y:y*(c.height/r.height) }; };
  const down = ev => { ev.preventDefault(); const p = point(ev); CROP.dragging = true; CROP.lastX = p.x; CROP.lastY = p.y; c.classList.add('dragging'); };
  const move = ev => { if (!CROP.dragging) return; ev.preventDefault(); const p = point(ev); CROP.imgX += p.x - CROP.lastX; CROP.imgY += p.y - CROP.lastY; CROP.lastX = p.x; CROP.lastY = p.y; constrainCropImage(); drawCropper(); };
  const up = () => { CROP.dragging = false; c.classList.remove('dragging'); };
  c.addEventListener('mousedown', down); c.addEventListener('touchstart', down, {passive:false});
  window.addEventListener('mousemove', move); window.addEventListener('touchmove', move, {passive:false});
  window.addEventListener('mouseup', up); window.addEventListener('touchend', up);
  window.addEventListener('resize', () => { if (CROP.img && !document.getElementById('crop-modal')?.classList.contains('hidden')) { sizeCropCanvas(); resetCropperView(); } });
}
function resetCropperView() {
  if (!CROP.img || !CROP.canvas) return; updateCropBox();
  const {w,h,x,y} = CROP.crop;
  CROP.baseScale = Math.max(w/CROP.img.naturalWidth, h/CROP.img.naturalHeight);
  CROP.scale = CROP.baseScale * CROP.zoom;
  CROP.imgX = x + (w - CROP.img.naturalWidth*CROP.scale)/2;
  CROP.imgY = y + (h - CROP.img.naturalHeight*CROP.scale)/2;
  constrainCropImage(); drawCropper();
}
function setCropMode(value) {
  const mode = CROP_MODES[value] ? value : 'square';
  CROP.mode = mode; CROP.aspect = CROP_MODES[mode].aspect;
  document.getElementById('crop-output-label').textContent = CROP_MODES[mode].label;
  resetCropperView();
}
function setCropZoom(value) {
  if (!CROP.img) return; const old = CROP.scale || 1;
  CROP.zoom = Number(value) || 1; CROP.scale = CROP.baseScale * CROP.zoom;
  const cx = CROP.crop.x + CROP.crop.w/2; const cy = CROP.crop.y + CROP.crop.h/2;
  CROP.imgX = cx - (cx-CROP.imgX)*(CROP.scale/old);
  CROP.imgY = cy - (cy-CROP.imgY)*(CROP.scale/old);
  constrainCropImage(); drawCropper();
}
function constrainCropImage() {
  const iw = CROP.img.naturalWidth*CROP.scale, ih = CROP.img.naturalHeight*CROP.scale; const {x,y,w,h} = CROP.crop;
  if (iw <= w) CROP.imgX = x+(w-iw)/2; else { if (CROP.imgX > x) CROP.imgX = x; if (CROP.imgX+iw < x+w) CROP.imgX = x+w-iw; }
  if (ih <= h) CROP.imgY = y+(h-ih)/2; else { if (CROP.imgY > y) CROP.imgY = y; if (CROP.imgY+ih < y+h) CROP.imgY = y+h-ih; }
}
function drawCropPath(ctx, x, y, w, h) {
  ctx.beginPath();
  if (CROP.mode === 'circle') ctx.arc(x + w/2, y + h/2, Math.min(w,h)/2, 0, Math.PI*2);
  else ctx.rect(x,y,w,h);
}
function drawCropper() {
  const c = CROP.canvas, ctx = CROP.ctx; if (!c || !ctx || !CROP.img) return;
  ctx.clearRect(0,0,c.width,c.height); ctx.fillStyle = '#05070a'; ctx.fillRect(0,0,c.width,c.height);
  ctx.drawImage(CROP.img, CROP.imgX, CROP.imgY, CROP.img.naturalWidth*CROP.scale, CROP.img.naturalHeight*CROP.scale);
  const {x,y,w,h} = CROP.crop;
  ctx.save(); ctx.fillStyle = 'rgba(0,0,0,0.58)';
  ctx.beginPath(); ctx.rect(0,0,c.width,c.height); drawCropPath(ctx,x,y,w,h); ctx.fill('evenodd');
  ctx.strokeStyle = '#39ff14'; ctx.lineWidth = 2; ctx.setLineDash([8,6]); drawCropPath(ctx,x,y,w,h); ctx.stroke(); ctx.setLineDash([]);
  if (CROP.mode !== 'circle') { ctx.strokeStyle = 'rgba(255,255,255,0.45)'; ctx.lineWidth = 1; ctx.strokeRect(x+w/3,y,w/3,h); ctx.strokeRect(x,y+h/3,w,h/3); }
  ctx.restore(); drawCropPreview();
}
function getCropSourceRect() {
  const {x,y,w,h} = CROP.crop;
  const sx = Math.max(0, (x-CROP.imgX)/CROP.scale);
  const sy = Math.max(0, (y-CROP.imgY)/CROP.scale);
  const sw = Math.min(CROP.img.naturalWidth-sx, w/CROP.scale);
  const sh = Math.min(CROP.img.naturalHeight-sy, h/CROP.scale);
  return {sx, sy, sw, sh};
}
function drawCropPreview() {
  const p = CROP.preview, ctx = CROP.pctx; if (!p || !ctx || !CROP.img) return;
  const a = currentAspect(); let pw = 240, ph = Math.round(pw / a); if (ph > 240) { ph = 240; pw = Math.round(ph * a); }
  p.width = Math.max(80, pw); p.height = Math.max(80, ph);
  ctx.clearRect(0,0,p.width,p.height);
  if (CROP.mode !== 'circle') { ctx.fillStyle = '#000'; ctx.fillRect(0,0,p.width,p.height); }
  ctx.save(); if (CROP.mode === 'circle') { ctx.beginPath(); ctx.arc(p.width/2,p.height/2,Math.min(p.width,p.height)/2,0,Math.PI*2); ctx.clip(); }
  const {sx,sy,sw,sh} = getCropSourceRect(); ctx.drawImage(CROP.img, sx, sy, sw, sh, 0, 0, p.width, p.height); ctx.restore();
}
async function confirmImageCrop() {
  if (!CROP.img || !CROP.file || !CROP.onDone) return;
  const {w,h} = CROP.crop; const {sx,sy,sw,sh} = getCropSourceRect();
  const maxLong = 1600; let outW = Math.round(w), outH = Math.round(h);
  const mult = Math.min(maxLong / Math.max(outW,outH), 4); outW = Math.max(320, Math.round(outW*mult)); outH = Math.max(320, Math.round(outH*mult));
  const out = document.createElement('canvas'); out.width = outW; out.height = outH; const octx = out.getContext('2d');
  if (CROP.mode !== 'circle') { octx.fillStyle = '#000'; octx.fillRect(0,0,outW,outH); }
  octx.save(); if (CROP.mode === 'circle') { octx.beginPath(); octx.arc(outW/2,outH/2,Math.min(outW,outH)/2,0,Math.PI*2); octx.clip(); }
  octx.drawImage(CROP.img, sx, sy, sw, sh, 0, 0, outW, outH); octx.restore();
  const original = CROP.file; const cb = CROP.onDone; const mime = CROP.mode === 'circle' ? 'image/png' : 'image/jpeg'; const quality = CROP.mode === 'circle' ? undefined : 0.92;
  out.toBlob(blob => { if (!blob) { toast('Crop failed; uploading original image instead', 'warning'); closeImageCropper(true); return; } const cropped = new File([blob], croppedFileName(original), {type:mime, lastModified:Date.now()}); closeImageCropper(false); cb(cropped); }, mime, quality);
}

// ══════════════════════════════════════════════
//  ASSETS
// ══════════════════════════════════════════════
async function refreshAssets() {
  STATE.showFullUrls = document.getElementById('show-full-urls').checked;
  if (!STATE.ghConnected) { document.getElementById('assets-grid').innerHTML = '<div style="color:var(--muted);font-size:0.82rem;grid-column:1/-1">Connect GitHub to browse assets.</div>'; return; }
  try {
    const r = await fetch(`${ghBase()}/contents/assets?ref=${STATE.ghBranch}`, { headers: ghHeaders() });
    if (!r.ok) { toast('Could not load assets', 'error'); return; }
    STATE.assets = await r.json();
    renderAssets();
  } catch(e) { toast('Error loading assets: ' + e.message, 'error'); }
}

function renderAssets() {
  const grid = document.getElementById('assets-grid');
  if (!STATE.assets.length) { grid.innerHTML = '<div style="color:var(--muted);font-size:0.82rem;grid-column:1/-1">No assets found in assets/ folder.</div>'; return; }
  const rawBase = `https://raw.githubusercontent.com/${STATE.ghOwner}/${STATE.ghRepo}/${STATE.ghBranch}/`;
  grid.innerHTML = STATE.assets.filter(a => a.type === 'file').map(a => {
    const isImage = /\.(jpe?g|png|gif|webp|svg)$/i.test(a.name);
    const isVideo = /\.(mp4|webm|mov|avi)$/i.test(a.name);
    const rawUrl  = rawBase + a.path;
    const display = STATE.showFullUrls ? rawUrl : a.name;
    const thumb   = isImage ? `<img class="asset-thumb" src="${rawUrl}" loading="lazy" alt="${a.name}" />` :
                    isVideo ? `<div class="asset-thumb-placeholder">🎬</div>` :
                              `<div class="asset-thumb-placeholder">📄</div>`;
    return `
      <div class="asset-card">
        ${thumb}
        <div class="asset-info">
          <div class="asset-name" title="${a.name}">${a.name}</div>
          <div class="asset-url" title="${display}">${display}</div>
        </div>
        <div class="asset-actions">
          <button class="asset-btn" onclick="copyToClipboard('${STATE.showFullUrls ? rawUrl : a.name}')">Copy</button>
          <button class="asset-btn" onclick="openAssetSelector(null,{standalone:true,preferred:'${isVideo?'video':isImage?'image':'file'}'})">Select</button>
          <button class="asset-btn delete" onclick="deleteAsset('${a.path}','${a.sha}')">Delete</button>
        </div>
      </div>`;
  }).join('');
}


function assetDisplayPath(asset, opts = {}) {
  const rawUrl = `https://raw.githubusercontent.com/${STATE.ghOwner}/${STATE.ghRepo}/${STATE.ghBranch}/${asset.path}`;
  if (STATE.showFullUrls) return rawUrl;
  if (opts.thicc) return '../assets/' + asset.name;
  return 'assets/' + asset.name;
}

async function openAssetSelector(target, opts = {}) {
  if (!STATE.ghConnected) { toast('Connect GitHub first to browse assets', 'error'); return; }
  if (!STATE.assets || !STATE.assets.length) await refreshAssets();
  const targetInput = typeof target === 'string' ? document.querySelector(target) : target;
  const files = (STATE.assets || []).filter(a => a.type === 'file');
  const preferred = opts.preferred || 'image';
  const filtered = files.filter(a => {
    if (preferred === 'image') return /\.(jpe?g|png|gif|webp|svg)$/i.test(a.name);
    if (preferred === 'video') return /\.(mp4|webm|mov|avi)$/i.test(a.name);
    return true;
  });
  let modal = document.getElementById('asset-picker-modal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'asset-picker-modal';
    modal.className = 'asset-picker-modal hidden';
    document.body.appendChild(modal);
  }
  const rawBase = `https://raw.githubusercontent.com/${STATE.ghOwner}/${STATE.ghRepo}/${STATE.ghBranch}/`;
  modal.innerHTML = `
    <div class="asset-picker-dialog">
      <div class="asset-picker-head">
        <div>
          <div class="asset-picker-title">Select Asset</div>
          <div class="asset-picker-subtitle">Choose an existing file from /assets. Upload new files from the Assets tab or each member field.</div>
        </div>
        <button class="qa-btn ghost" onclick="closeAssetSelector()">Close</button>
      </div>
      <div class="asset-picker-grid">
        ${filtered.length ? filtered.map((a, i) => {
          const isImage=/\.(jpe?g|png|gif|webp|svg)$/i.test(a.name);
          const isVideo=/\.(mp4|webm|mov|avi)$/i.test(a.name);
          const rawUrl=rawBase+a.path;
          const preview=isImage?`<img src="${rawUrl}" alt="${escapeHtml(a.name)}"/>`:isVideo?`<div class="asset-picker-placeholder">🎬</div>`:`<div class="asset-picker-placeholder">📄</div>`;
          return `<button class="asset-picker-card" onclick="chooseAssetFromPicker(${i})">${preview}<span>${escapeHtml(a.name)}</span></button>`;
        }).join('') : '<div class="asset-picker-empty">No matching assets found.</div>'}
      </div>
    </div>`;
  modal._targetInput = targetInput || null;
  modal._opts = opts;
  modal._files = filtered;
  modal.classList.remove('hidden');
}

function chooseAssetFromPicker(i) {
  const modal = document.getElementById('asset-picker-modal');
  const asset = modal && modal._files ? modal._files[i] : null;
  if (!asset) return;
  const value = assetDisplayPath(asset, modal._opts || {});
  if (modal._targetInput) {
    modal._targetInput.value = value;
    modal._targetInput.dispatchEvent(new Event('input', {bubbles:true}));
    toast('Selected ' + asset.name, 'success');
  } else {
    copyToClipboard(value);
  }
  closeAssetSelector();
}

function closeAssetSelector() {
  const modal = document.getElementById('asset-picker-modal');
  if (modal) modal.classList.add('hidden');
}

function escapeHtml(v) {
  return String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}
function escapeAttr(v) { return escapeHtml(v); }

async function uploadAsset(input, targetInputId, configKey) {
  const file = input.files[0];
  if (!file) return;
  if (!STATE.ghConnected) { toast('Connect GitHub to upload assets', 'error'); return; }
  if (targetInputId && isCropCapableImage(file)) {
    openImageCropper(file, async (processedFile) => {
      await finishAssetUpload(processedFile, targetInputId, configKey);
      if (input.value !== undefined) input.value = '';
    });
    return;
  }
  await finishAssetUpload(file, targetInputId, configKey);
  if (input.value !== undefined) input.value = '';
}
async function finishAssetUpload(file, targetInputId, configKey) {
  toast('Uploading ' + file.name + '...', 'info');
  const reader = new FileReader();
  reader.onload = async (e) => {
    const base64 = e.target.result.split(',')[1];
    const path = 'assets/' + file.name;
    const ok = await commitFile(path, base64, '📁 Asset upload: ' + file.name, true);
    if (ok) {
      toast(file.name + ' uploaded!', 'success');
      if (targetInputId) document.getElementById(targetInputId).value = file.name;
      if (configKey) onFieldChange(configKey, file.name);
      logChange('edit', 'Uploaded asset: ' + file.name);
      refreshAssets();
    } else toast('Upload failed', 'error');
  };
  reader.readAsDataURL(file);
}

async function handleBulkUpload(input) {
  for (const file of input.files) {
    await uploadAsset({ files: [file] }, null, null);
  }
}

async function handleFileDrop(files) {
  for (const file of files) {
    if (!STATE.ghConnected) { toast('Connect GitHub first', 'error'); return; }
    toast('Uploading ' + file.name + '...', 'info');
    const reader = new FileReader();
    reader.onload = async (e) => {
      const base64 = e.target.result.split(',')[1];
      const ok = await commitFile('assets/' + file.name, base64, '📁 Asset upload: ' + file.name, true);
      if (ok) { toast(file.name + ' uploaded!', 'success'); logChange('edit', 'Dropped asset: ' + file.name); refreshAssets(); }
      else toast('Upload failed for ' + file.name, 'error');
    };
    reader.readAsDataURL(file);
  }
}

async function deleteAsset(path, sha) {
  if (!confirm('Delete ' + path + '? This cannot be undone.')) return;
  const r = await fetch(`${ghBase()}/contents/${path}`, {
    method: 'DELETE', headers: ghHeaders(),
    body: JSON.stringify({ message: '🗑 Delete asset: ' + path, sha, branch: STATE.ghBranch })
  });
  if (r.ok) { toast('Asset deleted', 'success'); logChange('edit', 'Deleted asset: ' + path); refreshAssets(); }
  else toast('Delete failed', 'error');
}

// ══════════════════════════════════════════════
//  CLIPS EDITOR
// ══════════════════════════════════════════════
function renderClipsEditor() {
  const el = document.getElementById('clips-editor');
  el.innerHTML = STATE.clips.map((clip, i) => `
    <div class="clip-editor-card" id="clip-card-${i}">
      <div class="clip-num">Clip ${i+1}${clip.title ? ' — ' + clip.title : ''}</div>
      <div class="field">
        <label>Title</label>
        <input type="text" value="${clip.title||''}" placeholder="e.g. Insane 1v4 clutch" oninput="STATE.clips[${i}].title=this.value" />
      </div>
      <div class="field">
        <label>Link (Twitch / YouTube / TikTok / Instagram)</label>
        <div class="flex-row">
          <input type="text" value="${clip.url||''}" placeholder="Paste video URL..." style="flex:1" oninput="STATE.clips[${i}].url=this.value" />
          <button class="qa-btn ghost" onclick="document.getElementById('clip-file-${i}').click()">Upload</button>
          <input type="file" id="clip-file-${i}" accept="video/*" style="display:none" onchange="uploadClipFile(this,${i})" />
        </div>
        <div class="input-hint">${clip.url ? (STATE.showFullUrls ? clip.url : clip.url.split('/').pop().split('?')[0] || clip.url) : clip.file ? clip.file : 'No source yet'}</div>
      </div>
      ${i > 0 ? `<button class="qa-btn danger" onclick="removeClipSlot(${i})" style="align-self:flex-end">Remove</button>` : ''}
    </div>
  `).join('');
}

function addClipSlot() {
  STATE.clips.push({url:'',title:'',file:null});
  renderClipsEditor();
}

function removeClipSlot(i) {
  STATE.clips.splice(i,1);
  renderClipsEditor();
}

async function uploadClipFile(input, idx) {
  const file = input.files[0];
  if (!file || !STATE.ghConnected) { toast('Connect GitHub to upload clips', 'error'); return; }
  toast('Uploading ' + file.name + '...', 'info');
  const reader = new FileReader();
  reader.onload = async (e) => {
    const base64 = e.target.result.split(',')[1];
    const path = 'assets/' + file.name;
    const ok = await commitFile(path, base64, '🎬 Clip upload: ' + file.name, true);
    if (ok) {
      STATE.clips[idx].file = file.name;
      STATE.clips[idx].url  = '';
      toast(file.name + ' uploaded!', 'success');
      logChange('edit', 'Uploaded clip: ' + file.name);
      renderClipsEditor();
    } else toast('Upload failed', 'error');
  };
  reader.readAsDataURL(file);
}

// ══════════════════════════════════════════════
//  SCHEDULE EDITOR
// ══════════════════════════════════════════════
function renderScheduleEditor() {
  const el = document.getElementById('schedule-editor');
  const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  el.innerHTML = days.map(d => {
    const s = STATE.schedule[d];
    return `
      <div class="day-editor-card ${s.live?'active':''}" id="day-card-${d}">
        <div class="day-name-label">${d}</div>
        <label class="toggle" style="margin:4px 0">
          <input type="checkbox" ${s.live?'checked':''} onchange="toggleDay('${d}',this.checked)" />
          <div class="toggle-track"></div>
          <div class="toggle-thumb"></div>
        </label>
        <input class="day-time-input" type="text" value="${s.time||''}" placeholder="8pm" style="width:100%;font-size:0.75rem;padding:0.25rem;text-align:center;background:var(--bg4);border:1px solid var(--border2);border-radius:4px;color:var(--text)" oninput="STATE.schedule['${d}'].time=this.value" ${!s.live?'disabled':''} />
      </div>`;
  }).join('');
}

function toggleDay(day, on) {
  STATE.schedule[day].live = on;
  const card = document.getElementById('day-card-' + day);
  card.classList.toggle('active', on);
  const timeInput = card.querySelector('input[type="text"]');
  if (timeInput) timeInput.disabled = !on;
  renderScheduleEditor();
}

// ══════════════════════════════════════════════
//  LIVE BADGE TOGGLE
// ══════════════════════════════════════════════
function toggleLiveBadge() {
  STATE.liveBadgeOn = !STATE.liveBadgeOn;
  STATE.config.isLive = STATE.liveBadgeOn;
  localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
  document.getElementById('hero-live-badge').checked = STATE.liveBadgeOn;
  toast('Live badge ' + (STATE.liveBadgeOn ? 'ON' : 'OFF'), STATE.liveBadgeOn ? 'success' : 'info');
  logChange('edit', 'Live badge toggled ' + (STATE.liveBadgeOn ? 'ON' : 'OFF'));
}

// ══════════════════════════════════════════════
//  TWITCH API
// ══════════════════════════════════════════════
async function saveTwitchCreds() {
  // Use input field values if entered
  const idInput = document.getElementById('twitch-id-input');
  const secInput = document.getElementById('twitch-secret-input');
  if (idInput && idInput.value.trim()) STATE.twitchClientId = idInput.value.trim();
  if (secInput && secInput.value.trim()) STATE.twitchClientSecret = secInput.value.trim();
  await fetchTwitchToken();
}

async function fetchTwitchToken() {
  try {
    const r = await fetch(`https://id.twitch.tv/oauth2/token?client_id=${STATE.twitchClientId}&client_secret=${STATE.twitchClientSecret}&grant_type=client_credentials`, { method:'POST' });
    if (!r.ok) throw new Error('Bad credentials');
    const d = await r.json();
    STATE.twitchToken = d.access_token;
    updateTwitchConnStatus(true);
    const reauth = document.getElementById('twitch-reauth');
    if (reauth) { reauth.style.display = 'none'; }
    const idInput = document.getElementById('twitch-id-input');
    const secInput = document.getElementById('twitch-secret-input');
    if (idInput) idInput.value = '';
    if (secInput) secInput.value = '';
    startTwitchPolling();
  } catch(e) {
    updateTwitchConnStatus(false);
    const reauth = document.getElementById('twitch-reauth');
    if (reauth) reauth.style.display = 'block';
  }
}

function updateTwitchConnStatus(ok) {
  STATE.twitchConnected = ok;
  const el = document.getElementById('twitch-conn-status');
  if (el) { el.className = 'conn-badge ' + (ok ? 'connected' : 'disconnected'); el.innerHTML = `<span class="conn-dot"></span>${ok ? 'Connected' : 'Not connected'}`; }
  setDot('cdot-twitch', ok ? 'ok' : 'err');
  saveToStorage();
}

function startTwitchPolling() {
  if (STATE.twitchPollTimer) clearInterval(STATE.twitchPollTimer);
  const interval = parseInt(document.getElementById('twitch-poll-interval').value || '30') * 1000;
  checkTwitchLive();
  STATE.twitchPollTimer = setInterval(checkTwitchLive, interval);
}

async function checkTwitchLive() {
  if (!STATE.twitchToken || !STATE.twitchClientId) return;
  try {
    const r = await fetch(`https://api.twitch.tv/helix/streams?user_login=${STATE.twitchUsername}`, {
      headers: { 'Client-ID': STATE.twitchClientId, 'Authorization': 'Bearer ' + STATE.twitchToken }
    });
    if (!r.ok) { if (r.status === 401) await fetchTwitchToken(); return; }
    const d = await r.json();
    const stream = d.data && d.data[0];
    const online = !!stream;
    const indicator = document.getElementById('twitch-status');
    const statusText = document.getElementById('twitch-status-text');
    const viewerEl   = document.getElementById('twitch-viewer-count');
    indicator.className = 'live-indicator ' + (online ? 'online' : 'offline');
    statusText.textContent = online ? 'LIVE' : 'Offline';
    if (online && stream.viewer_count !== undefined) {
      viewerEl.style.display = '';
      viewerEl.textContent = ' · ' + stream.viewer_count.toLocaleString() + ' viewers';
      document.getElementById('dash-status').textContent = 'LIVE';
      document.getElementById('dash-viewers').textContent = stream.viewer_count.toLocaleString() + ' viewers · ' + (stream.game_name || '');
    } else {
      viewerEl.style.display = 'none';
      document.getElementById('dash-status').textContent = 'Offline';
      document.getElementById('dash-viewers').textContent = 'Not streaming';
    }
    STATE.isLive = online;
  } catch(e) {}
}

// ══════════════════════════════════════════════
//  THEME
// ══════════════════════════════════════════════
function liveTheme() {
  const green = document.getElementById('theme-green').value;
  const cyan  = document.getElementById('theme-cyan').value;
  const bg    = document.getElementById('theme-bg').value;
  document.getElementById('theme-green-hex').value = green;
  document.getElementById('theme-cyan-hex').value  = cyan;
  document.getElementById('theme-bg-hex').value    = bg;
  // Apply to theme preview iframe
  try {
    const iframe = document.getElementById('theme-preview-frame');
    const doc = iframe.contentDocument || iframe.contentWindow.document;
    const root = doc.documentElement;
    root.style.setProperty('--green', green);
    root.style.setProperty('--cyan', cyan);
    root.style.setProperty('--bg', bg);
  } catch(e) {}
}

function syncColorFromText(colorId, textId) {
  const val = document.getElementById(textId).value;
  if (/^#[0-9a-fA-F]{6}$/.test(val)) {
    document.getElementById(colorId).value = val;
    liveTheme();
  }
}

function pushTheme() {
  markDraftUpdated();
  STATE.config.accentColor = document.getElementById('theme-green').value;
  STATE.config.accent2Color = document.getElementById('theme-cyan').value;
  STATE.config.bgColor = document.getElementById('theme-bg').value;
  STATE.config.displayFont = document.getElementById('theme-display-font').value;
  STATE.config.bodyFont = document.getElementById('theme-body-font').value;
  localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
  saveToStorage();
  toast('Theme pushed to preview — deploy to go live', 'success');
  logChange('edit', 'Theme updated');
}

// ══════════════════════════════════════════════
//  CHANGE LOG
// ══════════════════════════════════════════════
function logChange(type, msg, detail = '') {
  const entry = { ts: new Date().toISOString(), type, msg, detail };
  STATE.changelog.unshift(entry);
  if (STATE.changelog.length > 200) STATE.changelog.pop();
  saveToStorage();
  renderChangelog();
  // also update dashboard log
  const dashLog = document.getElementById('dash-log');
  const div = document.createElement('div');
  div.className = 'log-entry';
  div.innerHTML = `<span class="log-time">${new Date(entry.ts).toLocaleTimeString()}</span><span class="log-badge ${type}">${type}</span><span class="log-msg">${msg}</span>${detail ? `<span class="log-detail">${detail}</span>` : ''}`;
  dashLog.insertBefore(div, dashLog.firstChild);
}

function renderChangelog() {
  const el = document.getElementById('changelog-body');
  if (!STATE.changelog.length) { el.innerHTML = '<div style="color:var(--muted);font-size:0.82rem">No changes logged yet.</div>'; return; }
  el.innerHTML = STATE.changelog.map(e => `
    <div class="log-entry">
      <span class="log-time">${new Date(e.ts).toLocaleString()}</span>
      <span class="log-badge ${e.type}">${e.type}</span>
      <span class="log-msg">${e.msg}</span>
      ${e.detail ? `<span class="log-detail">${e.detail}</span>` : ''}
    </div>`).join('');
}

function clearLog() {
  STATE.changelog = [];
  saveToStorage();
  renderChangelog();
  document.getElementById('dash-log').innerHTML = '<div class="log-entry"><span class="log-time">—</span><span class="log-badge edit">Info</span><span class="log-msg">Log cleared.</span></div>';
}

function exportLog() {
  const blob = new Blob([JSON.stringify(STATE.changelog, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'controldyn-changelog-' + new Date().toISOString().slice(0,10) + '.json';
  a.click();
  toast('Log exported', 'success');
}

// ══════════════════════════════════════════════
//  DASHBOARD
// ══════════════════════════════════════════════
function updateDashboard() {
  const d = STATE.config._lastDeploy;
  if (d) {
    document.getElementById('dash-deploy').textContent = new Date(d).toLocaleDateString();
    document.getElementById('dash-deploy-sub').textContent = new Date(d).toLocaleTimeString();
  }
  document.getElementById('dash-backup-count').textContent = STATE.backups.length;
}

// ══════════════════════════════════════════════
//  PREVIEW
// ══════════════════════════════════════════════
function setPreviewSrc(mode) {
  const frame = document.getElementById('preview-frame');
  const dot   = document.getElementById('preview-dot');
  const urlBar = document.getElementById('preview-url-bar');
  if (mode === 'live') {
    frame.src = 'https://chazdyn.com';
    dot.className = 'preview-dot live';
    urlBar.textContent = 'https://chazdyn.com (live)';
  } else {
    const localPath = getLocalIndexPath();
    frame.src = localPath + '?v=' + Date.now();
    dot.className = 'preview-dot preview';
    urlBar.textContent = localPath + ' (local preview)';
  }
  if (VISUAL_EDITOR.enabled) setTimeout(bindPreviewVisualEditor, 50);
}


// ══════════════════════════════════════════════
//  UTILS
// ══════════════════════════════════════════════
function toggleVisible(id) {
  const el = document.getElementById(id);
  el.type = el.type === 'password' ? 'text' : 'password';
}

function copyToClipboard(text) {
  navigator.clipboard.writeText(text).then(() => toast('Copied: ' + text, 'success')).catch(() => {
    const ta = document.createElement('textarea');
    ta.value = text; document.body.appendChild(ta);
    ta.select(); document.execCommand('copy'); document.body.removeChild(ta);
    toast('Copied!', 'success');
  });
}

function toast(msg, type = 'info') {
  const icons = { success: '✅', error: '❌', info: 'ℹ️', warning: '⚠️' };
  const el = document.createElement('div');
  el.className = 'toast ' + type;
  el.innerHTML = `<span class="toast-icon">${icons[type]||'ℹ️'}</span><span>${msg}</span>`;
  document.getElementById('toast-container').appendChild(el);
  setTimeout(() => { el.style.opacity='0'; el.style.transform='translateX(20px)'; el.style.transition='all 0.3s'; setTimeout(()=>el.remove(), 300); }, 3000);
}

// ══════════════════════════════════════════════
//  CLICK-TO-EDIT VISUAL EDITOR
// ══════════════════════════════════════════════

// Map of element selectors/keywords → {section, fieldId, label}
const CTX_MAP = [
  // Hero
  { match: ['hero-title','CHAZDYN','hero title'],       section:'hero',     field:'hero-tagline',    label:'Hero Title' },
  { match: ['hero-tagline','Always one more match'],    section:'hero',     field:'hero-tagline',    label:'Tagline' },
  { match: ['hero-eyebrow','Streamer'],                 section:'hero',     field:'hero-eyebrow',    label:'Eyebrow Text' },
  { match: ['live-badge','Live on Twitch'],             section:'hero',     field:'hero-live-badge', label:'Live Badge' },
  { match: ['btn-primary','btn-green','Watch Live'],    section:'hero',     field:'hero-twitch-url', label:'Watch Live Button' },
  { match: ['Join Discord'],                            section:'hero',     field:'hero-discord-url',label:'Discord Button' },
  // About
  { match: ['about-name','about-card'],                 section:'about',    field:'about-short-bio', label:'About Card' },
  { match: ['about-bio','about-text'],                  section:'about',    field:'about-short-bio', label:'Bio Text' },
  { match: ['about-handle'],                            section:'about',    field:'about-tags',      label:'Handles' },
  { match: ['avatar-ring','about-avatar'],              section:'about',    field:'about-avatar-url',label:'Avatar Image' },
  { match: ['tag','Black Ops','Party Games'],           section:'about',    field:'about-tags',      label:'Tags' },
  // Clips
  { match: ['clip','clip-card','clip-title','Best Moments'], section:'clips', field:null,            label:'Clips' },
  // Music
  { match: ['music','Beyond the Stream','music-video'], section:'music',    field:'music-video-url', label:'Music Section' },
  { match: ['music-link','YouTube','Spotify','SoundCloud'], section:'music', field:'music-yt-url',   label:'Music Links' },
  // Schedule
  { match: ['schedule','day-card','When I\'m Live'],    section:'schedule', field:null,              label:'Schedule' },
  // Socials
  { match: ['social-card','Find Me Everywhere','socials-grid'], section:'socials', field:null,       label:'Social Links' },
  { match: ['twitch.tv'],                               section:'socials',  field:'soc-twitch',      label:'Twitch Link' },
  { match: ['discord.gg'],                              section:'socials',  field:'soc-discord',     label:'Discord Link' },
  { match: ['tiktok'],                                  section:'socials',  field:'soc-tiktok',      label:'TikTok Link' },
  { match: ['instagram'],                               section:'socials',  field:'soc-insta',       label:'Instagram Link' },
  { match: ['thicc','THICC'],                           section:'socials',  field:'soc-thicc',       label:'THICC Link' },
  // Theme
  { match: ['hero-bg-art','orb','background'],          section:'theme',    field:'theme-bg',        label:'Background / Theme' },
];

const VISUAL_EDITOR = { enabled:false, boundFrame:null };

function findCtxMatches(text, className, tagName) {
  const haystack = (text + ' ' + className + ' ' + tagName).toLowerCase();
  const found = [];
  const seen = new Set();
  for (const entry of CTX_MAP) {
    for (const keyword of entry.match) {
      if (haystack.includes(keyword.toLowerCase())) {
        const key = entry.section + '|' + entry.field + '|' + entry.label;
        if (!seen.has(key)) { found.push(entry); seen.add(key); }
        break;
      }
    }
  }
  return found;
}
function findCtxMatch(text, className, tagName) { return findCtxMatches(text, className, tagName)[0] || null; }

function buildCtxActions(matches) {
  const list = Array.isArray(matches) ? matches.filter(Boolean) : (matches ? [matches] : []);
  const items = [];

  if (list.length) {
    list.forEach(match => items.push({
      icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>`,
      label: `Edit: ${match.label}`,
      action: () => jumpToField(match.section, match.field)
    }));
    items.push({ sep: true });
  } else {
    items.push({
      icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"/><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4 12.5-12.5z"/></svg>`,
      label: 'Open Index Editor',
      action: () => jumpToField('index-editor', 'index-html-editor')
    });
    items.push({ sep: true });
  }

  items.push({
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"/></svg>`,
    label: 'Edit Theme / Colors',
    action: () => jumpToField('theme', 'theme-green')
  });
  items.push({
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>`,
    label: 'Manage Assets',
    action: () => jumpToField('assets', null)
  });
  items.push({
    icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/></svg>`,
    label: 'Reload Preview',
    action: () => { const f = document.getElementById('preview-frame'); if(f) f.src += ''; }
  });

  return items;
}

function jumpToField(section, fieldId) {
  showSection(section);
  hideCtxMenu();
  if (fieldId) {
    setTimeout(() => {
      const el = document.getElementById(fieldId);
      if (el) {
        el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        el.focus();
        el.style.outline = '2px solid var(--green)';
        el.style.boxShadow = '0 0 0 4px rgba(57,255,20,0.15)';
        setTimeout(() => { el.style.outline = ''; el.style.boxShadow = ''; }, 2000);
      }
    }, 120);
  }
}

let CTX_ACTIONS = [];
function runCtxAction(i) { const fn = CTX_ACTIONS[i]; hideCtxMenu(); if (typeof fn === 'function') fn(); }

function showCtxMenu(x, y, matches, elementLabel) {
  const menu = document.getElementById('ctx-menu');
  const titleEl = document.getElementById('ctx-title');
  const labelEl = document.getElementById('ctx-element-label');
  const itemsEl = document.getElementById('ctx-items');
  const list = Array.isArray(matches) ? matches.filter(Boolean) : (matches ? [matches] : []);

  titleEl.textContent = list.length > 1 ? 'Choose Field to Edit' : (list[0]?.label || 'Edit Options');
  labelEl.textContent = elementLabel ? elementLabel.substring(0, 60) : '';
  labelEl.style.display = elementLabel ? '' : 'none';

  const actions = buildCtxActions(list);
  CTX_ACTIONS = actions.map(a => a.action);
  itemsEl.innerHTML = actions.map((a, i) => a.sep
    ? '<div class="ctx-sep"></div>'
    : `<button class="ctx-item" onclick="runCtxAction(${i})">${a.icon}${a.label}</button>`
  ).join('');

  menu.style.left = '0'; menu.style.top = '0';
  menu.classList.add('visible');
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  const vw = window.innerWidth,  vh = window.innerHeight;
  menu.style.left = Math.max(8, Math.min(x, vw - mw - 8)) + 'px';
  menu.style.top  = Math.max(8, Math.min(y, vh - mh - 8)) + 'px';
}

function hideCtxMenu() {
  const menu = document.getElementById('ctx-menu');
  if (menu) menu.classList.remove('visible');
}

function toggleVisualEditor() {
  if (VISUAL_EDITOR.enabled) disableVisualEditor(); else enableVisualEditor();
}

function enableVisualEditor() {
  VISUAL_EDITOR.enabled = true;
  setPreviewSrc('preview');
  updateVisualEditorUi();
  bindPreviewVisualEditor();
  toast('Edit Mode ON — click anything in the preview to choose what to edit', 'success');
  showSection('preview');
}

function disableVisualEditor() {
  VISUAL_EDITOR.enabled = false;
  updateVisualEditorUi();
  hideCtxMenu();
  toast('Edit Mode OFF', 'info');
}

function updateVisualEditorUi() {
  const btn = document.getElementById('visual-edit-toggle');
  const label = document.getElementById('visual-edit-label');
  const status = document.getElementById('visual-edit-status');
  if (btn) btn.classList.toggle('active', VISUAL_EDITOR.enabled);
  if (label) label.textContent = VISUAL_EDITOR.enabled ? 'Editing ON' : 'Edit Mode';
  if (status) status.style.display = VISUAL_EDITOR.enabled ? '' : 'none';
}

function getVisualMatchesFromElement(el) {
  const matches = [];
  const seen = new Set();
  let node = el;
  for (let depth = 0; node && depth < 7; depth++, node = node.parentElement) {
    const text = node.textContent?.trim() || '';
    const cls  = (node.className || '') + ' ' + (node.id || '');
    const tag  = node.tagName?.toLowerCase() || '';
    findCtxMatches(text, cls, tag).forEach(m => {
      const key = m.section + '|' + m.field + '|' + m.label;
      if (!seen.has(key)) { matches.push(m); seen.add(key); }
    });
  }
  return matches;
}

function bindPreviewVisualEditor() {
  const iframe = document.getElementById('preview-frame');
  if (!iframe) return;

  const bind = () => {
    try {
      const doc = iframe.contentDocument || iframe.contentWindow.document;
      if (!doc || doc.__controlDynVisualEditorBound) return;
      doc.__controlDynVisualEditorBound = true;
      doc.addEventListener('click', handlePreviewEditClick, true);
      doc.addEventListener('contextmenu', handlePreviewEditClick, true);
      doc.body?.classList.add('control-dyn-editable-preview');
    } catch(err) {
      toast('Preview is cross-origin. Switch to Preview/local mode for click editing.', 'warning');
    }
  };

  iframe.addEventListener('load', bind);
  bind();
}

function handlePreviewEditClick(e) {
  if (!VISUAL_EDITOR.enabled) return;
  e.preventDefault();
  e.stopPropagation();

  const iframe = document.getElementById('preview-frame');
  const iRect = iframe.getBoundingClientRect();
  const x = iRect.left + e.clientX;
  const y = iRect.top + e.clientY;
  const el = e.target;
  const matches = getVisualMatchesFromElement(el);
  const elementLabel = (el.textContent?.trim() || el.alt || el.getAttribute?.('aria-label') || el.id || el.className || el.tagName || '').toString();
  showCtxMenu(x, y, matches, elementLabel);
}

// Close menu on app click/scroll/escape. Preview clicks are handled inside the iframe above.
document.addEventListener('click', e => {
  if (!e.target.closest('#ctx-menu') && !e.target.closest('#visual-edit-toggle')) hideCtxMenu();
});
document.addEventListener('scroll', hideCtxMenu, true);
document.addEventListener('keydown', e => { if (e.key === 'Escape') { hideCtxMenu(); if (VISUAL_EDITOR.enabled) disableVisualEditor(); } });

// ══════════════════════════════════════════════
//  PWA INSTALL
// ══════════════════════════════════════════════
let _pwaPrompt = null;
window.addEventListener('beforeinstallprompt', e => {
  e.preventDefault();
  _pwaPrompt = e;
  const btn = document.getElementById('install-btn');
  if (btn) btn.style.display = '';
});

function installPWA() {
  if (!_pwaPrompt) { toast('Open in Chrome and use the address bar install button', 'info'); return; }
  _pwaPrompt.prompt();
  _pwaPrompt.userChoice.then(r => {
    if (r.outcome === 'accepted') { toast('Control.Dyn installed!', 'success'); document.getElementById('install-btn').style.display = 'none'; }
    _pwaPrompt = null;
  });
}

window.addEventListener('appinstalled', () => { toast('Control.Dyn installed as desktop app!', 'success'); logChange('deploy', 'PWA installed'); });

// Register service worker
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('./sw.js').catch(e => console.warn('SW:', e));
}

// ══════════════════════════════════════════════
//  THICC
// ══════════════════════════════════════════════
const DEFAULT_THICC_MEMBERS = [
  { id:1, name:'Chazdyn', gamertag:'Chazdyn', rank:'Clan Leader', isLeader:true,
    about:'PNW dad, musician, and the guy who pauses games to read chat. Come hang.',
    bio:'Pacific Northwest content creator, dad, and musician who somehow finds time to lead a COD clan and entertain thousands on stream. Chazdyn built THICC from the ground up — it\'s not about K/D ratios, it\'s about vibes and good comms.',
    photoUrl:'../assets/Chazdyn Avatar.JPG', videoUrl:'', bannerUrl:'', accentColor:'#f5a623',
    socials:[
      {platform:'Twitch',url:'https://twitch.tv/chazdyn',handle:'Chazdyn'},
      {platform:'TikTok',url:'https://tiktok.com/@thiccchazdyn',handle:'@THICCChazdyn'},
      {platform:'Instagram',url:'https://instagram.com/chazdynplays',handle:'@ChazdynPlays'}
    ]},
  { id:2, name:'ShyShackle', gamertag:'ShyShackle', rank:'Member', isLeader:false,
    about:'Horror games, jump scares, shooters and constant chaos. Dark aesthetic, smart mouth, soft spot for new friends. Come hang... if you can handle it 🖤',
    bio:'New Affiliate 🎉 Horror games, jump scares, shooters and constant chaos with her favorites. She talks trash, screams, laughs—it\'s a whole mess. Dark aesthetic, smart mouth, soft spot for making new friends. Come hang... if you can handle it 🖤',
    photoUrl:'../assets/ShyShack Avatar.png', videoUrl:'', bannerUrl:'', accentColor:'#c0392b',
    socials:[
      {platform:'Twitch',url:'https://twitch.tv/shyshackle',handle:'ShyShackle'},
      {platform:'TikTok',url:'https://tiktok.com/@shyshackle',handle:'@shyshackle'},
      {platform:'Instagram',url:'https://instagram.com/shyshackle',handle:'@shyshackle'}
    ]},
  { id:3, name:'Mastercardi',     gamertag:'Mastercardi',     rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#22c55e', socials:[] },
  { id:4, name:'SenoritoTaquito', gamertag:'SenoritoTaquito', rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#fb923c', socials:[] },
  { id:5, name:'PrincessBayleaf', gamertag:'PrincessBayleaf', rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#f472b6', socials:[] },
  { id:6, name:'NeighborGuyBri',  gamertag:'NeighborGuyBri',  rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#2dd4bf', socials:[] },
  { id:7, name:'Thomas',          gamertag:'Thomas',          rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#a78bfa', socials:[] }
];

function loadTHICC() {
  try {
    const raw = localStorage.getItem('chazdyn_thicc');
    if (raw) {
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed) && parsed.length > 0) return parsed;
    }
  } catch(e) {
    console.warn('chazdyn_thicc corrupt, clearing:', e);
    localStorage.removeItem('chazdyn_thicc');
  }
  return JSON.parse(JSON.stringify(DEFAULT_THICC_MEMBERS));
}

function saveTHICC() {
  // Collect from editor
  const members = collectTHICC();
  localStorage.setItem('chazdyn_thicc', JSON.stringify(members));
  STATE.config.thiccMembers = members;
  // Also save clan settings into STATE.config
  STATE.config.thiccDesc    = document.getElementById('thicc-desc')?.value || '';
  STATE.config.thiccGame    = document.getElementById('thicc-game')?.value || 'BO6';
  STATE.config.thiccFounded = document.getElementById('thicc-founded')?.value || '2025';
  STATE.config.thiccTag     = document.getElementById('thicc-tag')?.value || 'THICC';
  STATE.config.thiccFullname= document.getElementById('thicc-fullname')?.value || '';
  localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
  saveToStorage();
  toast('THICC saved to preview', 'success');
  logChange('edit', 'THICC roster/settings saved');
}

function collectTHICC() {
  const cards = document.querySelectorAll('.thicc-member-editor');
  return Array.from(cards).map(card => {
    const id = parseInt(card.dataset.id);
    const socials = Array.from(card.querySelectorAll('.thicc-social-row')).map(row => ({
      platform: row.querySelector('.thicc-soc-platform').value,
      url:      row.querySelector('.thicc-soc-url').value,
      handle:   row.querySelector('.thicc-soc-handle').value
    })).filter(s => s.url);
    return {
      id,
      name:        card.querySelector('.thicc-name').value,
      gamertag:    card.querySelector('.thicc-gamertag').value,
      rank:        card.querySelector('.thicc-rank').value,
      isLeader:    card.querySelector('.thicc-leader').checked,
      about:       card.querySelector('.thicc-about').value,
      bio:         card.querySelector('.thicc-bio').value,
      photoUrl:    card.querySelector('.thicc-photo-url').value,
      videoUrl:    card.querySelector('.thicc-video-url').value,
      bannerUrl:   card.querySelector('.thicc-banner-url').value,
      accentColor: card.querySelector('.thicc-accent-color').value,
      socials
    };
  });
}

function renderTHICC() {
  const members = loadTHICC();
  const el = document.getElementById('thicc-roster-editor');
  if (!el) return;
  el.innerHTML = members.map((m,i) => renderMemberEditor(m,i)).join('');
}

function renderMemberEditor(m, i) {
  const socialsHtml = (m.socials||[]).map((s,si) => `
    <div class="thicc-social-row flex-row" style="gap:0.5rem;margin-top:0.4rem">
      <select class="thicc-soc-platform" style="width:110px;font-size:0.78rem;padding:0.3rem">
        ${['Twitch','TikTok','Instagram','YouTube','Twitter','Other'].map(p=>`<option ${s.platform===p?'selected':''}>${p}</option>`).join('')}
      </select>
      <input class="thicc-soc-url" type="text" value="${escapeAttr(s.url||'')}" placeholder="URL" style="flex:1;font-size:0.78rem;padding:0.3rem" />
      <input class="thicc-soc-handle" type="text" value="${escapeAttr(s.handle||'')}" placeholder="@handle" style="width:110px;font-size:0.78rem;padding:0.3rem" />
      <button class="qa-btn danger" onclick="removeSocialRow(this)" style="padding:3px 8px;font-size:0.7rem">✕</button>
    </div>`).join('');

  return `
    <div class="thicc-member-editor" data-id="${m.id}" style="background:var(--bg3);border:1px solid var(--border2);border-radius:6px;padding:1rem;margin-bottom:0.75rem;">
      <div class="flex-row" style="margin-bottom:0.75rem;justify-content:space-between">
        <div class="flex-row">
          <span style="font-family:var(--display);font-size:1.1rem;letter-spacing:0.06em;color:var(--text)">${m.name||'New Member'}</span>
          <label class="toggle" title="Clan Leader">
            <input type="checkbox" class="thicc-leader" ${m.isLeader?'checked':''} />
            <div class="toggle-track"></div>
            <div class="toggle-thumb"></div>
          </label>
          <span style="font-size:0.7rem;color:var(--muted)">Leader</span>
        </div>
        <button class="qa-btn danger" onclick="removeMember(${m.id})" style="font-size:0.72rem">Remove</button>
      </div>
      <div class="field-row" style="margin-bottom:0.6rem">
        <div class="field">
          <label>Display Name</label>
          <input type="text" class="thicc-name" value="${escapeAttr(m.name||'')}" placeholder="Name" />
        </div>
        <div class="field">
          <label>Gamertag</label>
          <input type="text" class="thicc-gamertag" value="${escapeAttr(m.gamertag||'')}" placeholder="Gamertag" />
        </div>
        <div class="field">
          <label>Rank</label>
          <input type="text" class="thicc-rank" value="${escapeAttr(m.rank||'Member')}" placeholder="Member" />
        </div>
      </div>
      <div class="field-row" style="margin-bottom:0.6rem;align-items:flex-end">
        <div class="field" style="flex:1">
          <label>Short Bio (card)</label>
          <textarea class="thicc-about" style="min-height:56px">${escapeHtml(m.about||'')}</textarea>
          <label style="margin-top:0.5rem">Long Bio (profile popout)</label>
          <textarea class="thicc-bio" style="min-height:82px">${escapeHtml(m.bio||'')}</textarea>
        </div>
        <div class="field" style="flex:0 0 auto;min-width:130px">
          <label>Profile Accent Color</label>
          <div class="flex-row" style="gap:0.4rem;align-items:center">
            <input type="color" class="thicc-accent-color" value="${m.accentColor||'#f5a623'}" style="width:36px;height:36px;padding:2px;cursor:pointer;border:1px solid var(--border2);background:transparent" oninput="document.getElementById('accent-hex-${m.id}').textContent=this.value" />
            <span style="font-family:monospace;font-size:0.75rem;color:var(--muted)" id="accent-hex-${m.id}">${m.accentColor||'#f5a623'}</span>
          </div>
        </div>
      </div>
      <div class="field-row" style="margin-bottom:0.6rem">
        <div class="field">
          <label>Photo (filename or URL)</label>
          <div class="flex-row">
            <input type="text" class="thicc-photo-url" value="${escapeAttr(m.photoUrl||'')}" placeholder="assets/..." style="flex:1;font-size:0.8rem" />
            <button class="qa-btn ghost" onclick="openAssetSelector(this.closest('.flex-row').querySelector('.thicc-photo-url'),{thicc:true,preferred:'image'})" style="font-size:0.72rem">Select</button>
            <button class="qa-btn ghost" onclick="uploadTHICC(this,'photo')" style="font-size:0.72rem">Upload</button>
            <input type="file" accept="image/*" style="display:none" onchange="handleTHICCUpload(this,'photo')" />
          </div>
        </div>
        <div class="field">
          <label>Hover Video (filename or URL)</label>
          <div class="flex-row">
            <input type="text" class="thicc-video-url" value="${escapeAttr(m.videoUrl||'')}" placeholder="assets/..." style="flex:1;font-size:0.8rem" />
            <button class="qa-btn ghost" onclick="openAssetSelector(this.closest('.flex-row').querySelector('.thicc-video-url'),{thicc:true,preferred:'video'})" style="font-size:0.72rem">Select</button>
            <button class="qa-btn ghost" onclick="uploadTHICC(this,'video')" style="font-size:0.72rem">Upload</button>
            <input type="file" accept="video/*" style="display:none" onchange="handleTHICCUpload(this,'video')" />
          </div>
        </div>
      </div>

      <div class="field" style="margin-bottom:0.6rem">
        <label>Profile Popout Banner (filename or URL)</label>
        <div class="flex-row">
          <input type="text" class="thicc-banner-url" value="${escapeAttr(m.bannerUrl||'')}" placeholder="../assets/banner.jpg" style="flex:1;font-size:0.8rem" />
          <button class="qa-btn ghost" onclick="openAssetSelector(this.closest('.flex-row').querySelector('.thicc-banner-url'),{thicc:true,preferred:'image'})" style="font-size:0.72rem">Select</button>
          <button class="qa-btn ghost" onclick="uploadTHICC(this,'banner')" style="font-size:0.72rem">Upload</button>
          <input type="file" accept="image/*" style="display:none" onchange="handleTHICCUpload(this,'banner')" />
        </div>
        <div class="input-hint">Shown across the top of that member's click-to-open profile.</div>
      </div>
      <div class="field">
        <label>Social Links</label>
        <div class="thicc-socials-list">${socialsHtml}</div>
        <button class="qa-btn ghost" onclick="addSocialRow(this)" style="margin-top:0.4rem;font-size:0.72rem">+ Add Social</button>
      </div>
    </div>`;
}

function addMember() {
  const members = loadTHICC();
  const newId = Math.max(0, ...members.map(m=>m.id)) + 1;
  members.push({ id:newId, name:'New Member', gamertag:'', rank:'Member', isLeader:false, about:'', bio:'', photoUrl:'', videoUrl:'', bannerUrl:'', accentColor:'#f5a623', socials:[] });
  localStorage.setItem('chazdyn_thicc', JSON.stringify(members));
  renderTHICC();
  logChange('edit', 'Added new THICC member');
}

function removeMember(id) {
  if (!confirm('Remove this member?')) return;
  let members = loadTHICC().filter(m => m.id !== id);
  localStorage.setItem('chazdyn_thicc', JSON.stringify(members));
  renderTHICC();
  logChange('edit', 'Removed THICC member #' + id);
}

function addSocialRow(btn) {
  const list = btn.previousElementSibling;
  const div = document.createElement('div');
  div.className = 'thicc-social-row flex-row';
  div.style.cssText = 'gap:0.5rem;margin-top:0.4rem';
  div.innerHTML = `
    <select class="thicc-soc-platform" style="width:110px;font-size:0.78rem;padding:0.3rem">
      ${['Twitch','TikTok','Instagram','YouTube','Twitter','Other'].map(p=>`<option>${p}</option>`).join('')}
    </select>
    <input class="thicc-soc-url" type="text" placeholder="URL" style="flex:1;font-size:0.78rem;padding:0.3rem" />
    <input class="thicc-soc-handle" type="text" placeholder="@handle" style="width:110px;font-size:0.78rem;padding:0.3rem" />
    <button class="qa-btn danger" onclick="removeSocialRow(this)" style="padding:3px 8px;font-size:0.7rem">✕</button>`;
  list.appendChild(div);
}

function removeSocialRow(btn) { btn.closest('.thicc-social-row').remove(); }

function uploadTHICC(btn, type) {
  btn.nextElementSibling.click();
}

async function handleTHICCUpload(input, type) {
  const file = input.files[0];
  if (!file) return;
  if (!STATE.ghConnected) { toast('Connect GitHub to upload', 'error'); return; }
  const go = async (processedFile) => {
    await finishTHICCUpload(input, processedFile);
    if (input.value !== undefined) input.value = '';
  };
  if ((type === 'photo' || type === 'banner') && isCropCapableImage(file)) {
    openImageCropper(file, go);
    return;
  }
  await go(file);
}
async function finishTHICCUpload(input, file) {
  toast('Uploading ' + file.name + '...', 'info');
  const reader = new FileReader();
  reader.onload = async (e) => {
    const base64 = e.target.result.split(',')[1];
    const ok = await commitFile('assets/' + file.name, base64, '📁 THICC upload: ' + file.name, true);
    if (ok) {
      const urlInput = input.closest('.flex-row').querySelector('input[type="text"]');
      if (urlInput) urlInput.value = STATE.showFullUrls
        ? `https://raw.githubusercontent.com/${STATE.ghOwner}/${STATE.ghRepo}/${STATE.ghBranch}/assets/${file.name}`
        : `../assets/${file.name}`;
      toast(file.name + ' uploaded!', 'success');
      logChange('edit', 'Uploaded THICC asset: ' + file.name);
      refreshAssets();
    } else toast('Upload failed', 'error');
  };
  reader.readAsDataURL(file);
}

async function deployTHICC() {
  if (!STATE.ghConnected) { toast('Connect GitHub first', 'error'); return; }
  saveTHICC();
  toast('Creating backup...', 'info');

  // Read current thicc/index.html
  const html = await readFile('thicc/index.html');
  if (!html) { toast('Could not read thicc/index.html', 'error'); return; }

  const members = loadTHICC();

  // 1. Replace DEFAULT_MEMBERS source block so fallback is always correct
  const membersJson = JSON.stringify(members, null, 2);
  let updated = html.replace(
    /const DEFAULT_MEMBERS = \[[\s\S]*?\];/,
    'const DEFAULT_MEMBERS = ' + membersJson + ';'
  );

  // 2. Inject a seed script that always overwrites localStorage on page load
  const membersJsonStr = JSON.stringify(members);
  const seedInner = 'localStorage.setItem("chazdyn_thicc",' + JSON.stringify(membersJsonStr) + ');';
  const _sc = '\u003c/script>';
  const seedScript = '\n<script data-thicc-deploy>' + seedInner + _sc;
  updated = updated.replace(/<script data-thicc-deploy>[\s\S]*?<\/script>\n?/, '');
  updated = updated.replace('</head>', seedScript + '\n</head>');

  const ok = await commitFile('thicc/index.html', updated, '🎮 THICC deploy: ' + new Date().toLocaleString());
  if (ok) {
    STATE.config.thiccMembers = members;
    STATE.config._lastDeploy = new Date().toISOString();
    localStorage.setItem('chazdyn_config', JSON.stringify(STATE.config));
    saveToStorage();
    try {
      const indexHtml = await readFile('index.html');
      if (indexHtml) {
        const configScript = buildConfigSeedScript(STATE.config);
        let updatedIndex = indexHtml.replace(/<script data-controldyn>[\s\S]*?<\/script>/,'');
        updatedIndex = updatedIndex.replace('</head>', configScript + '</head>');
        await commitFile('index.html', updatedIndex, 'THICC roster sync: ' + new Date().toLocaleString());
      }
    } catch(e) { console.warn('Index THICC sync failed:', e); }
    toast('THICC deployed! ✓', 'success');
    logChange('deploy', 'THICC roster deployed to live');
  } else {
    toast('THICC deploy failed', 'error');
    logChange('error', 'THICC deploy failed');
  }
}

// ══════════════════════════════════════════════
//  CONNECTION DOTS
// ══════════════════════════════════════════════
function setDot(id, state) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'conn-dot-item' + (state ? ' ' + state : '');
}

async function testAllConnections() {
  ['cdot-gh','cdot-twitch','cdot-supabase'].forEach(id => setDot(id, 'checking'));

  // GitHub — test and reconnect if needed
  try {
    const r = await fetch(ghBase(), { headers: ghHeaders() });
    if (r.ok) {
      updateGhStatus(true);
      setDot('cdot-gh', 'ok');
      document.getElementById('gh-reauth').style.display = 'none';
      if (!STATE.ghConnected) { refreshAssets(); syncControlDynFromLive(); }
    } else {
      updateGhStatus(false);
      setDot('cdot-gh', 'err');
      document.getElementById('gh-reauth').style.display = 'block';
    }
  } catch { updateGhStatus(false); setDot('cdot-gh', 'err'); document.getElementById('gh-reauth').style.display = 'block'; }

  // Twitch — test and reconnect if needed
  try {
    const r = await fetch(`https://id.twitch.tv/oauth2/token?client_id=${STATE.twitchClientId}&client_secret=${STATE.twitchClientSecret}&grant_type=client_credentials`, { method:'POST' });
    if (r.ok) {
      const d = await r.json();
      STATE.twitchToken = d.access_token;
      updateTwitchConnStatus(true);
      setDot('cdot-twitch', 'ok');
      document.getElementById('twitch-reauth').style.display = 'none';
      if (!STATE.twitchConnected) startTwitchPolling();
    } else {
      updateTwitchConnStatus(false);
      setDot('cdot-twitch', 'err');
      document.getElementById('twitch-reauth').style.display = 'block';
    }
  } catch { updateTwitchConnStatus(false); setDot('cdot-twitch', 'err'); document.getElementById('twitch-reauth').style.display = 'block'; }

  // Supabase — test and reconnect if needed
  try {
    if (!cdSupabase) cdInitSupabase();
    const { error } = await cdSupabase.from('community_members').select('id').limit(1);
    if (!error) {
      setDot('cdot-supabase', 'ok');
      document.getElementById('sb-reauth').style.display = 'none';
      const el = document.getElementById('sd-conn-status');
      if (el) { el.className = 'conn-badge connected'; el.innerHTML = '<span class="conn-dot"></span>Connected'; }
      if (!document.getElementById('sd-members-list').children.length) { sdLoadMembers(); sdLoadRequests(); }
    } else {
      setDot('cdot-supabase', 'err');
      document.getElementById('sb-reauth').style.display = 'block';
    }
  } catch { setDot('cdot-supabase', 'err'); document.getElementById('sb-reauth').style.display = 'block'; }
}

// ══════════════════════════════════════════════
//  DISCORD AUTH GATE
// ══════════════════════════════════════════════
const CD_ADMIN_DISCORD_ID = '562352729482067968';
const CD_SUPABASE_URL = 'https://lqayctcgprumnvlaktms.supabase.co';
const CD_SUPABASE_KEY = 'sb_publishable_tcWWDYpGBbVY1XKVNUaiZw_miMfMiFG';

let cdSupabase = null;

function cdInitSupabase() {
  if (window.supabase && !cdSupabase) {
    cdSupabase = window.supabase.createClient(CD_SUPABASE_URL, CD_SUPABASE_KEY);
  }
  return !!cdSupabase;
}

async function cdCheckAuth() {
  const gate = document.getElementById('discord-auth-gate');
  const app = document.querySelector('.app');

  cdInitSupabase();

  if (!cdSupabase) {
    gate.style.display = 'flex';
    app.style.display = 'none';
    return;
  }

  const { data: { session } } = await cdSupabase.auth.getSession();

  if (!session) {
    gate.style.display = 'flex';
    app.style.display = 'none';
    return;
  }

  const discordId = session.user.user_metadata?.provider_id || session.user.id;
  if (discordId !== CD_ADMIN_DISCORD_ID) {
    gate.innerHTML = '<div style="color:#c0392b;font-family:monospace;text-align:center;padding:2rem;">Access denied. Not Chazdyn\'s account.</div>';
    gate.style.display = 'flex';
    app.style.display = 'none';
    return;
  }

  gate.style.display = 'none';
  app.style.display = '';

  // Connect GitHub immediately so actions work right away
  try {
    const r = await fetch(ghBase(), { headers: ghHeaders() });
    if (r.ok) {
      updateGhStatus(true);
      setTimeout(syncControlDynFromLive, 300);
      refreshAssets();
    }
  } catch(e) {}

  // Connect Twitch
  startTwitchPolling();

  // Update all status dots
  setTimeout(testAllConnections, 800);

  const topbarRight = document.querySelector('.topbar-right');
  if (topbarRight && !document.getElementById('cd-logout-btn')) {
    const av = session.user.user_metadata?.avatar_url;
    const name = session.user.user_metadata?.full_name || session.user.user_metadata?.name || 'Chazdyn';
    const userEl = document.createElement('div');
    userEl.style.cssText = 'display:flex;align-items:center;gap:8px;';
    userEl.innerHTML = `
      ${av ? `<img src="${av}" style="width:26px;height:26px;border-radius:50%;border:1px solid rgba(57,255,20,0.3);" />` : ''}
      <span style="font-family:monospace;font-size:0.72rem;color:var(--muted);">${name}</span>
      <button id="cd-logout-btn" class="qa-btn ghost" onclick="cdLogout()" style="font-size:0.68rem;">Sign Out</button>`;
    topbarRight.prepend(userEl);
  }

  sdLoadMembers();
  sdLoadRequests();
}

async function cdDiscordLogin() {
  cdInitSupabase();
  await cdSupabase.auth.signInWithOAuth({
    provider: 'discord',
    options: { redirectTo: window.location.href }
  });
}

async function cdLogout() {
  if (cdSupabase) await cdSupabase.auth.signOut();
  location.reload();
}

async function sdTestConnection() {
  // Use new key if entered
  const keyInput = document.getElementById('sb-key-input');
  if (keyInput && keyInput.value.trim()) {
    cdSupabase = window.supabase.createClient(CD_SUPABASE_URL, keyInput.value.trim());
  }
  if (!cdSupabase) cdInitSupabase();
  const { error } = await cdSupabase.from('community_members').select('id').limit(1);
  const el = document.getElementById('sd-conn-status');
  const reauth = document.getElementById('sb-reauth');
  if (error) {
    if (el) { el.className = 'conn-badge disconnected'; el.innerHTML = '<span class="conn-dot"></span>Failed'; }
    if (reauth) reauth.style.display = 'block';
    setDot('cdot-supabase', 'err');
    toast('Supabase connection failed', 'error');
  } else {
    if (el) { el.className = 'conn-badge connected'; el.innerHTML = '<span class="conn-dot"></span>Connected'; }
    if (reauth) reauth.style.display = 'none';
    if (keyInput) keyInput.value = '';
    setDot('cdot-supabase', 'ok');
    toast('Supabase connected!', 'success');
    sdLoadMembers(); sdLoadRequests();
  }
}
// ══════════════════════════════════════════════
//  SPACEDYN MEMBER MANAGEMENT
// ══════════════════════════════════════════════
async function sdLoadMembers() {
  if (!cdSupabase) return;
  const list = document.getElementById('sd-members-list');
  list.innerHTML = '<div style="color:var(--muted);font-size:0.82rem;">Loading...</div>';
  const { data, error } = await cdSupabase.from('community_members').select('*').order('created_at', { ascending: true });
  if (error || !data || !data.length) {
    list.innerHTML = `<div style="color:var(--muted);font-size:0.82rem;">${error ? error.message : 'No members yet.'}</div>`;
    return;
  }
  list.innerHTML = data.map(m => `
  <div style="display:flex;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--border-subtle);">
    <div style="width:40px;height:40px;overflow:hidden;border:1px solid var(--border-subtle);flex-shrink:0;background:var(--surface);">
      ${m.photo_url ? `<img src="${m.photo_url}" style="width:100%;height:100%;object-fit:cover;" onerror="this.style.display='none'" />` : `<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;font-family:'Bebas Neue',sans-serif;font-size:1.2rem;color:${m.accent_color||'#f5a623'}">${(m.display_name||'?').charAt(0)}</div>`}
    </div>
    <div style="flex:1;min-width:0;">
      <div style="font-family:'Bebas Neue',sans-serif;font-size:1.1rem;letter-spacing:0.05em;">${m.display_name||'Unnamed'}</div>
      <div style="font-size:0.72rem;color:var(--muted);">${m.role||'Space Fam'}${m.discord_username?' · @'+m.discord_username:' · unclaimed'}</div>
    </div>
    <span style="font-size:0.62rem;font-family:monospace;letter-spacing:0.08em;padding:2px 8px;border-radius:2px;${m.approved?'background:rgba(46,204,113,0.15);color:#2ecc71;border:1px solid rgba(46,204,113,0.3);':'background:rgba(245,166,35,0.1);color:#f5a623;border:1px solid rgba(245,166,35,0.25);'}">${m.approved?'Live':'Pending'}</span>
    ${!m.approved?`<button class="qa-btn ghost" onclick="sdApproveMember('${m.id}')" style="font-size:0.72rem;">Approve</button>`:''}
    <button class="qa-btn danger" onclick="sdRemoveMember('${m.id}','${m.display_name}')" style="font-size:0.72rem;">Remove</button>
  </div>`).join('');
}

async function sdApproveMember(id) {
  if (!cdSupabase) return;
  const { error } = await cdSupabase.from('community_members').update({ approved: true }).eq('id', id);
  if (error) { toast('Error: ' + error.message, 'error'); return; }
  toast('Member approved!', 'success');
  sdLoadMembers();
}

async function sdRemoveMember(id, name) {
  if (!confirm(`Remove ${name} from SpaceDyn?`)) return;
  if (!cdSupabase) return;
  const { error } = await cdSupabase.from('community_members').delete().eq('id', id);
  if (error) { toast('Error: ' + error.message, 'error'); return; }
  toast(`${name} removed.`, 'success');
  sdLoadMembers();
}

function sdShowAddForm() {
  document.getElementById('sd-add-panel').style.display = '';
  document.getElementById('sd-add-panel').scrollIntoView({ behavior: 'smooth' });
}

function sdHideAddForm() {
  document.getElementById('sd-add-panel').style.display = 'none';
  ['sd-add-name','sd-add-role','sd-add-discord','sd-add-about','sd-add-photo'].forEach(id => document.getElementById(id).value = '');
  document.getElementById('sd-add-color').value = '#f5a623';
  document.getElementById('sd-add-color-hex').value = '#f5a623';
}

document.getElementById('sd-add-color').addEventListener('input', e => {
  document.getElementById('sd-add-color-hex').value = e.target.value;
});

async function sdAddMember() {
  if (!cdSupabase) { toast('Supabase not connected', 'error'); return; }
  const name = document.getElementById('sd-add-name').value.trim();
  if (!name) { toast('Name is required', 'error'); return; }
  const { error } = await cdSupabase.from('community_members').insert({
    display_name: name,
    role: document.getElementById('sd-add-role').value.trim(),
    about: document.getElementById('sd-add-about').value.trim(),
    photo_url: document.getElementById('sd-add-photo').value.trim(),
    accent_color: document.getElementById('sd-add-color').value,
    discord_username: document.getElementById('sd-add-discord').value.trim(),
    approved: true,
  });
  if (error) { toast('Error: ' + error.message, 'error'); return; }
  toast(`${name} added to SpaceDyn!`, 'success');
  sdHideAddForm();
  sdLoadMembers();
}

async function sdLoadRequests() {
  if (!cdSupabase) return;
  const list = document.getElementById('sd-requests-list');
  const badge = document.getElementById('sd-req-badge');
  list.innerHTML = '<div style="color:var(--muted);font-size:0.82rem;">Loading...</div>';
  const { data, error } = await cdSupabase.from('join_requests').select('*').eq('status', 'pending').order('created_at', { ascending: false });
  if (error) { list.innerHTML = `<div style="color:var(--muted);font-size:0.82rem;">${error.message}</div>`; return; }
  if (!data || !data.length) {
    list.innerHTML = '<div style="color:var(--muted);font-size:0.82rem;">No pending requests.</div>';
    badge.style.display = 'none';
    return;
  }
  badge.style.display = 'inline';
  badge.textContent = data.length;
  list.innerHTML = data.map(r => `
  <div style="background:var(--surface);border:1px solid var(--border-subtle);padding:1rem;margin-bottom:8px;">
    <div style="font-family:'Bebas Neue',sans-serif;font-size:1.2rem;letter-spacing:0.05em;">${r.display_name}</div>
    ${r.discord_username?`<div style="font-size:0.75rem;color:#5865F2;font-family:monospace;margin:2px 0;">@${r.discord_username}</div>`:''}
    ${r.message?`<div style="font-size:0.82rem;color:var(--muted);margin:6px 0;">${r.message}</div>`:''}
    <div style="font-size:0.65rem;color:var(--muted);opacity:0.5;margin-bottom:10px;">${new Date(r.created_at).toLocaleDateString('en-US',{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'})}</div>
    <div class="flex-row">
      <button class="qa-btn primary" onclick="sdApproveRequest('${r.id}','${r.display_name}','${r.discord_username||''}')">✓ Approve</button>
      <button class="qa-btn danger" onclick="sdDenyRequest('${r.id}')">✕ Deny</button>
    </div>
  </div>`).join('');
}

async function sdApproveRequest(rid, name, discord) {
  if (!cdSupabase) return;
  const { error: me } = await cdSupabase.from('community_members').insert({
    display_name: name, discord_username: discord, approved: true,
  });
  if (me) { toast('Error: ' + me.message, 'error'); return; }
  await cdSupabase.from('join_requests').update({ status: 'approved' }).eq('id', rid);
  toast(`${name} approved and added to SpaceDyn!`, 'success');
  sdLoadRequests();
  sdLoadMembers();
}

async function sdDenyRequest(rid) {
  if (!cdSupabase) return;
  await cdSupabase.from('join_requests').update({ status: 'denied' }).eq('id', rid);
  toast('Request denied.', 'success');
  sdLoadRequests();
}

renderTHICC();
init();
// Setup right-click on preview after DOM ready
setTimeout(setupPreviewContextMenu, 500);
// Discord auth check — shows gate if not logged in
setTimeout(cdCheckAuth, 100);
// Handle OAuth redirect
if (cdInitSupabase()) {
  cdSupabase.auth.onAuthStateChange((event) => {
    if (event === 'SIGNED_IN') cdCheckAuth();
  });
}
