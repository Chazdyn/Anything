/* ════════════════════════════════════════════════════════════
   PICKME — shared core (hub, dashboard, overlay)
   Needs supabase-js v2 loaded first. Exposes window.PM.
   ════════════════════════════════════════════════════════════ */
(function(){
'use strict';

const CONFIG = {
  supabaseUrl: 'https://lqayctcgprumnvlaktms.supabase.co',
  supabaseAnonKey: 'sb_publishable_tcWWDYpGBbVY1XKVNUaiZw_miMfMiFG',
  channel: 'chazdyn',
  hostName: 'CHAZDYN',
  joinUrl: 'chazdyn.com/pickme',
  storageKey: 'pickme-auth',        // keeps game sign-in separate from Control.Dyn / SpaceDyn
  modScopes: 'user:read:email moderator:manage:chat_messages',
};

/* Games on the site. Add new ones here; the hub and dashboard list them. */
const GAMES = {
  chatsays: { name:'Chat Says', blurb:'Chat answers a survey, then the board gets revealed. Beat the host or beat each other.' },
};
const MODES = {
  versus: { name:'Host vs Chat', short:'VS', blurb:'The host guesses the board. Every answer the host misses pays the viewers who said it.' },
  crowd:  { name:'Chat vs Chat', short:'CROWD', blurb:'No host guessing. Every tile pays the viewers who said it, so think like the crowd.' },
};
const REASONS = {
  blocked:'You are blocked from this game.',
  not_whitelisted:'This session is invite-only right now.',
  closed:'This session is closed to new players.',
  ended:'This session has ended.',
  no_session:'There is no live session right now.',
  round_closed:'Too late, the survey just closed.',
  already:'You already answered this one.',
  questions_closed:'Questions are not open right now.',
  limit:'You already have 3 questions waiting.',
  too_short:'That question is too short.',
  empty:'Type an answer first.',
  no_profile:'Sign in with Twitch first.',
};
const reason = (code) => REASONS[code] || code;

/* ── Supabase client ── */
let SB = null;
function client(opts){
  if (SB) return SB;
  if (!window.supabase) throw new Error('supabase-js failed to load');
  const anonOnly = opts && opts.anonOnly;
  SB = window.supabase.createClient(CONFIG.supabaseUrl, CONFIG.supabaseAnonKey, {
    auth: anonOnly
      ? { persistSession:false, autoRefreshToken:false, detectSessionInUrl:false, storageKey: CONFIG.storageKey + '-overlay' }
      : { persistSession:true, autoRefreshToken:true, detectSessionInUrl:true, storageKey: CONFIG.storageKey },
    realtime: { params: { eventsPerSecond: 10 } },
  });
  return SB;
}

/* ── Server clock (countdowns agree on every device) ── */
let clockOffset = 0;
async function syncClock(){
  const sb = client();
  let best = null;
  for (let i = 0; i < 3; i++){
    const t0 = Date.now();
    const { data, error } = await sb.rpc('pm_now');
    const t1 = Date.now();
    if (error || !data) continue;
    const rtt = t1 - t0;
    const off = new Date(data).getTime() - (t0 + t1) / 2;
    if (!best || rtt < best.rtt) best = { rtt, off };
  }
  if (best) clockOffset = best.off;
  return clockOffset;
}
const serverNow = () => Date.now() + clockOffset;

/* ── State ── */
function defaultState(){
  return { phase:'idle', game:'chatsays', mode:'versus', scene:'game', hidden:false,
           sessionId:null, sessionTitle:'', sessionStatus:null, questionCall:false, chatAnswers:true,
           roundNo:0, roundId:null, question:'', closesAt:null, seconds:45, topN:5,
           board:[], overflow:[], total:0, strikes:0,
           scores:{ host:0, chat:0 }, round:{ host:0, chat:0, paid:0 }, roundTop:[],
           lastGuess:null, result:null, notice:null, hostName: CONFIG.hostName };
}
function normalizeState(d){
  const s = Object.assign(defaultState(), d || {});
  s.scores = Object.assign({ host:0, chat:0 }, s.scores || {});
  s.round  = Object.assign({ host:0, chat:0, paid:0 }, s.round || {});
  s.roundTop = Array.isArray(s.roundTop) ? s.roundTop : [];
  s.board = Array.isArray(s.board) ? s.board : [];
  s.overflow = Array.isArray(s.overflow) ? s.overflow : [];
  return s;
}
async function fetchState(){
  const { data, error } = await client().from('pm_state').select('data, updated_at').eq('key', 'live').maybeSingle();
  if (error) throw error;
  return { state: normalizeState(data && data.data), updatedAt: data && data.updated_at };
}
/* Realtime + polling fallback. cb(state) fires only when the row changed. */
function watchState(cb, pollMs){
  let last = '';
  const deliver = (row) => {
    if (!row) return;
    const key = (row.updated_at || '') + '|' + JSON.stringify(row.data || {}).length;
    if (key === last) return;
    last = key;
    try { cb(normalizeState(row.data)); }
    catch (e) { console.error('PickMe render error:', e); }
  };
  const poll = async () => {
    try {
      const { data } = await client().from('pm_state').select('data, updated_at').eq('key', 'live').maybeSingle();
      deliver(data);
    } catch (e) { /* offline blip; next poll retries */ }
  };
  poll();
  const timer = setInterval(poll, pollMs || 3000);
  let channel = null;
  try {
    channel = client().channel('pm-state')
      .on('postgres_changes', { event:'*', schema:'public', table:'pm_state', filter:'key=eq.live' }, (p) => deliver(p.new))
      .subscribe();
  } catch (e) { /* polling still runs */ }
  return () => { clearInterval(timer); if (channel) client().removeChannel(channel); };
}

/* ── Answer normalisation + grouping ── */
const LEAD = new Set(['a','an','the','my','some','your','his','her','their','our','its','uh','um']);
function singular(w){
  if (w.length <= 3) return w;
  if (/ies$/.test(w)) return w.slice(0, -3) + 'y';
  if (/(ss|us|is|os)$/.test(w)) return w;
  if (/(ches|shes|xes|zes|sses)$/.test(w)) return w.slice(0, -2);
  if (/s$/.test(w)) return w.slice(0, -1);
  return w;
}
function normalize(text){
  let s = String(text || '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase();
  s = s.replace(/['’`]/g, '').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();
  if (!s) return '';
  let w = s.split(' ');
  while (w.length > 1 && LEAD.has(w[0])) w.shift();
  return w.map(singular).join(' ');
}
function lev(a, b, max){
  // optimal string alignment distance (counts a swapped pair as one edit)
  if (a === b) return 0;
  if (Math.abs(a.length - b.length) > max) return max + 1;
  const n = a.length, m = b.length;
  const d = Array.from({ length: n + 1 }, (_, i) => { const r = new Array(m + 1).fill(0); r[0] = i; return r; });
  for (let j = 0; j <= m; j++) d[0][j] = j;
  for (let i = 1; i <= n; i++){
    let rowMin = Infinity;
    for (let j = 1; j <= m; j++){
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      let v = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) v = Math.min(v, d[i - 2][j - 2] + 1);
      d[i][j] = v;
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > max) return max + 1;
  }
  return d[n][m];
}
function similar(a, b){
  if (!a || !b) return false;
  if (a === b) return true;
  const na = a.replace(/ /g, ''), nb = b.replace(/ /g, '');
  if (na === nb) return true;
  const L = Math.min(na.length, nb.length);
  if (L < 4) return false;
  const max = L >= 8 ? 2 : 1;
  return lev(na, nb, max) <= max;
}
const containsWord = (hay, needle) => needle.length >= 4 && (' ' + hay + ' ').includes(' ' + needle + ' ');

function prettyLabel(raw){
  let s = String(raw || '').replace(/\s+/g, ' ').trim();
  if (s.length > 30) s = s.slice(0, 29).trim() + '…';
  return s;
}

/* answers: [{answer, created_at}] → { board, overflow, total } */
function cluster(answers, topN){
  const byKey = new Map();
  let order = 0;
  for (const a of answers){
    const key = normalize(a.answer);
    if (!key) continue;
    let e = byKey.get(key);
    if (!e){ e = { key, count:0, forms:new Map(), first: order++ }; byKey.set(key, e); }
    e.count++;
    const form = prettyLabel(a.answer);
    e.forms.set(form, (e.forms.get(form) || 0) + 1);
  }
  const entries = [...byKey.values()].sort((x, y) => y.count - x.count || x.first - y.first);
  const groups = [];
  for (const e of entries){
    const g = groups.find(g => g.keys.some(k => similar(k, e.key)))
         || groups.find(g => g.keys.some(k => containsWord(e.key, k) || containsWord(k, e.key)));
    if (g){
      g.count += e.count; g.keys.push(e.key);
      for (const [f, n] of e.forms) g.forms.set(f, (g.forms.get(f) || 0) + n);
    } else {
      groups.push({ keys:[e.key], count:e.count, forms:new Map(e.forms), first:e.first });
    }
  }
  groups.sort((x, y) => y.count - x.count || x.first - y.first);
  const shape = (g) => {
    let label = '', best = -1;
    for (const [f, n] of g.forms) if (n > best){ best = n; label = f; }
    return { label, count:g.count, key:g.keys[0], keys:g.keys.slice(0, 40), revealed:false, by:null };
  };
  const keyOf = new Map();
  for (const g of groups) for (const k of g.keys) keyOf.set(k, g.keys[0]);
  const total = entries.reduce((n, e) => n + e.count, 0);
  return {
    board: groups.slice(0, topN).map(shape),
    overflow: groups.slice(topN, topN + 25).map(g => { const t = shape(g); t.keys = t.keys.slice(0, 12); delete t.revealed; delete t.by; return t; }),
    total,
    keyOf,   // normalized answer → its group's key (for paying players per tile)
  };
}

/* Which tile (if any) does a guess or a viewer's answer land on?
   → { type:'hit'|'dupe'|'offboard'|'miss', idx, count } */
function scoreMatch(tile, g){
  let best = 0;
  for (const k of tile.keys || []){
    if (k === g) return 3;
    if (similar(k, g)) best = Math.max(best, 2);
    else if (containsWord(k, g) || containsWord(g, k)) best = Math.max(best, 1);
  }
  return best;
}
function matchGuess(board, overflow, text){
  const g = normalize(text);
  if (!g) return { type:'empty' };
  let pick = -1, pickRank = 0, pickScore = 0;
  (board || []).forEach((t, i) => {
    const sc = scoreMatch(t, g);
    if (!sc) return;
    const rank = sc * 2 + (t.revealed ? 0 : 1);   // stronger match first, then unrevealed tiles
    if (rank > pickRank){ pickRank = rank; pick = i; pickScore = sc; }
  });
  let off = null, offScore = 0;
  for (const t of overflow || []){
    const sc = scoreMatch(t, g);
    if (sc > offScore){ offScore = sc; off = t; }
  }
  if (pick >= 0 && pickScore >= offScore) return { type: board[pick].revealed ? 'dupe' : 'hit', idx: pick, count: board[pick].count };
  if (off) return { type:'offboard', count:off.count, label:off.label };
  return { type:'miss' };
}

/* ── Identity helpers ── */
function twitchIdentity(user){
  return (user && user.identities || []).find(i => i.provider === 'twitch') || null;
}
function displayName(user){
  if (!user) return '';
  const d = (twitchIdentity(user) || {}).identity_data || user.user_metadata || {};
  return d.nickname || d.slug || d.name || d.preferred_username || d.full_name || user.email || 'you';
}
function avatarUrl(user){
  const d = (twitchIdentity(user) || {}).identity_data || (user && user.user_metadata) || {};
  return d.avatar_url || d.picture || '';
}
async function signInTwitch(redirectTo, scopes){
  const options = { redirectTo: redirectTo || location.href.split('#')[0].split('?')[0] };
  if (scopes) options.scopes = scopes;
  return client().auth.signInWithOAuth({ provider:'twitch', options });
}
async function signInDiscord(redirectTo){
  return client().auth.signInWithOAuth({ provider:'discord', options:{ redirectTo: redirectTo || location.href.split('#')[0].split('?')[0] } });
}

/* ── Sound (synth fallback; drop mp3s in assets/ to override) ── */
const Sound = (() => {
  let ctx = null, master = null, volume = 0.6, enabled = true;
  const files = {};
  function ac(){
    if (!ctx){
      const C = window.AudioContext || window.webkitAudioContext;
      if (!C) return null;
      ctx = new C(); master = ctx.createGain(); master.gain.value = volume; master.connect(ctx.destination);
    }
    if (ctx.state === 'suspended') ctx.resume().catch(() => {});
    return ctx;
  }
  function tone(freq, start, dur, type, gain, toFreq){
    const c = ac(); if (!c) return;
    const o = c.createOscillator(), g = c.createGain();
    o.type = type || 'sine';
    o.frequency.setValueAtTime(freq, c.currentTime + start);
    if (toFreq) o.frequency.exponentialRampToValueAtTime(toFreq, c.currentTime + start + dur);
    g.gain.setValueAtTime(0.0001, c.currentTime + start);
    g.gain.exponentialRampToValueAtTime(gain || 0.3, c.currentTime + start + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + start + dur);
    o.connect(g); g.connect(master);
    o.start(c.currentTime + start); o.stop(c.currentTime + start + dur + 0.05);
  }
  const synth = {
    ding(){ tone(1046.5, 0, 0.9, 'triangle', 0.35); tone(1568, 0.06, 1.0, 'sine', 0.22); tone(2093, 0.06, 0.6, 'sine', 0.08); },
    chat(){ tone(659, 0, 0.5, 'triangle', 0.25); tone(988, 0.05, 0.6, 'sine', 0.15); },
    buzz(){
      const c = ac(); if (!c) return;
      const f = c.createBiquadFilter(); f.type = 'lowpass'; f.frequency.value = 900; f.connect(master);
      [98, 103.5].forEach((hz, i) => {
        const o = c.createOscillator(), g = c.createGain();
        o.type = i ? 'square' : 'sawtooth'; o.frequency.value = hz;
        g.gain.setValueAtTime(0.0001, c.currentTime);
        g.gain.exponentialRampToValueAtTime(0.35, c.currentTime + 0.02);
        g.gain.setValueAtTime(0.35, c.currentTime + 0.6);
        g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + 0.8);
        o.connect(g); g.connect(f); o.start(); o.stop(c.currentTime + 0.85);
      });
    },
    tick(){ tone(1400, 0, 0.05, 'square', 0.08); },
    open(){ tone(330, 0, 0.35, 'sawtooth', 0.12, 990); tone(660, 0.12, 0.45, 'triangle', 0.18, 1320); },
    lock(){ [523, 659, 784].forEach((f, i) => tone(f, i * 0.07, 0.5, 'triangle', 0.2)); },
    win(){ [523, 659, 784, 1046].forEach((f, i) => tone(f, i * 0.11, 0.7, 'triangle', 0.25)); tone(1318, 0.45, 1.1, 'sine', 0.18); },
  };
  return {
    setVolume(v){ volume = v; if (master) master.gain.value = v; },
    setEnabled(v){ enabled = !!v; },
    preload(base){
      ['ding','chat','buzz','tick','open','lock','win'].forEach(n => {
        const a = new Audio(); a.preload = 'auto';
        a.addEventListener('canplaythrough', () => { files[n] = a; }, { once:true });
        a.addEventListener('error', () => {}, { once:true });
        a.src = base + n + '.mp3';
      });
    },
    unlock(){ ac(); },
    play(name){
      if (!enabled) return;
      const f = files[name];
      if (f){ try { const a = f.cloneNode(); a.volume = Math.min(1, volume); a.play().catch(() => synth[name] && synth[name]()); return; } catch (e) {} }
      if (synth[name]) synth[name]();
    },
  };
})();

/* "Picks" — the game currency (guitar pick). small = thicker strokes for tiny sizes */
function pickSVG(cls, small){
  const w = small ? [8, 7] : [5, 4.5];
  return `<svg class="pick ${cls || ''}" viewBox="0 0 100 100" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">` +
    `<path stroke-width="${w[0]}" d="M48 93 C40 93 12 63 10 39 C8.5 21 20 9.5 50 9.5 C80 9.5 91 21 89.5 39 C87.5 63 56 93 48 93 Z"/>` +
    `<path stroke-width="${w[1]}" d="M57 17.5 C71 17.5 80 24 80.5 39"/><path stroke-width="${w[1]}" d="M77 56 C72.5 66 65.5 75 57 81"/></svg>`;
}
const picks = (n) => n + (n === 1 ? ' Pick' : ' Picks');

/* ── Twitch: anonymous chat reader + moderation helpers (dashboard) ── */
const Twitch = {
  /* Reads chat anonymously over IRC. onMsg({id, userId, login, display, text, mod, broadcaster}) */
  chat(channel, onMsg, onStatus){
    let ws = null, stop = false, backoff = 1000;
    const unesc = (v) => String(v || '').replace(/\\s/g, ' ').replace(/\\:/g, ';').replace(/\\\\/g, '\\').replace(/\\r/g, '').replace(/\\n/g, '');
    const open = () => {
      if (stop) return;
      onStatus && onStatus('connecting');
      ws = new WebSocket('wss://irc-ws.chat.twitch.tv:443');
      ws.onopen = () => {
        ws.send('CAP REQ :twitch.tv/tags twitch.tv/commands');
        ws.send('PASS SCHMOOPIIE');
        ws.send('NICK justinfan' + (10000 + Math.floor(Math.random() * 80000)));
        ws.send('JOIN #' + channel.toLowerCase());
      };
      ws.onmessage = (e) => {
        for (const line of String(e.data).split('\r\n')){
          if (!line) continue;
          if (line.startsWith('PING')){ ws.send('PONG' + line.slice(4)); continue; }
          let rest = line, tags = {};
          if (rest[0] === '@'){
            const sp = rest.indexOf(' ');
            rest.slice(1, sp).split(';').forEach(kv => { const i = kv.indexOf('='); tags[kv.slice(0, i)] = unesc(kv.slice(i + 1)); });
            rest = rest.slice(sp + 1);
          }
          let prefix = '';
          if (rest[0] === ':'){ const sp = rest.indexOf(' '); prefix = rest.slice(1, sp); rest = rest.slice(sp + 1); }
          const cmd = rest.split(' ')[0];
          if (cmd === '366' || cmd === 'JOIN'){ backoff = 1000; onStatus && onStatus('connected'); continue; }
          if (cmd === 'RECONNECT'){ try { ws.close(); } catch (x) {} continue; }
          if (cmd !== 'PRIVMSG') continue;
          const idx = rest.indexOf(' :');
          let text = idx >= 0 ? rest.slice(idx + 2) : '';
          if (text.startsWith('\u0001ACTION ')) text = text.slice(8, -1);
          const badges = tags.badges || '';
          onMsg({ id: tags.id, userId: tags['user-id'], login: prefix.split('!')[0], display: tags['display-name'] || prefix.split('!')[0],
                  text, mod: tags.mod === '1', broadcaster: /(^|,)broadcaster\//.test(badges) });
        }
      };
      ws.onclose = () => { onStatus && onStatus('disconnected'); if (!stop) setTimeout(open, backoff); backoff = Math.min(backoff * 2, 30000); };
      ws.onerror = () => { try { ws.close(); } catch (x) {} };
    };
    open();
    return () => { stop = true; try { ws && ws.close(); } catch (x) {} };
  },
  async validate(token){
    const r = await fetch('https://id.twitch.tv/oauth2/validate', { headers:{ Authorization:'OAuth ' + token } });
    if (!r.ok) return null;
    return r.json();   // { client_id, login, user_id, scopes, expires_in }
  },
  async helix(token, clientId, method, path){
    return fetch('https://api.twitch.tv/helix/' + path, { method, headers:{ Authorization:'Bearer ' + token, 'Client-Id': clientId } });
  },
};

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));

const timeAgo = (iso) => {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return Math.floor(s) + 's ago';
  if (s < 3600) return Math.floor(s / 60) + 'm ago';
  if (s < 86400) return Math.floor(s / 3600) + 'h ago';
  return Math.floor(s / 86400) + 'd ago';
};

window.PM = { CONFIG, GAMES, MODES, REASONS, reason, client, syncClock, serverNow, defaultState, normalizeState, fetchState, watchState,
              normalize, similar, cluster, matchGuess, twitchIdentity, displayName, avatarUrl,
              signInTwitch, signInDiscord, Sound, Twitch, esc, pickSVG, picks, timeAgo };
})();
