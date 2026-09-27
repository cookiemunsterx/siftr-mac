// Leaderboard and Trends: what you actually listen to, counted in this app
// (a song counts once it plays to the end from the Library).
'use strict';
(() => {
  let staleTop = true, staleTrends = true;
  on('played', () => { staleTop = staleTrends = true; refresh(); });
  on('library', () => { staleTop = staleTrends = true; });
  on('page', refresh);

  function refresh() {
    if (App.page === 'top' && staleTop) loadLeaderboard();
    if (App.page === 'trends' && staleTrends) loadTrends();
  }

  function statCard(label, value, sub) {
    const c = el('div', 'card stat');
    c.append(el('div', 'k', label), el('div', 'v', value), el('div', 's', sub));
    return c;
  }

  const playSong = (id, queue) => post('play', { id, queue, show: true });

  // ---------- Leaderboard
  async function loadLeaderboard() {
    const rows = await api('leaderboard');
    if (!rows) return;
    staleTop = false;
    const empty = rows.length === 0;
    $('lb-empty').hidden = !empty;
    for (const e of [$('lb-stats'), $('lb-rows').parentElement, $('lb-summary').parentElement]) e.hidden = empty;
    if (empty) return;
    const total = rows.reduce((t, r) => t + r.plays, 0);
    const listened = (r) => r.plays * r.duration;       // finished plays only, so it's a floor
    const secs = rows.reduce((t, r) => t + listened(r), 0);
    const most = rows.reduce((b, r) => (listened(r) > listened(b) ? r : b), rows[0]);
    $('lb-stats').replaceChildren(
      statCard('Time listening', formatListening(secs), 'counting finished plays only'),
      statCard('Total plays', total.toLocaleString(), `across ${plural(rows.length, 'song')}`),
      statCard('Most time on one song', formatListening(listened(most)), `${most.title} · ${plural(most.plays, 'play')}`));
    $('lb-summary').textContent = `Counted in this app · updated ${new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`;
    const top = rows[0].plays;
    const ids = rows.map((r) => r.id);
    const frag = document.createDocumentFragment();
    for (const r of rows) {
      const row = el('div', `lb-row${r.rank <= 3 ? ' m' + r.rank : ''}`);
      const plays = el('div', 'plays');
      const meter = el('div', 'meter');
      const fill = el('i');
      fill.style.width = `${(r.plays / top) * 100}%`;
      meter.append(fill);
      plays.append(meter, el('span', 'n', String(r.plays)));
      row.append(el('span', 'rank', String(r.rank)), thumb('lib', r.id, 40), el('span', 't', r.title), el('span', 'a', r.artist),
                 plays, el('span', 'when', timeAgo(r.lastPlayed)));
      row.addEventListener('click', () => playSong(r.id, ids));
      frag.append(row);
    }
    $('lb-rows').replaceChildren(frag);
  }

  // ---------- Trends
  function songList(songs, empty) {
    if (!songs || !songs.length) return el('div', 'locked', empty);
    const box = el('div');
    const ids = songs.map((s) => s.id);
    for (const s of songs) {
      const row = el('div', 'trend-row');
      const text = el('div');
      text.append(el('div', 't', s.title), el('div', 'd', s.detail));
      row.append(thumb('lib', s.id, 38), text);
      row.addEventListener('click', () => playSong(s.id, ids));
      box.append(row);
    }
    return box;
  }

  function trendCard(title, sub, body) {
    const c = el('div', 'card trend-card');
    c.append(el('h3', null, title), el('div', 'sub muted', sub), body);
    return c;
  }

  const day = (iso) => new Date(`${iso}T00:00:00`).toLocaleDateString([], { month: 'short', day: 'numeric' });

  async function loadTrends() {
    $('tr-status').textContent = 'Looking at your listening…';
    const t = await api('trends');
    if (!t) return;
    staleTrends = false;
    const h = t.history;
    if (h.window) {
      $('tr-stats').replaceChildren(
        statCard(`Listening ${h.window}`, formatListening(h.seconds), 'counting finished plays only'),
        statCard(`Plays ${h.window}`, (h.plays || 0).toLocaleString(), 'across your library'));
      $('tr-status').textContent = `History since ${day(h.recordingSince)} (${plural(h.daysRecorded, 'day')}). The week-by-week trends sharpen as more days go by.`;
    } else {
      $('tr-stats').replaceChildren();
      $('tr-status').textContent = 'Trends fill in as you keep songs and play them.';
    }
    const locked = h.comparisonUnlocks ? el('div', 'locked', `Unlocks around ${day(h.comparisonUnlocks)} — it needs two weeks of history to compare.`) : null;
    const eras = el('div');
    const topEra = t.eras.length ? t.eras[0].seconds : 0;
    for (const e of t.eras) {
      const row = el('div', 'era');
      const line = el('div', 'line');
      line.append(el('strong', null, e.album), el('span', null, `${formatListening(e.seconds)} · ${plural(e.plays, 'play')} · ${plural(e.songs, 'song')}`));
      const meter = el('div', 'meter');
      const fill = el('i');
      fill.style.width = `${topEra ? (e.seconds / topEra) * 100 : 0}%`;
      meter.append(fill);
      row.append(line, meter);
      eras.append(row);
    }
    if (!t.eras.length) eras.append(el('div', 'locked', 'No data yet.'));
    $('tr-grid').replaceChildren(
      trendCard(`Most played ${h.window || ''}`, 'Plays gained over that stretch',
                h.window ? songList(h.mostPlayed, 'No plays recorded in this stretch yet.') : el('div', 'locked', 'No history yet.')),
      trendCard('Heating up', 'Playing it more this week than last', locked ? locked.cloneNode(true) : songList(h.heatingUp, "Nothing's climbing this week.")),
      trendCard('Cooling off', 'Played a lot last week, less this week', locked ? locked.cloneNode(true) : songList(h.coolingOff, "Nothing's fading this week.")),
      trendCard('Forgotten favorites', "Top songs you haven't played in a month", songList(t.forgottenFavorites, "None — you've been keeping up with your favorites.")),
      trendCard('Skip magnets', 'Skipped more than finished — maybe trim these', songList(t.skipMagnets, 'Nothing you skip a lot.')),
      trendCard('Fresh adds', 'Songs added in the last 30 days', songList(t.freshAdds, 'Nothing added in the last month.')),
      trendCard('Your eras', 'Listening time by album', eras));
  }

  App.debug.push(() => ({ leaderRows: $('lb-rows').children.length, trendCards: $('tr-grid').children.length }));
})();
