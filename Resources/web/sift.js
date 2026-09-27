// The Sifting page: the song being judged, Keep / Pass / Skip, the queue and
// this session's decisions. The app keeps every rule; this draws its state.
'use strict';
(() => {
  new Bars($('s-viz'));                       // the app draws the bars here
  const seek = makeSeek($('s-seek'), (f) => post('seek', { fraction: f, kind: 'sift' }));
  seek.onRender = (p, d) => { setText($('s-pos'), fmt(p)); setText($('s-dur'), fmt(d)); };
  const art = $('s-art');
  let S = { now: { gen: -1 }, index: -1, queue: [], queueStart: 0, queueTotal: 0, session: [] };

  art.addEventListener('load', () => { art.hidden = false; });
  art.addEventListener('error', () => { art.hidden = true; });

  on('sift', (s) => {
    const newTrack = s.now.gen !== S.now.gen;
    const moved = s.index !== S.index;
    if (s.queue) { S.queue = s.queue; S.queueStart = s.queueStart || 0; }
    S.queueTotal = s.queueTotal ?? S.queue.length;
    if (s.session) S.session = s.session;
    Object.assign(S, { now: s.now, hasTrack: s.hasTrack, playing: s.playing, active: s.active, canPrev: s.canPrev,
                       canNext: s.canNext, index: s.index, status: s.status, progress: s.progress, counts: s.counts,
                       folder: s.folder, busy: s.busy });
    renderNow(newTrack);
    $('s-long').hidden = !(S.hasTrack && s.duration > LONG_SONG);
    if (!S.active || !S.playing) seek.update(s.position, s.duration);
    if (s.queue || moved || newTrack) renderQueue(!!s.queue);
    if (s.session) renderSession();
    renderStatus();
  });

  on('frame', (f) => {
    if (f.kind !== 'sift') return;
    seek.update(f.pos, f.dur);
    $('s-play').classList.toggle('playing', f.playing);
  });

  on('flash', (decision) => {
    const b = $(decision);
    if (!b) return;
    b.classList.add('flash');
    setTimeout(() => b.classList.remove('flash'), 110);
  });

  function renderNow(newTrack) {
    const n = S.now;
    $('s-title').textContent = n.title;
    $('s-title').title = n.title;
    $('s-sub').textContent = n.sub;
    $('s-sub').classList.toggle('error', !!n.error);
    for (const id of ['keep', 'pass', 'skip']) $(id).disabled = !S.hasTrack;
    $('s-play').disabled = !S.hasTrack || !!n.error;
    $('s-play').classList.toggle('playing', !!(S.playing && S.active));
    $('s-back').disabled = $('s-fwd').disabled = !S.hasTrack || !!n.error;
    seek.setEnabled(S.hasTrack && !n.error);
    if (newTrack) {
      // keep the old cover up until the new one has loaded (or turns out missing)
      if (n.art) art.src = n.art; else { art.removeAttribute('src'); art.hidden = true; }
    }
    if (!S.hasTrack) art.hidden = true;
  }

  function renderQueue(full) {
    const ol = $('queue');
    if (full) {
      // the app sends the part of a big batch around the current song, with its place in the whole
      const frag = document.createDocumentFragment();
      if (S.queueStart > 0) frag.append(el('li', 'more', `${S.queueStart.toLocaleString()} earlier`));
      S.queue.forEach((r, i) => {
        const li = el('li');
        li.dataset.i = String(S.queueStart + i);
        li.title = r.artist ? `${r.title} — ${r.artist}` : r.title;
        li.append(el('span', 'mark'), el('span', 't', r.title));
        if (r.artist) li.append(el('span', 'a', `— ${r.artist}`));
        frag.append(li);
      });
      const after = S.queueTotal - S.queueStart - S.queue.length;
      if (after > 0) frag.append(el('li', 'more', `…and ${after.toLocaleString()} more`));
      ol.replaceChildren(frag);
    }
    const old = ol.querySelector('li.current');
    if (old) { old.classList.remove('current'); old.firstChild.textContent = ''; }
    const cur = S.hasTrack ? ol.querySelector(`li[data-i="${S.index}"]`) : null;
    if (cur) {
      cur.classList.add('current');
      cur.firstChild.textContent = '▸';
      cur.scrollIntoView({ block: 'nearest' });
    }
    const n = S.queueTotal;
    $('q-count').textContent = n ? `${n} to go` : '';
    ol.hidden = n === 0;
    $('q-empty').hidden = n > 0;
  }

  function renderSession() {
    const frag = document.createDocumentFragment();
    for (const r of S.session) {
      const li = el('li');
      li.dataset.id = String(r.id);
      li.title = `${r.title} — double-click to undo`;
      const undo = el('button', 'undo', '×');
      undo.title = 'Undo';
      li.append(el('span', `dot ${r.decision}`), el('span', `tag ${r.decision}`, r.decision.toUpperCase()),
                el('span', 't', r.title), undo);
      frag.append(li);
    }
    $('session').replaceChildren(frag);
    $('session').hidden = S.session.length === 0;
    $('s-empty').hidden = S.session.length > 0;
  }

  function renderStatus() {
    $('status').textContent = S.status;
    $('finish').disabled = !S.folder || !!S.busy;
    const c = S.counts || { kept: 0, passed: 0 };
    $('lifetime').textContent = `All time: ${c.kept.toLocaleString()} kept · ${c.passed.toLocaleString()} passed`;
    const p = S.progress, show = !!p && p.total > 0;
    $('progress').hidden = !show;
    if (!show) return;
    $('progress-text').textContent = `${p.kept + p.passed} of ${p.total} sorted`;
    $('progress').querySelector('.k').style.width = `${(p.kept / p.total) * 100}%`;
    $('progress').querySelector('.p').style.width = `${(p.passed / p.total) * 100}%`;
  }

  $('keep').addEventListener('click', () => post('judge', { decision: 'keep' }));
  $('pass').addEventListener('click', () => post('judge', { decision: 'pass' }));
  $('skip').addEventListener('click', () => post('judge', { decision: 'skip' }));
  $('s-back').addEventListener('click', () => post('skipBy', { seconds: -10, kind: 'sift' }));
  $('s-fwd').addEventListener('click', () => post('skipBy', { seconds: 10, kind: 'sift' }));
  $('s-play').addEventListener('click', () => post('toggle', { kind: 'sift' }));
  $('open').addEventListener('click', () => post('open'));
  $('finish').addEventListener('click', () => post('finishBatch'));
  $('queue').addEventListener('dblclick', (e) => {
    const li = e.target.closest('li[data-i]');
    if (li) post('jump', { index: Number(li.dataset.i) });
  });
  $('session').addEventListener('dblclick', (e) => {
    const li = e.target.closest('li');
    if (li && !e.target.closest('.undo')) post('undo', { id: Number(li.dataset.id) });
  });
  $('session').addEventListener('click', (e) => {
    const b = e.target.closest('.undo');
    if (b && e.detail <= 1) post('undo', { id: Number(b.closest('li').dataset.id) });   // a double-click undoes one, not two
  });

  App.debug.push(() => ({
    title: $('s-title').textContent, sub: $('s-sub').textContent, subError: $('s-sub').classList.contains('error'),
    pos: $('s-pos').textContent, dur: $('s-dur').textContent, playIcon: $('s-play').classList.contains('playing'),
    queueRows: $('queue').querySelectorAll('li[data-i]').length, sessionRows: $('session').children.length,
    current: ($('queue').querySelector('li.current .t') || {}).textContent || null,
    artShown: !art.hidden, keepDisabled: $('keep').disabled, finishDisabled: $('finish').disabled, status: $('status').textContent,
    lifetime: $('lifetime').textContent, progress: $('progress').hidden ? '' : $('progress-text').textContent,
  }));
  Object.assign(window.sifter.test, {
    dblclick(listId, i) {
      const li = $(listId).children[i];
      if (li) li.querySelector('.t').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
    },
    seek(id, phase, frac) {    // 'down' | 'move' | 'up' on a seek bar
      const bar = $(id), r = bar.getBoundingClientRect();
      bar.dispatchEvent(new PointerEvent(`pointer${phase}`, { clientX: r.left + frac * r.width, clientY: r.top + r.height / 2, pointerId: 7, bubbles: true }));
    },
  });
})();
