// Siftr's screen, shared parts. The app (Swift) owns the rules, the
// playback and the visualizer math; the page draws what it's sent and
// reports clicks back. Page scripts (sift.js, library.js, now.js, stats.js,
// backup.js) build on what's here.
'use strict';

const App = {
  page: 'sift',
  now: null,            // what's playing (the "now" event)
  sift: null,           // the Sifting page's state
  settings: null,
  lyrics: null,         // lyrics status (the "lyrics" event)
  volume: 70,
  colors: ['#5478ff', '#966eff', '#ff78be'],
  handlers: {},
  debug: [],
};

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
};
const clamp01 = (v) => Math.min(Math.max(v, 0), 1);
const fmt = (s) => {
  s = Number.isFinite(s) ? Math.max(0, Math.floor(s)) : 0;
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};
const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? '' : 's'}`;
/** Over this (seconds), a song plays without the visualizer or lyrics (SifterCore's longSongSeconds). */
const LONG_SONG = 20 * 60;
/** Sets text only if it changed: rewriting identical text still costs a repaint, every frame. */
const setText = (e, text) => { if (e.textContent !== text) e.textContent = text; };

function post(type, extra) {
  try { window.webkit.messageHandlers.sifter.postMessage(Object.assign({ type }, extra || {})); } catch (_) { /* not in the app */ }
}

/** Asks the app a question; the answer comes back as JSON. */
async function api(name, args) {
  try {
    const reply = await window.webkit.messageHandlers.api.postMessage({ name, args: args || {} });
    return JSON.parse(reply);
  } catch (_) {
    return null;
  }
}

function on(name, fn) { (App.handlers[name] = App.handlers[name] || []).push(fn); }
function emit(name, data) {
  for (const fn of App.handlers[name] || []) {
    try { fn(data); } catch (e) { console.error(name, e); }
  }
}

const artURL = (kind, id, size) => `sifter://app/art/${kind}/${encodeURIComponent(id)}${size ? `?s=${size}` : ''}`;

/** A small cover tile that loads only when it scrolls into view. */
function thumb(kind, id, size = 40, cls = 'thumb') {
  const box = el('div', cls);
  const img = el('img');
  img.loading = 'lazy';
  img.decoding = 'async';
  img.alt = '';
  img.addEventListener('error', () => img.classList.add('missing'));
  img.src = artURL(kind, id, size);
  box.append(img);
  return box;
}

function timeAgo(epoch) {
  if (!epoch) return '';
  const days = Math.floor((Date.now() / 1000 - epoch) / 86400);
  const d = new Date(epoch * 1000);
  if (days < 1 && new Date().toDateString() === d.toDateString()) {
    return `today, ${d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`;
  }
  if (days < 2) return 'yesterday';
  if (days < 30) return `${days} days ago`;
  return d.toLocaleDateString([], { month: 'short', day: 'numeric', year: 'numeric' });
}

function formatListening(secs) {
  const m = Math.round((secs || 0) / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  return h < 48 ? `${h} h ${m % 60} min` : `${Math.round(h / 24 * 10) / 10} days`;
}

let toastTimer = 0;
function toast(message) {
  const t = $('toast');
  t.textContent = message;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2600);
}

// ------------------------------------------------------------- pages
function showPage(name, tell = true) {
  App.page = name;
  document.body.dataset.page = name;
  if (tell) post('page', { name });
  emit('page', name);
}
for (const b of document.querySelectorAll('[data-goto]')) b.addEventListener('click', () => showPage(b.dataset.goto));
for (const b of document.querySelectorAll('[data-open]')) b.addEventListener('click', () => post('open'));

// ------------------------------------------------------------- looks
// The colors of the visualizer, progress bars, lyrics and leaderboard:
// low, middle, high. Aurora is this app's own; the rest come from the
// Python app's Colors panel.
const LOOKS = {
  Aurora: ['#5478ff', '#966eff', '#ff78be'],
  Hilltop: ['#ff1a1a', '#808080', '#000000'],
  Original: ['#0020ff', '#7a00ff', '#ff00d4'],
  Sunset: ['#7a00ff', '#ff2e63', '#ffb300'],
  Ocean: ['#0033cc', '#0091ff', '#00e5c7'],
  Forest: ['#00695c', '#00c853', '#c6ff00'],
  Fire: ['#c62828', '#ff5722', '#ffc400'],
};
const isColors = (c) => Array.isArray(c) && c.length === 3 && c.every((x) => /^#[0-9a-f]{6}$/i.test(x));
const hexRGB = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

function applyColors(colors) {
  if (!isColors(colors)) colors = LOOKS.Aurora;
  App.colors = colors;
  const root = document.documentElement.style;
  root.setProperty('--g1', colors[0]);
  root.setProperty('--g2', colors[1]);
  root.setProperty('--g3', colors[2]);
  const dark = darkScheme.matches;
  colors.forEach((c, i) => root.setProperty(`--w${i + 1}`, readable(c, dark)));
  emit('colors', colors);
}

// The name in Settings' footer, in the look's colors: lightened (dark mode)
// or darkened just enough to read against the background (3:1, the bar for
// large text). Hilltop ends in black.
const darkScheme = matchMedia('(prefers-color-scheme: dark)');
darkScheme.addEventListener('change', () => applyColors(App.colors));
function readable(hex, dark) {
  const lum = (rgb) => rgb.map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
    .reduce((sum, c, i) => sum + c * [0.2126, 0.7152, 0.0722][i], 0);
  const bg = lum(dark ? [0x12, 0x13, 0x1c].map((c) => c / 255) : [0xf4, 0xf5, 0xf9].map((c) => c / 255));
  const rgb = hexRGB(hex).map((c) => c / 255);
  const toward = dark ? 1 : 0;
  for (let step = 0; step <= 10; step++) {
    const mixed = rgb.map((c) => c + (toward - c) * (step / 10));
    const l = lum(mixed);
    if ((Math.max(l, bg) + 0.05) / (Math.min(l, bg) + 0.05) >= 3) {
      return `rgb(${mixed.map((c) => Math.round(c * 255)).join(' ')})`;
    }
  }
  return dark ? '#fff' : '#000';
}

// ------------------------------------------------------------- the visualizer
// The visualizer: the app draws the bars natively, over this spot. (The web
// engine redrawing a canvas 30 times a second cost more than the rest of the
// app put together.) The page just says where the spot is -- or that none is
// showing, when its page is hidden or something covers it.
class Bars {
  constructor(el, { reflection = true } = {}) {
    this.el = el;
    this.reflection = reflection;
    Bars.all.push(this);
    // Its size changing moves the bars -- and so does anything next to it
    // changing size (a title on two lines, the Edit button showing up) or its
    // column scrolling, even when the spot itself stays the same size.
    const watch = new ResizeObserver(() => Bars.report());
    for (const e of el.parentElement.children) watch.observe(e);
    el.parentElement.addEventListener('scroll', () => Bars.report(), { passive: true });
  }

  set() {}                                    // drawn by the app

  static report() {
    if (Bars.pending) return;
    Bars.pending = requestAnimationFrame(() => { Bars.pending = 0; Bars.send(); });
  }

  static send() {
    const covered = !$('settings').hidden || !$('drop').hidden;
    let spot = {};
    for (const b of Bars.all) {
      if (covered || b.el.hidden || !b.el.offsetParent) continue;
      const r = b.el.getBoundingClientRect();
      if (r.width < 1 || r.height < 40) continue;          // too short to show anything (a small window)
      spot = { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height),
               reflection: b.reflection, colors: App.colors };
      break;
    }
    const key = JSON.stringify(spot);
    if (key === Bars.last) return;
    Bars.last = key;
    post('viz', spot);
  }
}
Bars.all = [];
Bars.pending = 0;
Bars.last = null;
on('page', () => Bars.report());
on('colors', () => Bars.report());
on('colors', (colors) => post('colors', { colors }));      // the mark beside the name, in the toolbar
window.addEventListener('resize', () => Bars.report());

// ------------------------------------------------------------- seek bars
// Click or drag anywhere; the bar follows the pointer and the jump happens
// on release.
function makeSeek(root, onSeek) {
  let dragging = false, frac = 0, pos = 0, dur = 0;
  const s = {
    onRender: null,
    get dragging() { return dragging; },
    update(p, d) { pos = p; dur = d; if (!dragging) render(); },
    setEnabled(yes) { root.classList.toggle('off', !yes); },
  };
  let shown = '';
  function render() {
    const f = dragging ? frac : (dur > 0 ? clamp01(pos / dur) : 0);
    const p = f.toFixed(3);                   // a tenth of a percent: finer isn't visible
    if (p !== shown) { shown = p; root.style.setProperty('--p', p); }
    if (s.onRender) s.onRender(dragging ? frac * dur : pos, dur);
  }
  const at = (e) => { const r = root.getBoundingClientRect(); return clamp01((e.clientX - r.left) / r.width); };
  root.addEventListener('pointerdown', (e) => {
    if (root.classList.contains('off')) return;
    dragging = true;
    root.classList.add('dragging');
    try { root.setPointerCapture(e.pointerId); } catch (_) { /* synthetic pointer */ }
    frac = at(e);
    render();
    e.preventDefault();
  });
  root.addEventListener('pointermove', (e) => { if (dragging) { frac = at(e); render(); } });
  root.addEventListener('pointerup', (e) => {
    if (!dragging) return;
    frac = at(e);
    dragging = false;
    root.classList.remove('dragging');
    pos = frac * dur;                    // stay there until the app confirms
    render();
    onSeek(frac);
  });
  root.addEventListener('pointercancel', () => { dragging = false; root.classList.remove('dragging'); render(); });
  return s;
}

// ------------------------------------------------------------- volume
let volumeHeld = null;
function setVolume(v) {
  App.volume = v;
  for (const input of document.querySelectorAll('input.vol')) {
    if (input === volumeHeld) continue;          // don't fight a slider being dragged
    input.value = String(v);
    input.style.setProperty('--v', `${v}%`);
  }
}
for (const input of document.querySelectorAll('input.vol')) {
  input.addEventListener('pointerdown', () => { volumeHeld = input; });
  input.addEventListener('input', () => {
    input.style.setProperty('--v', `${input.value}%`);
    post('volume', { value: Number(input.value) });
  });
  const release = () => { volumeHeld = null; input.blur(); setVolume(Number(input.value)); };
  input.addEventListener('change', release);
  input.addEventListener('pointerup', release);
}

// ------------------------------------------------------------- the mini player
const mini = { seek: makeSeek($('mini-seek'), (f) => post('seek', { fraction: f })) };
mini.seek.onRender = (p, d) => { setText($('mini-pos'), fmt(p)); setText($('mini-dur'), fmt(d)); };

function updateMini() {
  const n = App.now;
  const browsing = ['library', 'top', 'trends', 'backup'].includes(App.page);
  const show = !!(n && n.kind) && (browsing || (App.page === 'sift' && n.kind === 'library'));
  document.body.classList.toggle('has-mini', show);
  $('mini').hidden = !show;
  if (!show) return;
  $('mini-title').textContent = n.title;
  $('mini-artist').textContent = n.artist || n.album || '';
  $('mini-play').classList.toggle('playing', n.playing);
  $('mini-prev').disabled = !n.canPrev;
  $('mini-next').disabled = !n.canNext;
  const img = $('mini-img');
  if (img.dataset.src !== n.art) {
    img.dataset.src = n.art;
    img.hidden = true;
    img.src = n.art + '?s=48';
  }
  mini.seek.update(n.position, n.duration);
}
$('mini-img').addEventListener('load', () => { $('mini-img').hidden = false; });
$('mini-img').addEventListener('error', () => { $('mini-img').hidden = true; });
$('mini-play').addEventListener('click', () => post('toggle'));
$('mini-prev').addEventListener('click', () => post('prev'));
$('mini-next').addEventListener('click', () => post('next'));
$('mini-open').addEventListener('click', () => showPage('now'));
$('mini-now').addEventListener('click', () => showPage('now'));
on('now', updateMini);
on('page', updateMini);
on('frame', (f) => {
  if (!App.now || f.kind !== App.now.kind || $('mini').hidden) return;
  mini.seek.update(f.pos, f.dur);
  $('mini-play').classList.toggle('playing', f.playing);
});

// ------------------------------------------------------------- the tint behind the page
// The playing song's most colorful cover color (worked out once per song
// from a tiny copy of it) tints the top of the page; without a cover, the look's.
const ambientImg = new Image();
ambientImg.decoding = 'async';
ambientImg.addEventListener('load', () => {
  try {
    const c = document.createElement('canvas');
    c.width = c.height = 12;
    const g = c.getContext('2d', { willReadFrequently: true });
    g.drawImage(ambientImg, 0, 0, 12, 12);
    const px = g.getImageData(0, 0, 12, 12).data;
    let best = null, bestScore = -1, sum = [0, 0, 0];
    for (let i = 0; i < px.length; i += 4) {
      const [r, gr, b] = [px[i], px[i + 1], px[i + 2]];
      sum[0] += r; sum[1] += gr; sum[2] += b;
      const max = Math.max(r, gr, b), min = Math.min(r, gr, b);
      const score = (max - min) * (0.4 + max / 255);          // colorful and not too dark
      if (score > bestScore) { bestScore = score; best = [r, gr, b]; }
    }
    const avg = sum.map((v) => Math.round(v / (px.length / 4)));
    setAmbient(best || avg);
  } catch (_) { setAmbient(null); }
});
ambientImg.addEventListener('error', () => setAmbient(null));

function setAmbient(a) {
  const c = a || hexRGB(App.colors[0]);
  document.documentElement.style.setProperty('--amb', `rgb(${c[0]},${c[1]},${c[2]})`);
}
on('now', (n) => {
  const src = n && n.kind && !n.error ? `${n.art}?s=24` : '';
  if (ambientImg.dataset.src === src) return;
  ambientImg.dataset.src = src;
  if (src) ambientImg.src = src; else setAmbient(null);
});
on('colors', () => { if (!ambientImg.dataset.src) setAmbient(null); });

// ------------------------------------------------------------- settings
function openSettings() {
  renderSettings();
  $('settings').hidden = false;
  drawVizSample(vizSettings());              // needs the sheet on screen to know its width
  Bars.report();
}
function closeSettings() { $('settings').hidden = true; Bars.report(); }
$('settings').addEventListener('mousedown', (e) => { if (e.target === $('settings')) closeSettings(); });
for (const b of document.querySelectorAll('[data-close]')) b.addEventListener('click', closeSettings);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('settings').hidden) closeSettings(); });

function customLooks() { return (App.settings && App.settings.customLooks) || []; }
function currentLook() { return (App.settings && App.settings.look) || 'Aurora'; }

function saveSettings(change) {
  App.settings = Object.assign({}, App.settings, change);
  post('saveSettings', change);
}

function pickLook(name, colors) {
  applyColors(colors);
  saveSettings({ look: name, colors });
  markLooks();
}

/** A switch: one button that says on or off, to CSS (data-state) and to VoiceOver (role, aria-checked) alike. */
function setSwitch(b, on) {
  b.setAttribute('role', 'switch');
  b.setAttribute('aria-checked', String(on));
  b.dataset.state = on ? 'on' : 'off';
}

// ---------- the visualizer's bars: how many, how tall (the app draws them)
const VIZ_DEFAULT = { bars: 96, height: 85 };
function vizSettings() {
  const s = App.settings || {};
  return { bars: s.vizBars || VIZ_DEFAULT.bars, height: s.vizHeight || VIZ_DEFAULT.height };
}
function renderViz() {
  const v = vizSettings();
  setSwitch($('viz-calm'), !!(App.settings && App.settings.vizCalm));
  for (const [id, val, text] of [['viz-bars', v.bars, String(v.bars)], ['viz-height', v.height, `${v.height}%`]]) {
    const input = $(id);
    input.value = val;
    input.style.setProperty('--v', `${((val - input.min) / (input.max - input.min)) * 100}%`);
    $(`${id}-v`).textContent = text;
  }
  drawVizSample(v);
}
// A still sample of the bars -- drawn only when a slider moves, never animated
function drawVizSample(v) {
  const c = $('viz-sample'), dpr = window.devicePixelRatio || 1;
  const W = Math.round(c.clientWidth * dpr), H = Math.round(c.clientHeight * dpr);
  if (!W || !H) return;
  c.width = W; c.height = H;
  const g = c.getContext('2d');
  const [low, mid, high] = App.colors.map(hexRGB);
  const fill = g.createLinearGradient(0, H, 0, 0);
  fill.addColorStop(0, `rgb(${low})`); fill.addColorStop(0.5, `rgb(${mid})`); fill.addColorStop(1, `rgb(${high})`);
  g.fillStyle = fill;
  const n = v.bars, gap = Math.min(2.5, Math.max(1, W / dpr / n * 0.3)) * dpr, bw = Math.max((W - gap * (n - 1)) / n, 1);
  g.beginPath();
  for (let b = 0; b < n; b++) {
    const x = b / (n - 1);          // a typical song's shape: strong lows, a bump in the middle, tapering highs
    const level = Math.min(1, 0.75 * Math.exp(-2.4 * x) + 0.28 * Math.exp(-((x - 0.42) ** 2) / 0.01) + 0.12 * (0.5 + 0.5 * Math.sin(b * 1.7)) * (1 - x) + 0.03);
    const h = Math.max(level * (H - 4 * dpr) * v.height / 100, 2 * dpr);
    g.roundRect(b * (bw + gap), H - h, bw, h, Math.min(bw / 2, 3 * dpr));
  }
  g.fill();
}
function saveViz(change) {
  saveSettings(change);
  renderViz();
}
$('viz-bars').addEventListener('input', (e) => saveViz({ vizBars: Number(e.target.value) }));
$('viz-height').addEventListener('input', (e) => saveViz({ vizHeight: Number(e.target.value) }));
$('viz-reset').addEventListener('click', () => saveViz({ vizBars: VIZ_DEFAULT.bars, vizHeight: VIZ_DEFAULT.height }));
$('viz-calm').addEventListener('click', () => saveViz({ vizCalm: !(App.settings && App.settings.vizCalm) }));

// ---------- lyrics: words fill letter by letter, or light up whole (lighter: nothing animates while a word is sung).
// macOS's Reduce Motion lights them up whole too.
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const letterFillPref = () => !(App.settings && App.settings.letterFill === false);   // the switch in Settings
const letterFill = () => letterFillPref() && !reduceMotion.matches;                     // what the lyrics do
reduceMotion.addEventListener('change', () => applyLetterFill());
function applyLetterFill() {
  const whole = !letterFill();
  if (document.body.classList.contains('whole-words') === whole) return;
  document.body.classList.toggle('whole-words', whole);
  emit('letterFill', !whole);
}

function renderSettings() {
  renderViz();
  const s = App.settings || {};
  const box = $('looks');
  box.replaceChildren();
  const all = Object.entries(LOOKS).map(([name, colors]) => ({ name, colors, custom: false }))
    .concat(customLooks().map((l) => ({ name: l[0], colors: l.slice(1), custom: true })));
  for (const look of all) {
    const item = el('div', 'look-item');
    const b = el('button', 'look');
    b.setAttribute('role', 'radio');
    b.dataset.look = look.name;
    b.dataset.colors = look.colors.join();
    const chip = el('span', 'chip');
    // three plain blocks -- low, middle, high -- exactly the colors it uses
    const [lo, mid, hi] = look.colors;
    chip.style.background = `linear-gradient(90deg, ${lo} 0 33.4%, ${mid} 33.4% 66.7%, ${hi} 66.7%)`;
    b.append(chip, el('span', null, look.name));
    b.addEventListener('click', () => pickLook(look.name, look.colors));
    item.append(b);
    if (look.custom) {
      const x = el('button', 'look-remove', '×');
      x.setAttribute('aria-label', `Remove the look “${look.name}”`);
      x.title = 'Remove this look';
      x.addEventListener('click', () => {
        saveSettings({ customLooks: customLooks().filter((l) => l[0] !== look.name) });
        renderSettings();
      });
      item.append(x);
    }
    box.append(item);
  }
  markLooks();
  $('set-folder').textContent = (s.libraryFolder || '').replace(/^\/Users\/[^/]+/, '~');
  $('set-about').replaceChildren(el('span', 'wordmark', 'Siftr'), ` ${s.version || ''} · everything stays on this Mac`);
  renderLyricsSettings();
}

/** Which look is picked (and the three color wells), without building the list again. */
function markLooks() {
  for (const b of $('looks').querySelectorAll('.look')) {
    const on = b.dataset.look === currentLook() && b.dataset.colors === App.colors.join();
    b.setAttribute('aria-checked', String(on));
    b.dataset.state = on ? 'checked' : 'unchecked';
  }
  ['c-low', 'c-mid', 'c-high'].forEach((id, i) => { $(id).value = App.colors[i]; });
}

for (const [i, id] of ['c-low', 'c-mid', 'c-high'].entries()) {
  $(id).addEventListener('input', () => {
    const colors = App.colors.slice();
    colors[i] = $(id).value;
    applyColors(colors);
  });
  $(id).addEventListener('change', () => { saveSettings({ look: 'Custom', colors: App.colors }); renderSettings(); });
}
$('look-save').addEventListener('click', () => {
  const row = $('look-save').parentElement;
  if (row.querySelector('.look-name')) return;
  const input = el('input', 'look-name');
  input.type = 'text';
  input.placeholder = 'Name this look';
  input.setAttribute('aria-label', 'Name this look');
  row.insertBefore(input, $('look-save'));
  input.focus();
  const done = (save) => {
    const name = input.value.trim().slice(0, 30);
    input.remove();
    if (!save || !name) return;
    const others = customLooks().filter((l) => l[0] !== name);
    saveSettings({ customLooks: others.concat([[name, ...App.colors]]), look: name, colors: App.colors });
    renderSettings();
  };
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') done(true); if (e.key === 'Escape') { e.stopPropagation(); done(false); } });
  input.addEventListener('blur', () => done(true));
});
$('set-reveal').addEventListener('click', () => post('reveal'));
$('set-library').addEventListener('click', () => post('chooseLibrary'));

// ------------------------------------------------------------- lyrics: the question, and its settings
function lyricsFacts(st, asking = false) {
  const ul = el('ul', 'facts');
  const rows = [['What', asking ? 'Whisper large-v3-turbo: OpenAI\'s free, open-source speech-to-text model, in the version made for Apple\'s Neural Engine.'
                                : `${st.model}: OpenAI's free, open-source speech-to-text model, in the version made for Apple's Neural Engine.`],
                ['Download', asking ? `${st.sizes.standard} (compressed and quick) or ${st.sizes.best} (the full model, much more accurate), once: only the one you pick`
                                    : `${st.size}, once${st.modelDownloaded ? ' (already here)' : ''}`],
                ['From', st.source],
                ['Kept in', st.folder.replace(/^\/Users\/[^/]+/, '~')],
                ['Private', 'It runs only on this Mac. Nothing is uploaded.'],
                ['Time', `A few minutes to get ready the very first time; then roughly 5–15 seconds a song${asking || st.quality === 'best' ? ' (longer with Best)' : ''}, in the background.`]];
  for (const [k, v] of rows) {
    const li = el('li');
    li.append(el('b', null, k), el('span', null, v));
    ul.append(li);
  }
  return ul;
}

/** The one-time question: what the lyrics tool is, what it downloads, and a clear no. */
function lyricsAskCard() {
  const st = App.lyrics;
  const card = el('div', 'card ask-card');
  card.append(el('h2', null, 'Lyrics for your library?'),
              el('p', null, 'Siftr can write out the words of the songs you keep, with every word timed, so Now Playing lights them up as they\'re sung and you can find a song by a line you remember.'));
  if (st) card.append(lyricsFacts(st, true));
  const actions = el('div', 'actions');
  const yes = el('button', 'btn accent', `Get lyrics · ${st ? st.sizes.standard : '646 MB'}`);
  const best = el('button', 'btn ghost', `Best quality · ${st ? st.sizes.best : '1.6 GB'}`);
  const no = el('button', 'btn ghost', 'No thanks');
  yes.dataset.answer = 'standard'; best.dataset.answer = 'best'; no.dataset.answer = 'no';
  yes.addEventListener('click', () => post('lyricsAnswer', { yes: true, quality: 'standard' }));
  best.addEventListener('click', () => post('lyricsAnswer', { yes: true, quality: 'best' }));
  no.addEventListener('click', () => post('lyricsAnswer', { yes: false }));
  actions.append(yes, best, no);
  card.append(actions, el('p', 'muted small ask-note', 'You can change this, and the quality, in Settings.'));
  return card;
}

function lyricsProgressText(st) {
  if (!st || st.choice !== true) return '';
  switch (st.phase) {
    case 'downloading': return `Downloading the lyrics model… ${Math.round(st.progress * 100)}%`;
    case 'preparing': return 'Getting the lyrics model ready (first time only: a few minutes)…';
    case 'working': return `Writing lyrics: ${st.current || ''} · ${st.done} of ${st.total} songs done`;
    case 'error': return st.message || 'Lyrics stopped.';
    default: return st.total ? `${st.done} of ${st.total} songs have lyrics` : '';
  }
}

function renderLyricsSettings() {
  const box = $('lyrics-settings');
  const st = App.lyrics;
  box.replaceChildren();
  if (!st) return;
  const row = el('div', 'switch-row');
  const label = el('div');
  label.append(el('div', null, 'Write out lyrics with Whisper'),
               el('div', 'muted small', st.choice === true ? lyricsProgressText(st) : st.choice === false ? 'Off: lyrics are hidden everywhere.' : 'Not set up yet.'));
  const sw = el('button', 'switch');
  setSwitch(sw, st.choice === true);
  sw.setAttribute('aria-label', 'Write out lyrics with Whisper');
  sw.addEventListener('click', () => post('lyricsAnswer', { yes: st.choice !== true }));
  row.append(label, sw);
  // Quality: the compressed model or the full one. Neither is in the app; only the chosen one is downloaded.
  const q = el('div', 'switch-row quality-row');
  const qLabel = el('div');
  qLabel.append(el('div', null, 'Quality'),
                el('div', 'muted small', (st.quality === 'best'
                  ? `Best: the full model (${st.sizes.best}), reading each song through whole. Much closer on busy songs, and slower.`
                  : `Standard: a compressed model (${st.sizes.standard}), and quick. It can mishear busy songs.`)
                  + ' Switching replaces the downloaded model.'));
  const seg = el('div', 'seg');
  seg.setAttribute('role', 'radiogroup');
  seg.setAttribute('aria-label', 'Lyrics quality');
  for (const [value, name] of [['standard', `Standard · ${st.sizes.standard}`], ['best', `Best · ${st.sizes.best}`]]) {
    const b = el('button', value === st.quality ? 'on' : '', name);
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(value === st.quality));
    b.dataset.quality = value;
    b.addEventListener('click', () => { if (value !== st.quality) post('lyricsQuality', { quality: value }); });
    seg.append(b);
  }
  q.append(qLabel, seg);
  box.append(row, q, lyricsFacts(st));
  // songs Whisper already did, written again with the quality chosen now (a second click to be sure: it takes a while)
  if (st.written > 0 && st.choice === true) {
    const redo = el('button', 'btn ghost small redo-lyrics', `Write them again (${plural(st.written, 'song')})`);
    redo.title = 'Writes out every song Whisper did again, with the quality chosen now. Lyrics from .lrc files stay; lines fixed by hand are written again too.';
    redo.addEventListener('click', () => {
      if (redo.dataset.sure) { post('redoLyrics'); return; }
      redo.dataset.sure = '1';
      redo.textContent = `Click again to write ${plural(st.written, 'song')} again`;
      setTimeout(() => { if (!$('settings').hidden) renderLyricsSettings(); }, 4000);
    });
    box.append(redo);
  }
  if (st.modelDownloaded) {
    const rm = el('button', 'btn danger small', `Remove the model (frees ${st.size})`);
    rm.addEventListener('click', () => post('removeModel'));
    box.append(rm);
  }
  const lrc = el('p', 'muted small', 'A synced .lrc file with the same name as a song is used automatically, with or without Whisper.');
  lrc.style.marginTop = '10px';
  const fill = el('div', 'switch-row fill-row');
  const fillLabel = el('div');
  fillLabel.append(el('div', null, 'Fill words letter by letter'),
                   el('div', 'muted small', reduceMotion.matches ? 'Reduce Motion is on in macOS, so each word lights up whole.'
                     : letterFillPref() ? 'Each word fills in as it\'s sung.' : 'Off: each word lights up whole, which is lighter on your Mac.'));
  const fillSwitch = el('button', 'switch');
  setSwitch(fillSwitch, letterFillPref());
  fillSwitch.id = 'lyrics-fill';
  fillSwitch.setAttribute('aria-label', 'Fill words letter by letter');
  fillSwitch.addEventListener('click', () => { saveSettings({ letterFill: !letterFillPref() }); applyLetterFill(); renderLyricsSettings(); });
  fill.append(fillLabel, fillSwitch);
  box.append(lrc, fill);
}

on('lyrics', (st) => {
  App.lyrics = st;
  document.body.classList.toggle('no-lyrics', st.choice === false);
  if (!$('settings').hidden) renderLyricsSettings();
});

// ------------------------------------------------------------- keys and focus
// The app handles the single-key shortcuts; it only needs to know when a
// text box is being typed in, so those keys type instead.
const isTextBox = (t) => t && (t.tagName === 'TEXTAREA' || t.isContentEditable ||
  (t.tagName === 'INPUT' && ['text', 'search'].includes(t.type)));
document.addEventListener('focusin', (e) => { if (isTextBox(e.target)) post('typing', { on: true }); });
document.addEventListener('focusout', (e) => { if (isTextBox(e.target)) post('typing', { on: false }); });
// buttons never hold focus, so Space never "clicks" the last one pressed
document.addEventListener('mousedown', (e) => { if (e.target.closest('button')) e.preventDefault(); });
document.addEventListener('contextmenu', (e) => e.preventDefault());
document.addEventListener('dragstart', (e) => e.preventDefault());

// ------------------------------------------------------------- the app's entry points
window.sifter = {
  receive(state) { App.sift = Object.assign(App.sift || {}, state); emit('sift', state); },
  frame(kind, pos, dur, playing, bars) { emit('frame', { kind, pos, dur, playing, bars }); },
  event(name, data) {
    if (name === 'now') App.now = data;
    if (name === 'settings') { App.settings = data; applyColors(data.colors || LOOKS[data.look] || LOOKS.Aurora); applyLetterFill(); }
    emit(name, data);
  },
  showPage(name) { showPage(name, false); },
  setVolume,
  dragHover(show) { $('drop').hidden = !show; Bars.report(); },
  flash(decision) { emit('flash', decision); },
  openSettings,
  // read by the app's --self-test
  debugState() {
    const s = { page: App.page, volume: App.volume, mini: !$('mini').hidden, colors: App.colors,
                settingsOpen: !$('settings').hidden, noLyrics: document.body.classList.contains('no-lyrics'),
                letterFill: letterFillPref(), vizCalm: !!(App.settings && App.settings.vizCalm) };
    for (const f of App.debug) Object.assign(s, f());
    return JSON.stringify(s);
  },
  test: {
    // settings the way their switches set them (the bench switches them without opening Settings)
    setting(change) { saveSettings(change); applyLetterFill(); if (!$('settings').hidden) renderSettings(); },
  },
};

// Every page script has loaded by the time this fires: tell the app to send the state.
document.addEventListener('DOMContentLoaded', () => post('ready'));
