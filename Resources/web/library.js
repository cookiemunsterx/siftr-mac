// The Library page: every kept song (Songs), grouped by album (Albums), and
// searchable by a line of its lyrics (Lyrics). Playing a song queues the
// list it was picked from.
'use strict';
(() => {
  const L = { songs: [], albums: [], byId: {}, mode: 'songs', query: '', sort: { key: 'added', desc: true },
              album: null, shown: [], stale: true, loading: false, scanning: false, folder: '' };
  const lyricNote = el('div', 'lib-note');

  async function load() {
    if (L.loading) return;
    L.loading = true;
    const data = await api('library');
    L.loading = false;
    if (!data) return;
    L.stale = false;
    L.songs = data.songs;
    L.albums = data.albums;
    L.scanning = data.scanning;
    L.folder = data.folder;
    L.byId = Object.fromEntries(L.songs.map((s) => [s.id, s]));
    render();
  }

  let reloadTimer = 0;
  function reloadSoon() {
    L.stale = true;
    if (App.page !== 'library') return;
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(load, 400);
  }

  on('page', (p) => { if (p === 'library' && L.stale) load(); });
  on('library', reloadSoon);
  on('played', reloadSoon);
  on('lyricsSaved', reloadSoon);
  on('now', () => markPlaying());
  on('lyrics', () => { if (App.page === 'library' && L.mode === 'lyrics') renderLyricsMode(); });

  // ---------- modes and search
  for (const b of $('lib-mode').children) {
    b.addEventListener('click', () => setMode(b.dataset.mode));
  }
  function setMode(mode) {
    L.mode = mode;
    L.album = null;
    for (const b of $('lib-mode').children) b.classList.toggle('on', b.dataset.mode === mode);
    $('lib-search').placeholder = mode === 'lyrics' ? 'Type a line you remember…' : 'Search your library';
    render();
  }

  let searchTimer = 0;
  $('lib-search').addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      L.query = $('lib-search').value.trim();
      L.mode === 'lyrics' ? runLyricSearch() : render();
    }, L.mode === 'lyrics' ? 250 : 90);
  });
  $('lib-search').addEventListener('keydown', (e) => { if (e.key === 'Escape') { $('lib-search').value = ''; L.query = ''; render(); } });
  $('lib-reveal').addEventListener('click', () => post('reveal'));

  for (const b of document.querySelectorAll('.table-head button[data-sort]')) {
    b.addEventListener('click', () => {
      const key = b.dataset.sort;
      const numeric = key === 'plays' || key === 'duration';
      L.sort = L.sort.key === key ? { key, desc: !L.sort.desc } : { key, desc: numeric };
      renderSongs();
    });
  }

  // ---------- drawing
  function render() {
    const empty = L.songs.length === 0;
    $('lib-empty').hidden = !empty || L.scanning;
    $('lib-folder').textContent = (L.folder || '').replace(/^\/Users\/[^/]+/, '~');
    for (const id of ['lib-songs', 'lib-albums', 'lib-album', 'lib-lyrics']) $(id).hidden = true;
    const hours = L.songs.reduce((t, s) => t + (s.duration || 0), 0) / 3600;
    $('lib-count').textContent = L.scanning && empty ? 'Looking through your library…'
      : `${plural(L.songs.length, 'song')}${hours >= 1 ? ` · ${hours.toFixed(1)} hours` : ''}${L.scanning ? ' · updating…' : ''}`;
    if (empty) return;
    if (L.mode === 'songs') renderSongs();
    else if (L.mode === 'albums') L.album ? renderAlbum(L.album) : renderAlbums();
    else renderLyricsMode();
  }

  function matches(s, q) {
    return !q || s.title.toLowerCase().includes(q) || s.artist.toLowerCase().includes(q) || s.album.toLowerCase().includes(q);
  }

  function sorted(list) {
    const { key, desc } = L.sort;
    const dir = desc ? -1 : 1;
    const text = (v) => (v || '').toLowerCase();
    return list.slice().sort((a, b) => {
      let c;
      if (key === 'title' || key === 'artist' || key === 'album') c = text(a[key]).localeCompare(text(b[key]));
      else c = (a[key] || 0) - (b[key] || 0);
      return c * dir || text(a.title).localeCompare(text(b.title));
    });
  }

  // One click anywhere on a row plays it (Enter too, from the keyboard), and you stay
  // on the Library: the mini player's Now Playing button goes there when you want.
  function songRow(s, queue) {
    const row = el('div', 'song-row songs-grid');
    row.dataset.id = s.id;
    row.tabIndex = 0;
    row.setAttribute('role', 'button');
    row.setAttribute('aria-label', `Play ${s.title}${s.artist ? `, by ${s.artist}` : ''}`);
    const t = thumb('lib', s.id, 34, 'thumb play-thumb');
    const [kind, text, tip] = songStatus(s);
    const status = el('span', `status ${kind}`, text);
    status.title = tip;
    row.append(t, el('span', 't', s.title), el('span', 'muted-cell', s.artist), el('span', 'muted-cell', s.album),
               el('span', 'num', s.plays ? String(s.plays) : ''), el('span', 'num', fmt(s.duration)), status);
    row.title = [s.title, s.artist, s.album].filter(Boolean).join(' — ');
    row.addEventListener('click', () => play(s.id, queue()));
    row.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); play(s.id, queue()); } });
    return row;
  }

  function renderSongs() {
    $('lib-songs').hidden = false;
    for (const b of document.querySelectorAll('.table-head button[data-sort]')) {
      b.classList.toggle('sorted', b.dataset.sort === L.sort.key);
      b.classList.toggle('asc', b.dataset.sort === L.sort.key && !L.sort.desc);
    }
    const q = L.query.toLowerCase();
    const list = sorted(L.songs.filter((s) => matches(s, q)));
    L.shown = list.map((s) => s.id);
    const queue = () => L.shown;
    const frag = document.createDocumentFragment();
    for (const s of list) frag.append(songRow(s, queue));
    if (!list.length) frag.append(el('div', 'lib-note', `Nothing matches “${L.query}”.`));
    $('lib-rows').replaceChildren(frag);
    markPlaying();
  }

  function renderAlbums() {
    const box = $('lib-albums');
    box.hidden = false;
    const q = L.query.toLowerCase();
    const frag = document.createDocumentFragment();
    for (const a of L.albums) {
      const songs = a.ids.map((id) => L.byId[id]).filter(Boolean);
      if (q && !a.name.toLowerCase().includes(q) && !songs.some((s) => matches(s, q))) continue;
      const card = el('button', 'album-card');
      const art = el('div', 'art');
      art.innerHTML = '<svg class="art-ph" viewBox="0 0 100 100"><circle cx="50" cy="50" r="17"/><circle cx="50" cy="50" r="2.7"/></svg>';
      if (a.cover) {
        const img = el('img');
        img.loading = 'lazy';
        img.alt = '';
        img.src = artURL('lib', a.cover, 200);
        img.addEventListener('error', () => img.remove());
        art.append(img);
      }
      card.append(art, el('div', 'name', a.name), el('div', 'meta', `${plural(songs.length, 'song')}${topArtist(songs) ? ' · ' + topArtist(songs) : ''}`));
      card.addEventListener('click', () => { L.album = a; render(); });
      frag.append(card);
    }
    box.replaceChildren(frag);
  }

  function topArtist(songs) {
    const count = {};
    for (const s of songs) if (s.artist) count[s.artist] = (count[s.artist] || 0) + 1;
    return Object.entries(count).sort((a, b) => b[1] - a[1])[0]?.[0] || '';
  }

  function renderAlbum(a) {
    const box = $('lib-album');
    box.hidden = false;
    const songs = a.ids.map((id) => L.byId[id]).filter(Boolean);
    const ids = songs.map((s) => s.id);
    const head = el('div', 'album-head');
    const art = el('div', 'art');
    art.innerHTML = '<svg class="art-ph" viewBox="0 0 100 100"><circle cx="50" cy="50" r="17"/><circle cx="50" cy="50" r="2.7"/></svg>';
    if (a.cover) {
      const img = el('img');
      img.alt = '';
      img.src = artURL('lib', a.cover, 340);
      img.addEventListener('error', () => img.remove());
      art.append(img);
    }
    const info = el('div');
    const back = el('button', 'back', '‹ All albums');
    back.addEventListener('click', () => { L.album = null; render(); });
    const minutes = Math.round(songs.reduce((t, s) => t + (s.duration || 0), 0) / 60);
    const playAll = el('button', 'btn accent', 'Play');
    playAll.addEventListener('click', () => ids.length && play(ids[0], ids));
    const actions = el('div', 'actions');
    actions.append(playAll);
    info.append(back, el('div', 'label', a.name === 'Singles' ? 'One-song albums' : 'Album'), el('h2', null, a.name),
                el('div', 'muted', `${topArtist(songs)}${topArtist(songs) ? ' · ' : ''}${plural(songs.length, 'song')} · ${minutes} min`), actions);
    head.append(art, info);
    const rows = el('div', 'table-rows');
    for (const s of songs) rows.append(songRow(s, () => ids));
    box.replaceChildren(head, rows);
    L.shown = ids;
    markPlaying();
  }

  // ---------- lyrics search
  function renderLyricsMode() {
    const box = $('lib-lyrics');
    box.hidden = false;
    const st = App.lyrics;
    if (st && st.choice == null) { box.replaceChildren(lyricsAskCard()); return; }
    if (!L.query) {
      lyricNote.textContent = st && st.choice === true
        ? `Type a line you remember — the search is forgiving about spelling and word order. ${lyricsProgressText(st)}.`
        : 'Type a line you remember.';
      box.replaceChildren(lyricNote);
      return;
    }
    runLyricSearch();
  }

  let searchSeq = 0;
  async function runLyricSearch() {
    if (L.mode !== 'lyrics' || !L.query) return renderLyricsMode();
    const seq = ++searchSeq;
    const data = await api('search', { q: L.query });
    if (seq !== searchSeq || !data) return;
    const box = $('lib-lyrics');
    const frag = document.createDocumentFragment();
    if (!data.results.length) {
      frag.append(el('div', 'lib-note', data.transcribed ? `No lyrics match “${L.query}” (searched ${plural(data.transcribed, 'song')}).`
                                                          : 'No songs have lyrics yet.'));
    }
    for (const r of data.results) {
      const hit = el('div', 'lyric-hit');
      const body = el('div');
      body.append(el('div', 'song', r.title), el('div', 'by', r.artist));
      for (const line of r.lines) {
        const row = el('div', 'lyric-line');
        row.append(el('span', 'chip', fmt(line.time)), highlighted(line.text, line.hits));
        row.addEventListener('click', (e) => { e.stopPropagation(); play(r.id, [r.id], line.time, true); });
        body.append(row);
      }
      hit.append(thumb('lib', r.id, 48), body);
      hit.addEventListener('click', () => play(r.id, [r.id], r.lines[0] ? r.lines[0].time : 0, true));
      frag.append(hit);
    }
    box.replaceChildren(frag);
  }

  function highlighted(text, hits) {
    const span = el('span');
    const words = new Set(hits);
    for (const part of text.split(/(\s+)/)) {
      const norm = part.toLowerCase().replace(/[’']/g, '').replace(/[^a-z0-9]/g, '');
      if (norm && words.has(norm)) span.append(el('mark', null, part)); else span.append(document.createTextNode(part));
    }
    return span;
  }

  // ---------- playing
  function play(id, queue, at = 0, fromLyrics = false) {
    // the song already playing isn't started over by another click on its row
    if (!fromLyrics && App.now && App.now.kind === 'library' && App.now.id === id && App.now.playing) return;
    // a lyric: start a beat before the line so you catch it
    post('play', { id, queue, at: fromLyrics ? Math.max(0, at - 1) : at });
  }

  // One word or two on where a song stands (the playing one says Playing, from CSS).
  function songStatus(s) {
    const lyricsOn = App.lyrics && App.lyrics.choice === true;
    if (!s.plays && Date.now() / 1000 - s.added < 7 * 86400) return ['new', 'New', 'Added this week, not played yet'];
    if (s.lyrics === 'whisper' || s.lyrics === 'lrc') return ['ok', 'Lyrics', s.lyrics === 'lrc' ? 'Timed lyrics, from its .lrc file' : 'Timed lyrics, written out by Whisper'];
    if (s.lyrics === 'none') return ['quiet', 'No words', 'Whisper found no singing in it'];
    if (s.lyrics === 'long') return ['quiet', 'Too long', 'Over 20 minutes: it plays, without lyrics'];
    if (lyricsOn) return ['quiet', 'Lyrics soon', 'Waiting its turn for lyrics'];
    return ['quiet', '', ''];
  }

  function markPlaying() {
    const id = App.now && App.now.kind === 'library' ? App.now.id : null;
    for (const r of document.querySelectorAll('.song-row.playing')) r.classList.remove('playing');
    if (!id) return;
    for (const r of document.querySelectorAll(`.song-row[data-id="${id}"]`)) r.classList.add('playing');
  }

  App.debug.push(() => ({ librarySongs: L.songs.length, libraryRows: $('lib-rows').children.length, libraryMode: L.mode,
                          albums: L.albums.length, librarySearchText: $('lib-search').value, albumCards: $('lib-albums').querySelectorAll('.album-card').length }));
  Object.assign(window.sifter.test, {
    playFromLibrary(i) { const id = L.shown[i]; if (id) play(id, L.shown); return id || null; },
    libraryMode: setMode,
    librarySearch(q) { $('lib-search').value = q; L.query = q; L.mode === 'lyrics' ? runLyricSearch() : render(); },
  });
})();
