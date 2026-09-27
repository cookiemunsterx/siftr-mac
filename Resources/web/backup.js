// Backup: copy the library onto a thumb drive, SD card or external disk (with
// Siftr's history), restore it from one, eject it.
'use strict';
(() => {
  const GB = 1e9;
  const size = (b) => (b >= GB ? `${(b / GB).toFixed(1)} GB` : `${Math.max(1, Math.round(b / 1e6))} MB`);
  let info = null;

  on('page', (p) => { if (p === 'backup') load(); });
  on('backup', (status) => { if (info) info.status = status; showStatus(status); if (!status.running) load(); });
  $('bk-refresh').addEventListener('click', load);

  async function load() {
    info = await api('drives');
    if (!info) return;
    $('bk-size').textContent = info.songs ? `Your library: ${plural(info.songs, 'song')}, ${size(info.librarySize)}.` : 'Your library is empty, so there\'s nothing to back up yet.';
    const box = $('bk-drives');
    box.replaceChildren();
    if (!info.drives.length) {
      box.append(el('div', 'card lib-note', 'No drives plugged in. Plug in a thumb drive, SD card or external disk, then click Refresh.'));
    }
    for (const d of info.drives) {
      const card = el('div', 'card drive');
      card.innerHTML = '<svg viewBox="0 0 24 24"><rect x="4" y="3" width="16" height="18" rx="3"/><path d="M8 3v5h8V3"/></svg>';
      const mid = el('div');
      const meter = el('div', 'meter');
      const used = el('i');
      used.style.width = `${d.total ? (1 - d.free / d.total) * 100 : 0}%`;
      meter.append(used);
      const fits = info.librarySize <= d.free;
      mid.append(el('div', 'name', d.name), meter,
                 el('div', 'info', `${size(d.free)} free of ${size(d.total)}${d.songsBackedUp ? ` · ${plural(d.songsBackedUp, 'song')} backed up here` : ''}${fits ? '' : ' · may not have room for everything'}`));
      const actions = el('div', 'actions');
      const go = el('button', 'btn accent small', d.songsBackedUp ? 'Update backup' : 'Back up');
      go.disabled = !info.songs || (info.status && info.status.running);
      go.addEventListener('click', () => { post('backup', { path: d.path }); go.disabled = true; });
      const eject = el('button', 'btn ghost small', 'Eject');
      eject.disabled = !!(info.status && info.status.running);
      eject.addEventListener('click', async () => {
        const r = await api('eject', { path: d.path });
        if (r && r.error) toast(`Couldn't eject ${d.name}: ${r.error}`); else { toast(`${d.name} can be unplugged now.`); load(); }
      });
      // a backup that can put the library back (with its history), after a lost library or on a new Mac
      if (d.canRestore) {
        const back = el('button', 'btn ghost small', 'Restore…');
        back.title = 'Copy these songs back into your library under their original names, with their plays, lyrics and sorting history';
        back.disabled = !!(info.status && info.status.running);
        back.addEventListener('click', () => post('restore', { path: d.path }));
        actions.append(go, back, eject);
      } else {
        actions.append(go, eject);
      }
      card.append(mid, actions);
      box.append(card);
    }
    showStatus(info.status);
  }

  function showStatus(s) {
    if (!s) return;
    $('bk-progress').hidden = !s.running;
    if (s.running) {
      $('bk-now').textContent = s.current ? `${s.mode === 'restore' ? 'Restoring' : 'Copying'} ${s.current}` : 'Getting started…';
      $('bk-count').textContent = s.total ? `${s.done} of ${s.total}` : '';
      $('bk-bar').style.width = `${s.total ? (s.done / s.total) * 100 : 0}%`;
    }
    const out = $('bk-result');
    out.replaceChildren();
    if (s.error) {
      const c = el('div', 'card bk-result');
      c.append(el('h3', null, s.mode === 'restore' ? 'The restore stopped' : 'The backup stopped'), el('div', 'muted', s.error));
      out.append(c);
    } else if (s.restored && !s.running) {
      const f = s.restored.files, h = s.restored.history;
      const c = el('div', 'card bk-result');
      c.append(el('h3', null, f.copied ? `Restored ${plural(f.copied, 'song')} (${size(f.bytesCopied)})` : 'Your library already had every song'));
      if (f.alreadyThere) c.append(el('div', 'muted small', `${plural(f.alreadyThere, 'song')} ${f.alreadyThere === 1 ? 'was' : 'were'} already in your library.`));
      if (h) c.append(el('div', 'muted small', `History brought back: ${plural(h.plays, 'play')}, lyrics for ${plural(h.lyrics, 'song')}, ${plural(h.decisions, 'sorting decision')}.`));
      else c.append(el('div', 'muted small', 'This backup had no copy of Siftr\'s history, so plays and lyrics start fresh.'));
      if (f.conflicts.length) c.append(el('div', 'small', `Left alone (a different file already has the name): ${f.conflicts.join(', ')}`));
      if (f.missing.length) c.append(el('div', 'small', `Not on the drive any more: ${f.missing.join(', ')}`));
      out.append(c);
    } else if (s.result && !s.running) {
      const r = s.result;
      const c = el('div', 'card bk-result');
      c.append(el('h3', null, r.copied ? `Backed up ${plural(r.copied, 'new song')} (${size(r.bytesCopied)})` : 'Already up to date'),
               el('div', 'muted small', `${plural(r.upToDate + r.copied, 'song')} on the drive, in ${r.folder.split('/').slice(-2).join('/')}`));
      if (r.unavailable.length) {
        const ul = el('ul');
        for (const u of r.unavailable) ul.append(el('li', null, `${u.title}: ${u.why}`));
        c.append(el('div', 'small', `${plural(r.unavailable.length, 'song')} couldn't be backed up:`), ul);
      }
      if (r.notInLibraryAnymore.length) {
        c.append(el('div', 'muted small', `${plural(r.notInLibraryAnymore.length, 'song')} on the drive ${r.notInLibraryAnymore.length === 1 ? 'is' : 'are'} no longer in your library — left there, never deleted.`));
      }
      out.append(c);
    }
  }

  App.debug.push(() => ({ drives: info ? info.drives.length : -1 }));
})();
