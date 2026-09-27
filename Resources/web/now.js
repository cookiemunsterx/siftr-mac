// Now Playing: whatever's playing -- a library song or the one being
// sifted -- big, with its lyrics on a scroll wheel that lights each word as
// it's sung (ported from the Python app's Now Playing), or a big visualizer
// when there are no lyrics.
'use strict';
(() => {
  new Bars($('np-viz'));
  new Bars($('np-viz-side'));                 // the corner under the controls, when the big one isn't showing
  const seek = makeSeek($('np-seek'), (f) => post('seek', { fraction: f }));
  seek.onRender = (p, d) => { setText($('np-pos'), fmt(p)); setText($('np-dur'), fmt(d)); };
  const box = $('k-lines');
  const art = $('np-art');
  const K = { filling: new Set(), fillTimer: 0, key: null, lyrics: null, offset: 0, editing: false, editLine: null, state: { line: -2, sung: -1, between: null },
              geometry: null, anchor: 0, v: 0, active: -1, tints: [], pos: 0, posAt: 0, playing: false, loadSeq: 0,
              styles: [], snap: false, view: null, jank: { dts: [], last: 0 } };
  const now = () => performance.now();

  art.addEventListener('load', () => { art.hidden = false; });
  art.addEventListener('error', () => { art.hidden = true; });

  // ---------- what's playing
  on('now', (n) => {
    const playing = !!(n && n.kind);
    $('np-view').hidden = !playing;
    Bars.report();
    $('np-empty').hidden = playing;
    if (!playing) { K.key = null; return; }
    const key = `${n.kind}:${n.id}`;
    $('np-label').textContent = n.kind === 'sift' ? 'Now sifting' : 'Now playing';
    $('np-title').textContent = n.title;
    $('np-title').title = n.title;
    $('np-artist').textContent = [n.artist, n.album].filter(Boolean).join(' · ') || (n.error ? 'Could not play this file' : '');
    $('np-play').classList.toggle('playing', n.playing);
    $('np-play').disabled = !!n.error;
    $('np-back').disabled = $('np-fwd').disabled = !!n.error;
    $('np-prev').disabled = !n.canPrev;
    $('np-next').disabled = !n.canNext;
    $('np-decide').hidden = n.kind !== 'sift';
    seek.setEnabled(!n.error);
    seek.update(n.position, n.duration);
    setPos(n.position, n.playing);
    if (key !== K.key) {
      K.key = key;
      if (art.dataset.src !== n.art) { art.dataset.src = n.art; art.src = `${n.art}?s=400`; }
      loadLyrics(n);
    } else if (n.kind === 'library' && n.lyrics && (!K.lyrics || K.lyrics.source === 'missing')) {
      loadLyrics(n);                     // lyrics just arrived for this song
    } else if ((n.duration > LONG_SONG) !== !!K.long) {
      showMain();                        // its length just became known: say so if it's a long one
    }
    K.long = n.duration > LONG_SONG;
    tick();
  });

  on('frame', (f) => {
    if (!App.now || f.kind !== App.now.kind) return;
    seek.update(f.pos, f.dur);
    $('np-play').classList.toggle('playing', f.playing);
    setPos(f.pos, f.playing);
    tick();
  });

  // The app sends the position 4 times a second while lyrics are up; in
  // between, the page counts forward from the last one itself (never more
  // than half a second ahead, in case updates stop).
  function setPos(pos, playing) {
    // Never step back a hair while playing: updates arrive a little unevenly,
    // and going back 20 ms at the start of a word would un-light it and light
    // it again (a quick flash). Real jumps back (a click, -10 s) are bigger.
    if (playing && K.playing) {
      const cur = songTime();
      if (pos < cur && cur - pos < 0.35) pos = cur;
    }
    K.pos = pos;
    K.posAt = now();
    K.playing = playing;
  }
  const songTime = () => K.pos + (K.playing ? Math.min(0.5, (now() - K.posAt) / 1000) : 0);

  // Nothing runs continuously: the lyrics catch up on each position update,
  // and a timer wakes them exactly when the next word or line starts.
  function tick() {
    if (!onPage() || !showingKaraoke()) return;
    sync();
    schedule();
    if (K.filling.size && !K.fillTimer) fillStep();                  // paused, or away: the fill picks up where the song is
  }
  function schedule() {
    clearTimeout(K.timer);
    K.timer = 0;
    if (!K.playing || !onPage() || !showingKaraoke()) return;
    const t = songTime() + K.offset;
    const lines = K.lyrics.lines;
    let next = Infinity;
    for (let i = Math.max(0, K.state.line); i < lines.length && i <= K.state.line + 2; i++) {
      const l = lines[i];
      for (const w of l.words.length ? l.words : [l]) if (w.start > t) { next = Math.min(next, w.start); break; }
      if (l.start > t) next = Math.min(next, l.start);
      if (l.end + 1.5 > t) next = Math.min(next, l.end + 1.5);
    }
    const ms = Math.max(15, Math.min(1000, (next - t) * 1000 + 5));
    K.timer = setTimeout(() => { K.timer = 0; tick(); }, ms);
  }
  const onPage = () => App.page === 'now' && !$('np-view').hidden;

  on('lyricsSaved', (id) => { if (App.now && App.now.kind === 'library' && App.now.id === id) loadLyrics(App.now); });
  on('lyrics', () => { if (App.now && App.now.kind && (!K.lyrics || !K.lyrics.lines.length)) showMain(); });
  // Back on this page: measure again and jump straight to where the song is
  // (while away nothing was laid out, so nothing could be measured).
  on('page', (p) => {
    closeMenu();
    reportView();
    if (p !== 'now') { stopTints(); return; }
    resync();
  });
  function resync() {
    K.geometry = null;
    K.styles = [];
    stopTints();
    K.state = { line: -2, sung: -1, between: null };
    K.snap = true;
    requestAnimationFrame(() => tick());          // after the page is laid out
  }
  on('colors', () => { K.geometry = null; tick(); });
  // letter by letter switched on or off: the line being sung is armed again the new way
  on('letterFill', () => {
    if (box.children[K.armed]) disarm(box.children[K.armed]);
    K.armed = -1;
    if (onPage() && showingKaraoke()) resync();
  });

  async function loadLyrics(n) {
    const seq = ++K.loadSeq;
    K.lyrics = null;
    K.editing = false;
    if (n.kind === 'library') {
      const data = await api('lyrics', { id: n.id });
      if (seq !== K.loadSeq) return;           // another song by now
      K.lyrics = data;
    }
    K.offset = K.lyrics ? K.lyrics.offset || 0 : 0;
    renderLines();
    showMain();
    renderMenu();
  }

  const synced = () => !!(K.lyrics && K.lyrics.synced && K.lyrics.lines.length);
  const showingKaraoke = () => synced() && !box.hidden;

  /** The right side: the lyrics wheel, untimed lyrics, the question, or a big visualizer. */
  function showMain() {
    const n = App.now, st = App.lyrics;
    const hasSynced = synced();
    const plain = K.lyrics && K.lyrics.source === 'tags' && K.lyrics.lines.length;
    const ask = !hasSynced && !plain && n && n.kind === 'library' && st && st.choice == null;
    box.hidden = !hasSynced;
    box.classList.toggle('editing', K.editing);
    $('np-plain').hidden = !plain;
    if (plain) $('np-plain').textContent = K.lyrics.lines.map((l) => l.text).join('\n');
    $('np-viz').hidden = hasSynced || plain || ask;
    $('np-viz-side').hidden = !$('np-viz').hidden;
    Bars.report();
    $('np-edit').hidden = !hasSynced || !n || n.kind !== 'library';
    $('np-edit').firstChild.textContent = K.editing ? 'Done fixing ' : 'Edit ';
    $('np-edit').classList.toggle('on', K.editing);
    $('np-edit').querySelector('.chev').style.display = K.editing ? 'none' : '';
    if (!hasSynced) { K.editing = false; closeMenu(); }
    const note = $('np-note');
    const main = note.parentElement;
    main.classList.toggle('wheel', hasSynced);
    for (const c of main.querySelectorAll('.ask-card')) c.remove();
    note.hidden = true;
    if (!hasSynced && n && n.duration > LONG_SONG) {
      note.replaceChildren(el('span', 'pill', 'Over 20 minutes: it plays, without the visualizer or lyrics'));
      note.hidden = false;
    } else if (ask) {
      main.append(lyricsAskCard());
    } else if (!hasSynced && n && n.kind === 'library' && st && st.choice === true) {
      note.replaceChildren(el('span', 'pill', K.lyrics && K.lyrics.source === 'none' ? 'No words found in this song'
        : plain ? 'Untimed lyrics from the song\'s tags — timed ones are on their way' : `Lyrics are on their way · ${lyricsProgressText(st)}`));
      note.hidden = false;
    } else if (plain) {
      note.replaceChildren(el('span', 'pill', 'Lyrics from the song\'s tags (untimed)'));
      note.hidden = false;
    } else if (K.editing) {
      note.replaceChildren(el('span', 'pill', 'Click a line to fix it · Enter saves · Esc cancels · clearing a line removes it'));
      note.hidden = false;
    }
    reportView();
    if (hasSynced) resync();
  }

  // Tells the app whether the lyrics wheel is what's showing: then it sends
  // just the position, 10 times a second, instead of 60 visualizer frames.
  function reportView() {
    const v = onPage() && showingKaraoke();
    if (v === K.view) return;
    K.view = v;
    post('lyricsView', { on: v });
  }

  // ---------- the lyrics wheel
  function renderLines() {
    const frag = document.createDocumentFragment();
    (synced() ? K.lyrics.lines : []).forEach((line, i) => {
      const div = el('div', 'k-line' + (line.edited ? ' edited' : ''));
      div.dataset.i = String(i);
      const words = line.words.length ? line.words : [{ text: line.text, start: line.start, end: line.end }];
      words.forEach((w, j) => {
        if (j) div.append(document.createTextNode(' '));
        div.append(el('span', 'w', w.text));
      });
      frag.append(div);
    });
    box.replaceChildren(frag);
    K.armed = -1;
    K.state = { line: -2, sung: -1, between: null };
    K.geometry = null;
    K.styles = [];
    K.active = -1;
    stopTints();
  }

  function position(lines, t) {
    let line = -1;
    for (let i = 0; i < lines.length && lines[i].start <= t; i++) line = i;
    if (line === -1) return { line: -1, sung: 0, between: true };
    const cur = lines[line];
    let sung = 0;
    const words = cur.words.length ? cur.words : [{ start: cur.start }];
    while (sung < words.length && words[sung].start <= t) sung++;
    return { line, sung, between: t > cur.end + 1.5 };      // hold a finished line a moment before calling it a break
  }

  function formatOffset(v) {
    if (Math.abs(v) < 0.05) return 'in sync';
    return `${Math.abs(v).toFixed(1)} s ${v > 0 ? 'earlier' : 'later'}`;
  }

  // The line being sung sits level with a point 25% up from the bottom of
  // the cover -- higher than dead center, where the eye naturally goes.
  function readingLine() {
    const panel = box.getBoundingClientRect();
    const cover = $('np-art-box').getBoundingClientRect();
    const y = cover.top + cover.height * 0.75 - panel.top;
    return cover.right <= panel.left && y > 0 && y < panel.height ? y : panel.height * 0.4;
  }

  // p: -1 (top edge) .. 0 (the reading line) .. 1 (bottom edge). In steps
  // of 1/16: a new color repaints the line's text, a new position doesn't.
  function lineColor(p) {
    p = Math.round(p * 16) / 16;
    const [low, mid, high] = App.colors.map(hexRGB);
    const [to, t] = p < 0 ? [high, -p] : [low, p];
    return `rgb(${mid.map((c, i) => Math.round(c + (to[i] - c) * t)).join(', ')})`;
  }
  const brightness = (p) => { const d = Math.abs(p); return d < 0.08 ? 1 : 0.13 + 0.82 * Math.exp(-(d - 0.08) * 4.5); };

  function wheel(offset, radius, distance) {
    const angle = offset / radius;
    if (Math.abs(angle) >= Math.PI / 2) return null;             // rolled over the rim
    const depth = radius * (Math.cos(angle) - 1);
    const shownAt = radius * Math.sin(angle) * (distance - depth) / distance;
    return { angle, depth, shift: shownAt - offset };
  }

  // The wheel never scrolls: K.v is how far it's turned (what the scroll
  // position used to be). When the line changes, every line is given its new
  // place on the wheel once, and macOS's compositor glides it there (CSS
  // transitions of transform and opacity): the page does nothing per frame.
  // The tints step along a few times during the glide (a new color repaints
  // the line; a new position doesn't).
  const GLIDE_S = 1.2;          // .k-line's transition in pages.css: a curve fitted to this spring (within 1%)
  const glided = (t) => 1 - (1 + 4.5 * t) * Math.exp(-4.5 * t);
  const r = (v, k) => Math.round(v * k) / k;

  function measure() {
    if (K.geometry || !box.clientHeight) return;
    if (!K.editing) box.scrollTop = 0;
    K.geometry = [...box.children].map((e) => [e.offsetTop, e.offsetHeight]);
    K.anchor = readingLine();
    // seen from the lines' left edge, where they all start: the wheel still curves, but no line leans like italics
    box.style.perspectiveOrigin = `0 ${Math.round(K.anchor)}px`;
    K.styles = [];
    K.snap = true;
    if (K.editing) {                             // fixing: a plain list that scrolls
      box.scrollTop = K.v;
      K.v = box.scrollTop;                       // as far as it can go
      for (let i = 0; i < K.geometry.length; i++) set(box.children[i], i, 'off', false);
      tintAll(K.v);
    }
  }
  window.addEventListener('resize', () => { K.geometry = null; tick(); });

  // compared as rounded numbers, and turned into text only when they change
  function set(e, i, name, value, text) {
    const cache = K.styles[i] || (K.styles[i] = {});
    if (cache[name] === value) return;
    cache[name] = value;
    if (name === 'off') e.classList.toggle('off', value);
    else if (name === 'opacity') e.style.opacity = text(value);
    else e.style.setProperty(name, text(value));
  }

  // p: -1 (top edge) .. 0 (the reading line) .. 1 (bottom edge)
  function tilt(i, v) {
    const [top, height] = K.geometry[i];
    const offset = top + height / 2 - v - K.anchor;
    const reach = offset < 0 ? K.anchor : box.clientHeight - K.anchor;
    return { offset, reach, height, p: Math.max(-1, Math.min(1, offset / reach)) };
  }
  /** Where line i sits with the wheel turned to v: null past the rim; `shown` if it's on the panel. */
  function spotAt(i, v) {
    const { offset, reach, height, p } = tilt(i, v);
    const spot = wheel(offset, reach * 1.53, 900);
    if (!spot) return null;
    const at = K.anchor + offset + spot.shift;
    return { ...spot, p, shown: at >= -height && at <= box.clientHeight + height };
  }
  function look(e, i, s, v) {
    set(e, i, 'transform', `translateY(${r(s.shift - v, 10)}px) translateZ(${r(s.depth, 10)}px) `
      + `rotateX(${r(-s.angle * 180 / Math.PI, 100)}deg) scale(${i === K.active ? 1.2 : 1})`, String);
    set(e, i, 'opacity', r(brightness(s.p), 1000), String);
  }
  function tintAll(v) {
    const els = box.children;
    for (let i = 0; i < K.geometry.length; i++) {
      if (K.styles[i]?.off === false) set(els[i], i, '--lc', Math.round(tilt(i, v).p * 16), (x) => lineColor(x / 16));
    }
  }
  // The sung line's glow (its sung words brighter, the ones ahead fainter)
  // is a color, which repaints the line: it steps along with the glide
  // instead of being animated every frame (that cost as much as the glide).
  function glows() {                               // the lines whose glow changes: [i, from, to]
    const list = [];
    for (let i = 0; i < K.geometry.length; i++) {
      const g = K.styles[i]?.['--glow'] ?? 0, to = i === K.active ? 1 : 0;
      if (g !== to) list.push([i, g, to]);
    }
    return list;
  }
  function glowAt(list, f) {
    for (const [i, g, to] of list) set(box.children[i], i, '--glow', r(g + (to - g) * f, 100), String);
  }
  function stopTints() {
    for (const t of K.tints) clearTimeout(t);
    K.tints = [];
  }

  /** Turns the wheel to v: gliding there, or straight there. */
  function place(v, glide) {
    if (!K.geometry || K.editing) return;
    const from = K.v, els = box.children, n = K.geometry.length;
    K.v = v;
    stopTints();
    const glowing = glows();
    const drawn = [], entering = [];
    for (let i = 0; i < n; i++) {
      const s = spotAt(i, v), was = glide ? spotAt(i, from) : null;
      if (!s || !(s.shown || (was && was.shown))) { if (!glide || !was) set(els[i], i, 'off', true); continue; }
      if (glide && was && K.styles[i]?.off !== false) entering.push([i, was]);
      drawn.push([i, s]);
    }
    // Lines coming onto the panel start from where they'd have been, not from
    // nowhere. Only they skip the transition (.jump): switching it off for the
    // whole wheel would cancel glides still running from the line before.
    const jump = (list, on) => { for (const [i] of list) els[i].classList.toggle('jump', on); };
    jump(entering, true);
    for (const [i, s] of entering) { set(els[i], i, 'off', false); look(els[i], i, s, from); }
    if (entering.length) { void box.offsetWidth; jump(entering, false); }
    if (!glide) jump(drawn, true);
    for (const [i, s] of drawn) { set(els[i], i, 'off', false); look(els[i], i, s, v); }
    if (!glide) { tintAll(v); glowAt(glowing, 1); void box.offsetWidth; jump(drawn, false); return; }
    const along = (t) => glided(t) / glided(GLIDE_S);
    for (const t of [0.15, 0.35, 0.6]) K.tints.push(setTimeout(() => tintAll(from + (v - from) * along(t)), t * 1000));
    if (glowing.length) {                        // two lines at most: finer steps
      for (const t of [0.1, 0.2, 0.3, 0.45, 0.6, 0.8]) K.tints.push(setTimeout(() => glowAt(glowing, along(t)), t * 1000));
    }
    K.tints.push(setTimeout(() => {              // settled: final tints, and lines that rolled away aren't drawn
      K.tints = [];
      tintAll(v);
      glowAt(glowing, 1);
      for (let i = 0; i < n; i++) if (K.styles[i]?.off === false && !spotAt(i, v)?.shown) set(els[i], i, 'off', true);
    }, GLIDE_S * 1000 + 50));
  }
  function scrollTo(i) {
    const [top, height] = K.geometry[i];
    place(top + height / 2 - K.anchor, !K.snap);
    K.snap = false;
  }

  // turning the wheel by hand (a trackpad or mouse wheel)
  box.addEventListener('wheel', (e) => {
    if (K.editing || !K.geometry || !K.geometry.length) return;
    const ends = [0, K.geometry.length - 1].map((i) => K.geometry[i][0] + K.geometry[i][1] / 2 - K.anchor);
    K.wheelTo = Math.max(ends[0], Math.min(ends[1], (K.wheelTo ?? K.v) + e.deltaY));
    if (!K.wheelRaf) {
      K.wheelRaf = requestAnimationFrame(() => {
        K.wheelRaf = 0;
        if (K.wheelTo != null && K.geometry) place(K.wheelTo, false);
        K.wheelTo = null;
      });
    }
  }, { passive: true });
  // hover highlights only while the pointer moves (see .pointing in pages.css)
  box.addEventListener('mousemove', () => {
    box.classList.add('pointing');
    clearTimeout(K.pointing);
    K.pointing = setTimeout(() => box.classList.remove('pointing'), 1200);
  }, { passive: true });
  box.addEventListener('scroll', () => {           // fixing: the list scrolls for real
    if (!K.editing) { if (box.scrollTop) box.scrollTop = 0; return; }   // otherwise never (it would add to the turn)
    if (K.geometry) { K.v = box.scrollTop; tintAll(K.v); }
  }, { passive: true });

  // Only the line being sung carries the lit copies of its words (a handful
  // of small layers); the others are plain text, dim ahead and lit behind.
  function arm(line) {
    if (document.body.classList.contains('whole-words')) return;     // Settings -> Lyrics: words light up whole
    for (const w of line.children) w.append(el('span', 'lit', w.textContent));
  }
  function disarm(line) {
    for (const w of line.children) {
      w.classList.remove('sung');
      K.filling.delete(w);
      w.style.removeProperty('--f');
      w.lastChild?.classList?.contains('lit') && w.lastChild.remove();
    }
  }

  // A sung word's lit copy is uncovered over the time the word is held, in
  // steps of 50 ms, by the same clock that decides which word is sung.
  function setSung(e, on, seconds) {
    if (e.classList.contains('sung') === on) return;
    e.classList.toggle('sung', on);
    K.filling.delete(e);
    e.style.removeProperty('--f');
    if (!on || !e.lastChild?.classList?.contains('lit')) return;
    const t = songTime() + K.offset;
    e.fill = { from: t, to: t + seconds, f: 0 };
    K.filling.add(e);
    fillStep();
  }
  function fillStep() {
    clearTimeout(K.fillTimer);
    K.fillTimer = 0;
    const t = songTime() + K.offset;
    for (const e of K.filling) {
      const { from, to } = e.fill;
      let f = to > from ? (t - from) / (to - from) : 1;
      if (f >= 1) { f = 1.1; K.filling.delete(e); }                  // done: a little past the end, for letters that lean out
      f = Math.max(e.fill.f, Math.round(f * 1000) / 1000);           // never back
      if (f !== e.fill.f) { e.fill.f = f; e.style.setProperty('--f', String(f)); }
    }
    if (K.filling.size && K.playing && onPage()) K.fillTimer = setTimeout(fillStep, 50);
  }

  /** Where the song is -> which line is lit, which words are sung, where to glide. */
  function sync() {
    if (!synced() || !onPage() || !box.clientHeight) return;   // hidden: nothing to measure yet
    const fresh = !K.geometry;
    measure();
    const lines = K.lyrics.lines;
    const t = songTime() + K.offset;
    const pos = position(lines, t);
    const els = box.children;
    if (pos.line !== K.state.line || pos.between !== K.state.between) {
      for (let i = 0; i < els.length; i++) {
        els[i].classList.toggle('active', i === pos.line && !pos.between);
        els[i].classList.toggle('done', i < pos.line || (i === pos.line && pos.between));
      }
      const armed = pos.between ? -1 : pos.line;
      if (armed !== K.armed) {
        if (els[K.armed]) disarm(els[K.armed]);
        if (els[armed]) arm(els[armed]);
        K.armed = armed;
      }
      // keep the line being sung in place -- or, in a break, the one coming up
      K.active = armed;
      K.target = els[pos.between ? pos.line + 1 : pos.line] ? (pos.between ? pos.line + 1 : pos.line) : pos.line;
      if (K.target >= 0 && !K.editing) scrollTo(K.target);
      else if (K.editing) glowAt(glows(), 1);
      K.state = { ...pos, sung: -1 };
    } else if (fresh && K.target >= 0 && !K.editing) {
      scrollTo(K.target);                         // measured again (a resize): straight back in place
    }
    if (pos.line >= 0 && pos.line === K.armed && pos.sung !== K.state.sung) {
      const words = lines[pos.line].words;
      const wordEls = els[pos.line].children;
      for (let i = 0; i < wordEls.length; i++) {
        // lit left to right over the time the word is held (quickly if we jumped past it; a long
        // held note fills for as long as it's held, up to 10 s)
        const seconds = words[i] ? Math.min(10, Math.max(0.12, words[i].end - t)) : 0.3;
        setSung(wordEls[i], i < pos.sung, i < pos.sung ? seconds : 0);
      }
      K.state.sung = pos.sung;
    }
  }

  box.addEventListener('click', (e) => {
    const line = e.target.closest('.k-line');
    if (!line || !synced() || e.target.tagName === 'INPUT') return;
    const i = Number(line.dataset.i);
    const start = K.lyrics.lines[i].start - K.offset - (K.editing ? 1 : 0.3);
    post('seekTo', { seconds: Math.max(0, start) });
    if (!K.playing) post('toggle');
    if (K.editing) startEdit(i);
  });

  // ---------- the Edit menu: timing, and fixing lyrics by hand
  const menu = $('np-menu');
  function openMenu() {
    renderMenu();
    menu.hidden = false;
    const r = $('np-edit').getBoundingClientRect();
    const h = menu.offsetHeight, w = menu.offsetWidth;
    const below = r.bottom + 6 + h < window.innerHeight;
    menu.style.top = `${Math.round(below ? r.bottom + 6 : r.top - 6 - h)}px`;
    menu.style.left = `${Math.round(Math.max(8, Math.min(window.innerWidth - w - 8, r.right - w)))}px`;
  }
  function closeMenu() { menu.hidden = true; }
  function renderMenu() {
    $('np-offset').textContent = formatOffset(K.offset);
    $('np-reset').disabled = Math.abs(K.offset) < 0.05;
  }
  $('np-edit').addEventListener('click', (e) => {
    e.stopPropagation();
    if (K.editing) return setEditing(false);       // "Done fixing"
    if (menu.hidden) openMenu(); else closeMenu();
  });
  menu.addEventListener('click', (e) => e.stopPropagation());
  document.addEventListener('click', closeMenu);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !menu.hidden) { closeMenu(); e.stopPropagation(); } }, true);
  window.addEventListener('resize', closeMenu);
  $('np-fix').addEventListener('click', () => { closeMenu(); setEditing(true); });

  function setEditing(on) {
    K.editing = on;
    if (!on) cancelEdit();
    showMain();
  }

  function startEdit(i) {
    cancelEdit();
    K.editLine = i;
    const line = box.children[i];
    const input = el('input');
    input.type = 'text';
    input.value = K.lyrics.lines[i].words.map((w) => w.text).join(' ') || K.lyrics.lines[i].text;
    input.setAttribute('aria-label', 'Edit this line');
    line.replaceChildren(input);
    K.geometry = null;
    input.focus();
    input.addEventListener('keydown', async (ev) => {
      if (ev.key === 'Escape') { ev.stopPropagation(); cancelEdit(); }
      if (ev.key === 'Enter') {
        ev.preventDefault();
        const data = await api('editLyric', { id: App.now.id, line: i, text: input.value });
        if (!data) { toast('Couldn\'t save that line.'); return; }
        K.lyrics = data;
        K.editLine = null;
        renderLines();
        showMain();
      }
    });
  }

  function cancelEdit() {
    if (K.editLine === null) return;
    K.editLine = null;
    renderLines();
    showMain();
  }

  function nudge(delta) {
    if (!K.lyrics || !App.now || App.now.kind !== 'library') return;
    K.offset = Math.round((K.offset + delta) * 10) / 10;
    api('timing', { id: App.now.id, seconds: K.offset });
    renderMenu();
    K.state = { line: -2, sung: -1, between: null };
    sync();
  }
  // the menu stays open for Earlier / Later, so they can be clicked a few times
  $('np-earlier').addEventListener('click', () => nudge(0.1));
  $('np-later').addEventListener('click', () => nudge(-0.1));
  $('np-reset').addEventListener('click', () => { nudge(-K.offset); closeMenu(); });

  // ---------- controls
  $('np-play').addEventListener('click', () => post('toggle'));
  $('np-prev').addEventListener('click', () => post('prev'));
  $('np-next').addEventListener('click', () => post('next'));
  $('np-back').addEventListener('click', () => post('skipBy', { seconds: -10 }));
  $('np-fwd').addEventListener('click', () => post('skipBy', { seconds: 10 }));
  for (const b of $('np-decide').querySelectorAll('[data-judge]')) {
    b.addEventListener('click', () => post('judge', { decision: b.dataset.judge }));
  }
  on('flash', (d) => {
    const b = $('np-decide').querySelector(`[data-judge="${d}"]`);
    if (!b) return;
    b.classList.add('flash');
    setTimeout(() => b.classList.remove('flash'), 110);
  });

  App.debug.push(() => ({
    npTitle: $('np-view').hidden ? null : $('np-title').textContent,
    npLines: synced() ? box.children.length : 0, npSource: K.lyrics ? K.lyrics.source : null,
    npActive: box.querySelector('.k-line.active') && K.state.line >= 0 ? K.lyrics.lines[K.state.line].text : null,
    npSung: box.querySelectorAll('.w.sung').length, npLit: box.querySelectorAll('.w .lit').length, npBigViz: !$('np-viz').hidden, npAsk: !!document.querySelector('#page-now .ask-card'),
    npDecide: !$('np-decide').hidden, npEdit: !$('np-edit').hidden, npEditing: K.editing,
    npMenu: !menu.hidden, npOffset: K.offset,
    // how far the lit line sits from the reading line (px), and the share of slow frames
    npAlign: (() => {
      const a = box.querySelector('.k-line.active');
      if (!a || !box.clientHeight) return null;
      const at = a.getBoundingClientRect(), panel = box.getBoundingClientRect();
      return Math.round(at.top + at.height / 2 - panel.top - K.anchor);
    })(),
    // dropped frames: well over the typical (median) frame time; and that typical rate
    ...(() => {
      const d = K.jank.dts.slice().sort((a, b) => a - b), mid = d[d.length >> 1] || 0;
      return { npFrames: d.length, npJank: d.length ? Math.round(d.filter((x) => x > mid * 1.7).length / d.length * 1000) / 1000 : null,
               npFps: mid ? Math.round(1000 / mid) : 0 };
    })(),
  }));
  Object.assign(window.sifter.test, {
    editMenu(action) {       // 'open' | 'earlier' | 'later' | 'reset' | 'fix' | 'done'
      if (action === 'open' || action === 'done') $('np-edit').click();
      else $(`np-${action}`).click();
    },
    // the page's frame times for 3 s (the glides themselves are the compositor's: this checks the page keeps up)
    resetJank() {
      K.jank = { dts: [], last: 0 };
      const end = performance.now() + 3000;
      requestAnimationFrame(function step(ts) {
        if (K.jank.last) K.jank.dts.push(ts - K.jank.last);
        K.jank.last = ts;
        if (ts < end) requestAnimationFrame(step);
      });
    },
  });
})();
