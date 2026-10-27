/* ════════════════════════════════════════════════════════════
   PICKME — game-board visuals shared by the overlay and the viewer page
   Wheels, Plinko board, Cliff Hangers mountain, Wheel of Fortune board, Jeopardy board.
   Everything is SVG/HTML that scales with its container. Exposes window.PMS.
   ════════════════════════════════════════════════════════════ */
(function(){
'use strict';
const NS = 'http://www.w3.org/2000/svg';
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const f2 = (n) => Math.round(n * 100) / 100;

/* Wheel of Fortune wedges: same order as pm_pir_wof_wedges() in the SQL */
const WOF = ['2500','600','700','600','650','500','700','BANKRUPT','600','550','500','600',
             'LOSE','650','500','700','BANKRUPT','800','500','650','500','900','550','1000'];
const WOF_FILL = ['#ff3d5a','#34e2ff','#b8ff2e','#ffbe3d','#b691ff','#ff7a3d'];
function wofSegs(){
  return WOF.map((v, i) => v === 'BANKRUPT' ? { label:'BANKRUPT', fill:'#0b0b0b', ink:'#ffffff', small:true }
    : v === 'LOSE' ? { label:'LOSE A TURN', fill:'#ffffff', ink:'#0b0b0b', small:true }
    : v === '2500' || v === '1000' ? { label:'$' + v, fill:'#ffcf4a', ink:'#1a1000' }
    : { label:'$' + v, fill:WOF_FILL[i % WOF_FILL.length], ink:'#0b0518' });
}
/* The Picks Are Right wheel (5..100) */
function pirSegs(values){
  return values.map((v, i) => ({ label:String(v), fill: v === 100 ? '#b8ff2e' : (v === 5 || v === 15) ? '#34e2ff' : (i % 2 ? '#3a1d73' : '#24124a'),
    ink: v === 100 || v === 5 || v === 15 ? '#081200' : '#f1f6e8' }));
}

/* ── spinning wheel: segment i is centred under the pointer at rotation 0 ── */
function wheel(host, segs, opts){
  opts = opts || {};
  const n = segs.length, A = 360 / n;
  host.classList.add('pms-wheel');
  host.innerHTML = '<div class="pms-ptr"></div>';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '-110 -110 220 220');
  let h = '';
  segs.forEach((s, i) => {
    const a0 = (i * A - 90 - A / 2) * Math.PI / 180, a1 = (i * A - 90 + A / 2) * Math.PI / 180;
    h += `<path d="M0 0 L${f2(100 * Math.cos(a0))} ${f2(100 * Math.sin(a0))} A100 100 0 0 1 ${f2(100 * Math.cos(a1))} ${f2(100 * Math.sin(a1))} Z" fill="${s.fill}" stroke="#0e0720" stroke-width="1"/>`;
    const am = i * A - 90;
    if (opts.radial){
      const tx = 94 * Math.cos(am * Math.PI / 180), ty = 94 * Math.sin(am * Math.PI / 180);
      h += `<text x="${f2(tx)}" y="${f2(ty)}" transform="rotate(${f2(am + 180)} ${f2(tx)} ${f2(ty)})" text-anchor="start" dominant-baseline="middle" font-family="Bebas Neue, Impact, sans-serif" font-size="${s.small ? 8 : 11}" fill="${s.ink}">${esc(s.label)}</text>`;
    } else {
      const tx = 76 * Math.cos(am * Math.PI / 180), ty = 76 * Math.sin(am * Math.PI / 180);
      h += `<text x="${f2(tx)}" y="${f2(ty)}" transform="rotate(${f2(am + 90)} ${f2(tx)} ${f2(ty)})" text-anchor="middle" dominant-baseline="middle" font-family="Bebas Neue, Impact, sans-serif" font-size="15" fill="${s.ink}">${esc(s.label)}</text>`;
    }
  });
  h += '<circle r="100" fill="none" stroke="#b8ff2e" stroke-width="3"/><circle r="16" fill="#0e0720" stroke="#b8ff2e" stroke-width="3"/>';
  svg.innerHTML = h;
  host.appendChild(svg);
  let rot = 0;
  return {
    svg,
    /* spin to segment i (index into segs). instant = jump there with no animation */
    spinTo(i, instant){
      if (i == null || i < 0) return;
      const want = ((-(i * A)) % 360 + 360) % 360;
      const cur = ((rot % 360) + 360) % 360;
      const delta = ((want - cur) % 360 + 360) % 360;
      rot += instant ? delta : 360 * 4 + delta;
      svg.style.transition = instant ? 'none' : '';
      svg.style.transform = `rotate(${rot}deg)`;
    },
  };
}

/* ── Plinko: 9 slots, 12 rows of pegs. Positions are half-slots 0..16 ── */
const PX = (x) => 10 + x * 10, PY = (r) => 26 + r * 12;
function plinko(host){
  host.classList.add('pms-plinko');
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 180 210');
  let h = '<rect x="2" y="2" width="176" height="206" rx="8" class="pk-bg"/>';
  for (let k = 0; k < 9; k++) h += `<text x="${PX(2 * k)}" y="14" class="pk-pos" text-anchor="middle">${k + 1}</text>`;
  for (let r = 0; r < 12; r++) for (let p = 0; p <= 16; p++) if (p % 2 === r % 2) h += `<circle cx="${PX(p)}" cy="${PY(r) + 6}" r="1.6" class="pk-peg"/>`;
  for (let k = 0; k <= 9; k++) h += `<line x1="${PX(2 * k - 1)}" y1="${PY(12) + 2}" x2="${PX(2 * k - 1)}" y2="206" class="pk-wall"/>`;
  h += '<g class="pk-slots"></g><g class="pk-landed"></g><g class="pk-live"></g>';
  svg.innerHTML = h;
  host.innerHTML = '';
  host.appendChild(svg);
  const gSlots = svg.querySelector('.pk-slots'), gLanded = svg.querySelector('.pk-landed'), gLive = svg.querySelector('.pk-live');
  let slots = [];
  const landed = new Map();   // slot → count
  const api = {
    svg,
    setSlots(vals){
      if (JSON.stringify(vals) === JSON.stringify(slots)) return;
      slots = vals || [];
      gSlots.innerHTML = slots.map((v, k) => `<rect x="${PX(2 * k - 1) + 1}" y="${PY(12) + 4}" width="18" height="40" rx="3" class="pk-slot ${k === 4 ? 'top' : v === 0 ? 'zero' : ''}" data-k="${k}"/>` +
        `<text x="${PX(2 * k)}" y="${PY(12) + 36}" text-anchor="middle" class="pk-val ${k === 4 ? 'top' : v === 0 ? 'zero' : ''}" font-size="${String(v).length > 3 ? 6 : 8}">${v}</text>`).join('');
    },
    /* animate one chip along its path; resolves when it lands */
    drop(path, o){
      o = o || {};
      return new Promise((resolve) => {
        if (!Array.isArray(path) || path.length < 2){ resolve(); return; }
        const g = document.createElementNS(NS, 'g');
        g.innerHTML = `<circle r="5.2" class="pk-chip" style="fill:${o.color || '#b8ff2e'}"/><text y="2.2" text-anchor="middle" class="pk-chipt">${esc(String(o.label || '').slice(0, 2).toUpperCase())}</text>`;
        gLive.appendChild(g);
        const step = o.fast ? 120 : 260, t0 = performance.now();
        const total = (path.length - 1) * step + step;
        const place = (x, y) => g.setAttribute('transform', `translate(${f2(x)} ${f2(y)})`);
        const tick = (now) => {
          const t = now - t0;
          if (t < step){ place(PX(path[0]), 2 + (PY(0) - 2) * (t / step)); requestAnimationFrame(tick); return; }
          const u = (t - step) / step, r = Math.floor(u);
          if (r >= path.length - 1){
            const k = path[path.length - 1] / 2, cnt = landed.get(k) || 0;
            landed.set(k, cnt + 1);
            place(PX(path[path.length - 1]), PY(12) + 12 + Math.min(cnt, 3) * 3);
            g.classList.add('landed');
            gLive.removeChild(g); gLanded.appendChild(g);
            const rect = gSlots.querySelector(`[data-k="${k}"]`);
            if (rect){ rect.classList.remove('flash'); void rect.getBoundingClientRect(); rect.classList.add('flash'); }
            while (gLanded.childElementCount > 24) gLanded.removeChild(gLanded.firstChild);
            resolve(k);
            return;
          }
          const fr = u - r, x0 = PX(path[r]), x1 = PX(path[r + 1]);
          const ease = fr * fr * (3 - 2 * fr);
          place(x0 + (x1 - x0) * ease, PY(r) + 12 * fr - 5 * Math.sin(Math.PI * fr));
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        setTimeout(() => resolve(), total + 1500);   // never hang if the tab is in the background
      });
    },
    reset(){ landed.clear(); gLanded.innerHTML = ''; gLive.innerHTML = ''; },
  };
  return api;
}

/* ── Cliff Hangers: climbers walk up the slope one step per number they're off ── */
function cliff(host){
  host.classList.add('pms-cliff');
  host.innerHTML = '';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 260 170');
  svg.innerHTML = '<g class="cl-bg"></g><g class="cl-who"></g>';
  host.appendChild(svg);
  let limit = 0;
  const gBg = svg.querySelector('.cl-bg'), gWho = svg.querySelector('.cl-who');
  const SX = (k) => 18 + k * (190 / limit), SY = (k) => 150 - k * (108 / limit);
  function drawBg(){
    let h = `<polygon points="10,160 ${SX(0)},${SY(0)} ${SX(limit)},${SY(limit)} 214,${SY(limit)} 214,160" class="cl-hill"/>`;
    h += `<polygon points="214,${SY(limit)} 222,${SY(limit) + 3} 226,160 214,160" class="cl-edge"/>`;
    for (let k = 0; k <= limit; k++){
      const x = SX(k), y = SY(k);
      h += `<line x1="${f2(x)}" y1="${f2(y)}" x2="${f2(x)}" y2="${f2(y + 3)}" class="cl-tick ${k % 5 === 0 ? 'big' : ''}"/>`;
      if (k % 5 === 0) h += `<text x="${f2(x)}" y="${f2(y + 11)}" text-anchor="middle" class="cl-num">${k}</text>`;
    }
    h += `<text x="238" y="${SY(limit) + 4}" text-anchor="middle" class="cl-warn">FALL!</text>`;
    gBg.innerHTML = h;
  }
  return {
    svg,
    /* list: [{ id, name, steps, out, color }] */
    set(lim, list){
      if (lim !== limit){ limit = lim || 25; drawBg(); }
      const seen = new Set(), stack = new Map();
      (list || []).slice(0, 16).forEach((p) => {
        seen.add(p.id);
        let g = gWho.querySelector(`[data-id="${CSS.escape(p.id)}"]`);
        if (!g){
          g = document.createElementNS(NS, 'g');
          g.setAttribute('data-id', p.id); g.setAttribute('class', 'cl-man');
          g.innerHTML = `<circle r="6.5" style="fill:${p.color || '#b8ff2e'}"/><text y="2.6" text-anchor="middle" class="cl-ini">${esc(String(p.name || '?').slice(0, 1).toUpperCase())}</text><text y="-9" text-anchor="middle" class="cl-name">${esc(String(p.name || '').slice(0, 12))}</text>`;
          g.style.transform = `translate(${SX(0)}px, ${SY(0) - 7}px)`;
          gWho.appendChild(g);
        }
        const k = Math.min(limit, Math.max(0, p.steps || 0));
        const n = stack.get(p.out ? 'out' : k) || 0; stack.set(p.out ? 'out' : k, n + 1);
        const x = p.out ? 236 + (n % 3) * 7 : SX(k), y = p.out ? 156 - Math.floor(n / 3) * 5 : SY(k) - 7 - n * 13;
        g.style.transform = `translate(${f2(x)}px, ${f2(y)}px)` + (p.out ? ' rotate(160deg)' : '');
        g.classList.toggle('out', !!p.out);
        g.classList.toggle('me', !!p.me);
        g.classList.toggle('nolabel', (list || []).length > 3 && !p.me);
      });
      [...gWho.children].forEach(g => { if (!seen.has(g.getAttribute('data-id'))) g.remove(); });
    },
  };
}

/* ── Wheel of Fortune puzzle board: 4 rows × 14 ── */
function wofLayout(mask){
  const words = String(mask || '').split(' ').filter(Boolean);
  const rows = []; let cur = [];
  const len = (ws) => ws.reduce((n, w) => n + w.length, 0) + Math.max(0, ws.length - 1);
  for (const w of words){
    if (!cur.length || len(cur.concat([w])) <= 14) cur.push(w);
    else { rows.push(cur); cur = [w]; }
  }
  if (cur.length) rows.push(cur);
  const top = Math.max(0, Math.floor((4 - rows.length) / 2));
  const cells = [];   // { row, col, i } i = index into mask
  let i = 0;
  rows.forEach((ws, r) => {
    let col = Math.floor((14 - len(ws)) / 2);
    ws.forEach((w, wi) => {
      for (let j = 0; j < w.length; j++) cells.push({ row:top + r, col:col + j, i:i + j });
      col += w.length + 1; i += w.length + 1;
    });
  });
  return cells;
}
function wofBoard(host){
  host.classList.add('pms-wof');
  host.innerHTML = '<div class="wf-grid"></div><div class="wf-cat"></div>';
  const grid = host.querySelector('.wf-grid'), catEl = host.querySelector('.wf-cat');
  for (let r = 0; r < 4; r++) for (let c = 0; c < 14; c++){
    const d = document.createElement('div');
    d.className = 'wf-t' + ((r === 0 || r === 3) && (c === 0 || c === 13) ? ' corner' : '');
    grid.appendChild(d);
  }
  let lastMask = null, lastLayoutKey = '';
  return {
    set(mask, cat){
      catEl.textContent = cat || '';
      mask = String(mask || '');
      const key = mask.replace(/[^ ]/g, 'x');
      const cells = wofLayout(mask);
      const tiles = grid.children;
      if (key !== lastLayoutKey){
        lastLayoutKey = key; lastMask = null;
        [...tiles].forEach(t => { t.className = t.className.replace(/ (on|shown|flash)/g, ''); t.textContent = ''; });
      }
      cells.forEach(({ row, col, i }) => {
        const t = tiles[row * 14 + col]; if (!t) return;
        const ch = mask[i];
        t.classList.add('on');
        const show = ch && ch !== '_';
        if (show && t.textContent !== ch){
          t.textContent = ch;
          t.classList.add('shown');
          if (lastMask != null && /[A-Z]/.test(ch)){ t.classList.remove('flash'); void t.offsetWidth; t.classList.add('flash'); }
        }
      });
      lastMask = mask;
    },
  };
}

/* ── Jeopardy board (HTML grid) ── */
function jboard(host){
  host.classList.add('pms-jb');
  let onPick = null;
  host.addEventListener('click', (e) => {
    const c = e.target.closest('[data-pick]');
    if (c && onPick && host.classList.contains('canpick')) onPick(c.dataset.pick);
  });
  return {
    set(b, o){
      o = o || {};
      onPick = o.onPick || null;
      host.classList.toggle('canpick', !!o.canPick);
      const cats = b.cats || [], vals = b.vals || [], used = b.used || [];
      const cur = b.cur && typeof b.cur === 'object' ? b.cur : null;
      host.style.setProperty('--cols', Math.max(1, cats.length));
      const key = JSON.stringify([cats, vals, used, cur && [cur.c, cur.r, cur.open], !!o.canPick]);
      if (host.dataset.key === key) return;
      host.dataset.key = key;
      let h = cats.map(c => `<div class="jb-cat"><span>${esc(c)}</span></div>`).join('');
      vals.forEach((v, r) => cats.forEach((_, c) => {
        const isUsed = used[c] && used[c][r];
        const isCur = cur && cur.c === c && cur.r === r && cur.open;
        h += `<div class="jb-cell ${isUsed ? 'used' : ''} ${isCur ? 'cur' : ''}" ${isUsed ? '' : `data-pick="${c + 1} ${v}"`}>${isUsed ? '' : '$' + v}</div>`;
      }));
      host.innerHTML = h;
    },
  };
}

/* stable colour per player (for chips / climbers) */
const PAL = ['#b8ff2e', '#34e2ff', '#ff6ad5', '#ffbe3d', '#b691ff', '#ff7a3d', '#7dffb2', '#ff3d5a'];
function colorFor(id){
  let h = 0; for (const ch of String(id || '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return PAL[h % PAL.length];
}

window.PMS = { WOF, wofSegs, pirSegs, wheel, plinko, cliff, wofLayout, wofBoard, jboard, colorFor };
})();
