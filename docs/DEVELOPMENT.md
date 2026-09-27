# Siftr for Mac: building, testing and performance

For people working on Siftr itself. Using it is in the [README](../README.md)
and the [guide](GUIDE.md). Siftr for Mac is a native rewrite of an earlier
Python app for Mac and Windows (called Music Sifter at the time); many of the
rules and their tests were ported from it case for case, and the data folder
and backup format stay compatible with it.

## Building it

Needs only Apple's free Command Line Tools (`xcode-select --install`), not
the full Xcode. The first build fetches WhisperKit (pinned to 1.1.0) from
GitHub.

```
./build.sh              # Apple Silicon -> build/Siftr.app and build/Siftr.zip
./build.sh --universal  # one app for Apple Silicon and Intel Macs
```

## Testing it

```
swift test                        # 57 tests of the rules, in under a second
scripts/self_test.sh              # the real app, driven by itself (about 2 minutes)
scripts/bench.sh                  # memory and CPU in each everyday state, realistic songs (about 2 minutes)
scripts/self_test.sh --whisper    # ...plus lyrics for real, with Whisper's small test model (~75 MB)
```

- `swift test` covers scanning, song keys, the database, copying and undo
  safety, the queue rules, the visualizer math, lyric search and lyric
  editing, `.lrc` files, trends, album grouping, backups and Finish batch's
  safety checks. Many cases are
  ported straight from the Python app's tests, and the visualizer is checked
  against numbers from the original `viz.py`, so both apps give the same
  answers.
- `scripts/self_test.sh` makes test songs in every format (it needs ffmpeg:
  `brew install ffmpeg`), starts the real app with scratch folders and its
  own preferences (never your real library, settings or media keys), presses
  the real keys, and goes through every page: sifting and finishing a batch,
  the library, synced lyrics on Now Playing (smoothness, staying in sync after
  switching pages, the Edit menu, whole-word lighting), a play being counted, the Leaderboard and Trends, a
  backup to a scratch folder, Settings (Calm bars at 15 fps), typing in the search box, and the
  page resting while minimized and coming back. It
  measures memory and CPU and saves screenshots. A window appears for about
  two minutes and plays silently. **Unlock the screen first** (a locked Mac
  has no sound for any app). Checks that need the window on screen are
  skipped, and say so, if another app covers it.

## How it's built

- **Swift + AppKit** for the window, the toolbar and its page switcher,
  menus and drag-and-drop.
- **The screen** (`Resources/web/`) is HTML/CSS/JS drawn by macOS's own web
  engine (WebKit). Nothing is bundled, and there's no browser, no network
  and no Python. It only draws what the app sends it and asks the app for
  data. It never plays audio, because WebKit stops audio in hidden windows.
- **Playback:** two AVAudioPlayers, one for the song being sifted and one for
  the library, with one playing at a time. Songs are prepared off the main
  thread, so a slow audio system never freezes the window.
- **Visualizer:** the original `viz.py` math in Swift, using Apple's
  Accelerate library (96 bars here, viz.py's 56 in the tests), drawn with
  Core Animation layers placed over the page, only while shown.
- **Lyrics:** WhisperKit (Core ML, Neural Engine), synced `.lrc` files, and
  search and editing ported from the Python app.
- **Tags and art:** AVFoundation, plus a small FLAC cover-art reader, and
  ImageIO for thumbnails.
- **Data:** SQLite, built into macOS.

```
Sources/SifterCore/   the rules: scan, keys, database, copy/undo, queue, visualizer math,
                      lyric search/editing/.lrc, trends, albums, backup
Sources/Siftr/        the Mac app: window and toolbar, menus, players, library, lyrics,
                      backup, the page bridge, the self-test
Resources/web/        the screen: index.html, app.css, pages.css, and one script per page
scripts/              make_icon.swift (draws the icon), self_test.sh, bench.sh, demo-setup.sh
```

`SIFTER_DATA`, `SIFTER_LIBRARY` and `SIFTER_TRASH` point the app at other
folders (the tests use them), and `SIFTER_PREFS=<name>` gives it a separate
set of preferences (`scripts/demo-setup.sh` uses all four for a clean
profile). `SIFTER_TRACE=1` prints start-up timing and
when the page's update rate changes.

## What it costs, in detail

Measured with `scripts/bench.sh` on an M2 MacBook Pro (8 GB, macOS 26), with
realistic songs (4 minutes long, a 250-song library, 70 lines of lyrics), on
its own Retina screen with Low Power Mode off: the reference runs of
25 September 2026 (the full tables, per process, are under "Where it stands"
below). The README quotes the same numbers.

| What's on screen | Memory | CPU |
|---|---|---|
| Nothing playing | **104 MB** | 0.1% |
| Sifting, visualizer moving | **148 MB** | **6.7%** of one core (5.8% with Calm) |
| Paused | **110 MB** | 0% |
| Now Playing, lyrics rolling (and the corner visualizer) | **179 MB** | **14.6%** (10.3% with letter by letter off) |
| Now Playing, big visualizer | **168 MB** | **6.9%** |
| Browsing the Library, mini player | **193 MB** | **4.6%** |
| Minimized, still playing | **182 MB** | **1.2%** |
| Minimized (or hidden) 10 minutes, still playing | **110 MB** | **1.1%** |

Lyrics vary the most between runs: three alternating old-and-new pairs on
the same screen gave 12.5% (see "Lyrics glide on the compositor"), the single
reference run 14.6%.

A second run on 26 September 2026, on the release build (same screen, Low
Power Mode off, 20 s holds), came out within about 7 MB and 1–2 points lower
on CPU. The README quotes both runs as ranges. Its window-server column isn't
clean (the Mac was in use), so it's left out:

| State | Memory | CPU | app / page / graphics |
|---|---|---|---|
| Idle | 100 | 0.3% | 0.1 / 0.1 / 0.1 |
| Sifting (native bars) | 145 | 5.6% | 2.4 / 1.3 / 1.9 |
| Sifting, Calm (15 fps) | 145 | 3.8% | 1.6 / 0.9 / 1.3 |
| Sifting, paused | 111 | 0.2% | |
| Now Playing: lyrics and corner bars | 179 | 12.4% | 3.9 / 4.6 / 3.8 |
| Now Playing: lyrics, words whole | 191 | 8.3% | 2.8 / 2.9 / 2.7 |
| Now Playing: big visualizer | 171 | 5.5% | 2.5 / 1.5 / 1.5 |
| Library, mini player | 193 | 3.3% | 1.2 / 1.5 / 0.5 |
| Minimized, playing | 176 | 0.7% | |
| Minimized 10 minutes: page resting | 103 | 0.9% | |

The page was back 1.2 s after the window.

On a plain (1×) monitor the page's pictures are a quarter the size, and
memory is 80–140 MB for the same states. Moving pictures also cost macOS's
own window compositor (WindowServer in Activity Monitor), which isn't in
these numbers: about 15% of a core while the bars move (half that with
Settings → Visualizer → Calm), and while lyrics roll 28% on the Retina
screen and 57% on a 120 Hz monitor (20% and 34% with letter by letter off).

Disk: **3.7 MB** (plus the optional 646 MB lyrics model); the Windows
version is 49 MB and ~165 MB of memory while sifting. Memory is the app plus
macOS's built-in web engine that draws the pages. (Activity Monitor counts
CPU per core: 100% is one whole core, and an Apple Silicon Mac has 8 or more.)

How it stays light:
- **The visualizer is drawn natively** (Core Animation), over a spot the
  page leaves for it, at 30 frames a second like the Windows app. The web
  engine redrawing a canvas was most of the app's CPU; now the page itself
  updates only 4 times a second (the progress bar and the time).
- **Lyrics** get 4 position updates a second; the page counts forward on
  its own and wakes exactly when the next word starts. When a new line
  comes up, the page gives each line its new place on the wheel once and
  macOS's compositor glides them there by itself: the page does nothing
  frame by frame. Each word fills letter by letter by sliding a lit copy
  into view, which the compositor animates too; only the line being sung
  carries those copies, and only the lines on the wheel are drawn.
- Nothing is drawn while the window is hidden or minimized, and the page
  only redraws what changed. **Put away for 10 minutes** (minimized, or
  the app hidden with ⌘H), the page itself is let go while the music plays
  on: the web engine otherwise keeps its pictures of the window, 60 MB and
  more on a Retina screen. When the window comes back, the page loads again
  in about a second (the window shows its plain background meanwhile). One solid background, no big blurred or glowing
  effects, no see-through cards, covers shrunk before the page sees them,
  and memory freed after big jobs (tagging the library, decoding a song) is
  handed back to macOS.

## Performance notes

Where the performance work stands, for whoever picks it up next. **The goal
now is lightweight and unnoticeable first**, while staying friendly and good
looking. The lyrics and the visualizer may be simplified to get there.
Keeping the visualizer the same on every page matters more than any one
effect in it.

### Where it stands (`scripts/bench.sh`, Low Power Mode off, 2026-09-25)

Two runs on each screen, 20 s holds; they agreed within about 0.5 points.
Memory in MB, CPU in % of one core. "Window server" is macOS's compositor,
shared with everything on screen (not in the total).

The reference runs (2026-09-25, late): the Mac otherwise idle, nobody
using it, 15 s holds, one run on each screen. The window server read
1–2% whenever the app wasn't drawing, so its column is clean. Three
earlier runs on the Retina screen agreed within about 2 points of CPU.

Retina 2×, 60 Hz (the Mac's own screen):

| State | Memory | App | Page | Graphics | CPU | app / page / graphics | Window server |
|---|---|---|---|---|---|---|---|
| Idle | 104 | 35 | 42 | 22 | 0.1% | | 1.3 |
| Sifting (native bars) | 148 | 47 | 69 | 28 | 6.7% | 2.9 / 1.8 / 2.0 | 15.2 |
| Sifting, Calm (15 fps) | 146 | 46 | 69 | 26 | 5.8% | 2.1 / 1.5 / 2.1 | **7.5** |
| Sifting, paused | 110 | 45 | 45 | 15 | 0.0% | | 1.2 |
| Now Playing: lyrics and corner bars | 179 | 47 | 96 | 31 | 14.6% | 4.4 / 5.8 / 4.5 | 27.5 |
| Now Playing: lyrics, words whole | 172 | 47 | 91 | 29 | **10.3%** | 3.4 / 3.6 / 3.2 | **19.9** |
| Now Playing: big visualizer | 168 | 47 | 79 | 37 | 6.9% | 3.1 / 1.8 / 2.0 | 14.0 |
| Library, mini player | 193 | 48 | 113 | 27 | 4.6% | 1.6 / 2.2 / 0.8 | 3.5 |
| Minimized, playing | 182 | 47 | 112 | 18 | 1.2% | | 1.6 |
| Minimized 10 minutes: page resting | **110** | 47 | **40** | 18 | 1.1% | | 1.7 |

External 1×, 120 Hz:

| State | Memory | App | Page | Graphics | CPU | app / page / graphics | Window server |
|---|---|---|---|---|---|---|---|
| Idle | 100 | 59 | 23 | 13 | 0.2% | | 1.7 |
| Sifting (native bars) | 143 | 66 | 44 | 28 | 5.6% | 2.8 / 1.3 / 1.5 | 18.0 |
| Sifting, Calm (15 fps) | 113 | 47 | 37 | 25 | 6.0% | 2.3 / 1.5 / 2.2 | **9.7** |
| Sifting, paused | 116 | 47 | 37 | 27 | 0.0% | | 1.9 |
| Now Playing: lyrics and corner bars | 131 | 48 | 50 | 28 | 13.8% | 4.7 / 5.2 / 3.9 | 57.2 |
| Now Playing: lyrics, words whole | 142 | 48 | 59 | 30 | **11.2%** | 3.8 / 4.1 / 3.4 | **34.0** |
| Now Playing: big visualizer | 130 | 48 | 48 | 29 | 6.3% | 3.0 / 1.6 / 1.7 | 18.5 |
| Library, mini player | 150 | 49 | 66 | 29 | 4.9% | 1.8 / 2.3 / 0.8 | 3.9 |
| Minimized, playing | 130 | 49 | 59 | 17 | 1.0% | | 1.7 |
| Minimized 10 minutes: page resting | **103** | 49 | **33** | 16 | 1.1% | | 1.8 |

The page was back 0.74 s after the window on both screens.

"Page" is WebKit's WebContent process and "Graphics" is WebKit's GPU
process; the Networking process adds about 5 MB that can't be avoided with
WKWebView. The biggest costs:

1. **The window server, driven by the app's moving pictures.** It's
   about 15 points of a core more while the bars move (sifting: 16–23% vs
   1–7% paused), which is more than the app's own processes use. (It isn't
   the bars' masks: bars without masks cost it more; see the Metal item
   under "The author's list".) While lyrics roll, the glides and the letter
   fills are compositor animations, which run at the screen's full rate:
   30% on the Retina screen, 55% at 120 Hz.
2. **The lyrics page: ~13% CPU** in the app's own processes (was ~19%: see
   "Lyrics glide on the compositor" below). What's left: the page's 4.8%
   (position updates, the word timers, the tint and glow steps), the
   corner bars and applying the page's layer changes (the app's 3.9%), and
   the graphics process repainting lines (4.0%).
3. **The page process keeps growing as pages are visited** (Retina: 42 MB
   idle → 113 MB after the Library; 1×: 23 → 58 MB) and doesn't shrink
   until the window is put away for 10 minutes and the page rests. That's WebKit's own heap: the DOM of every page stays
   in memory, just hidden, and the Library holds 250 rows.
4. **The app holds about 44 MB, of which only about 10 MB is live data**
   (checked with `heap`). The rest is frameworks, memory freed but not yet
   returned to macOS, and the song decoded for the bars (mono Int16 at
   22,050 Hz: about 10 MB for a 4-minute song).

### Already done (measured, don't redo)

- **The page rests when the window is put away** (2026-09-25, the author's
  call). Minimized, or the app hidden with ⌘H, for 10 minutes
  (`AppController.restAfter`; `SIFTER_REST_AFTER` for tests), the window's
  content becomes a plain view in its own background color and the page
  goes to `about:blank`, letting go of its document and its drawn tiles.
  WebKit keeps those otherwise: hiding the web view or taking it out of
  the window freed 3 MB of the 70. When the window shows again (the
  occlusion change, or un-minimize / unhide), `index.html` loads again
  behind the plain view, and on "ready" the app pushes its state as at
  launch and swaps the page back in. A folder opened meanwhile wakes it,
  and it rests again later if still put away. Measured: **182 → 110 MB**
  on Retina (the page process 112 → 40 MB) and 130 → 103 MB on the 1×
  monitor, back to about idle; the page is back 0.7–1.1 s after the window
  (2 s in the self-test, busier). The music is
  native, so it never stops.
- **Settings → Visualizer → Calm** (the author's call, off by default): the
  bars at 15 fps instead of 30 (`Playback.calm` → `FrameClock.fps`). It
  halves the window server's work for the bars (while sifting: 15 → 7.5%
  on Retina, 18 → 9.7% at 120 Hz),
  which is where nearly all of their cost is; the app's own processes
  barely change (its share 2.9 → 2.2%). The bars move by the time between
  frames, so they keep their speed.
- **Settings → Lyrics → Fill words letter by letter** (the author's call, on
  by default). Off (`body.whole-words`), `arm()` gives the sung line no lit
  copies and a sung word just takes the lit color, so nothing animates
  while it's sung: the lyrics state **14.6 → 10.3%** on Retina and
  13.8 → 11.2% at 120 Hz (2.2–4.3 points less in every run), and the
  window server 27.5 → 19.9% on Retina, **57 → 34%** at 120 Hz.

- **Lyrics glide on the compositor, glow in steps** (2026-09-25). The
  wheel no longer scrolls and no rAF loop runs. On each line change
  `place()` in `now.js` gives every line its final transform
  (`translateY/translateZ/rotateX`, and `scale(1.2)` for the sung line) and
  opacity once, and `.k-line`'s CSS transition glides it there (1.2 s,
  `cubic-bezier(.2, .1, .35, 1)`, fitted to within 1% of the old spring).
  What can't run on the compositor steps along with the glide from timers:
  the tints (3 steps plus 1 at the end, all lines) and the sung line's
  `--glow` (6 steps plus 1, two lines). A color repaints the line, and
  animating `--glow` in CSS alone cost about 3.5 points once the glide no
  longer hid it. Lines coming onto the panel first jump to where they'd
  have been (`.jump` on those lines only: on the whole wheel it would
  cancel glides still running on fast songs). The mouse wheel turns it by
  hand; "Fix a line…" makes it a plain scrolling list again.

  Measured old against new, alternating runs of the lyrics state on each
  screen (`scripts/bench.sh <app>` with the old web files in a copy of
  the app):

  | Lyrics and corner bars | Old | New |
  |---|---|---|
  | Retina 2×, 60 Hz (3 pairs) | 19.4% (app 4.2 / page 9.5 / graphics 5.8), 230 MB | **12.5%** (3.9 / 4.6 / 3.9), **180 MB** |
  | External 1×, 120 Hz (2 pairs) | 19.2% (4.5 / 9.6 / 5.1), 156 MB | **13.2%** (4.4 / 5.1 / 3.8), **138 MB** |

  WindowServer, which now runs the glides, rose about 1–2 points (Retina
  30.7% vs 28.8%), so the system as a whole saves about 5 points of the
  7. The page process's memory fell because the wheel is no longer a
  scrolling layer (146 → 100 MB on Retina). The self-test says ALL PASSED
  (the sung line 0 px off its spot after a page switch; no dropped page
  frames while gliding), and a burst of window pictures shows smooth
  glides, lines fading in at the bottom, and no jumps.

- **Visualizer drawn natively** (`BarsView`: Core Animation layers over a
  spot the page reports) at **30 fps**. The page gets only 4 updates a
  second. This took sifting from 23% to 6%.
- **Frames reach the page through `callAsyncJavaScript`** with arguments
  (one fixed script), not as new code each frame.
- **Lyrics wheel:**
  - rAF runs only while gliding, and a timer wakes at the next word;
  - lines rolled off the wheel are `.off` (no 3D layer), and each line is
    only as wide as its text;
  - the wheel values are registered non-inheriting (`@property`);
  - the fade is overlays, not a mask;
  - there's no per-word gradient sweep (that was the biggest cost), and the
    letter fill is a compositor reveal on the active line only.
- **Freed memory goes back to macOS** after indexing and after decoding
  (`Memory.giveBack()`).
- **Lyrics clock never steps back a hair while playing** (`setPos()` in
  `now.js`). Unevenly arriving position updates used to un-light a word
  and light it again, which showed as a quick flash. Keep this if the
  timing code is reworked.
- **The letter fill follows the lyrics clock, not an animation** (`fillStep()`
  in `now.js`, `.lit` in `pages.css`). Each sung word's lit copy is cut to
  the sung part (`clip-path`, `--f` from 0 to 1) and moved on every 50 ms from
  the same clock that decides which word is sung, so the two can't disagree.
  It used to be a compositor animation (transitions, then keyframes), and on
  a 120 Hz screen the compositor's copy ran ahead of the page's clock and was
  pulled back at each layer commit: the fill jumped ahead, lit the whole word
  and snapped back, over and over, worst on held notes. It never happened on
  the 60 Hz built-in screen, which is why tests there missed it. Found by
  replaying a real song with held notes (below) and reading the fill's edge
  out of window pictures taken 11 times a second: the old fill went 1110 ->
  1218 -> 1152 -> ... -> 1346 (the whole word) -> 1218; the new one only
  moves right. A held note now fills for as long as it's held (up to 10 s).
  What it costs (`--compare` against the build before, 2 runs each): the
  app's processes +1.1 points on the built-in screen and +1.9 at 120 Hz (the
  page repaints the word being sung 20 times a second), and the window
  server 5 points less at 60 Hz and 19 less at 120 Hz (32 -> 27%, 54 -> 35%),
  because the compositor no longer animates fills at the screen's full rate.
  `will-change` on the copies was tried on the way and measured out: ~23 MB
  more on the lyrics page.
- **Replaying a real song through the bench:** `SIFTER_BENCH_LYRICS_ID=<library
  id>` plays that song for the lyrics states (put it and its lyrics row into
  the bench's scratch library and database first) and `SIFTER_BENCH_AT=<s>`
  starts it there; `SIFTER_BENCH_SCREEN=2` for the other screen.
- **The visualizer's spot is re-reported when anything next to it changes
  size, or its column scrolls** (`Bars` in `core.js`): the corner spot on Now
  Playing is capped at 240 px, so a row appearing above it (the Edit button)
  moved it without resizing it, and the native bars stayed put, over the Edit
  button.
- **Two lyrics qualities** (`LyricsService.Quality`; Settings → Lyrics →
  Quality, and a choice in the one-time question). Standard is
  `openai_whisper-large-v3-v20240930_turbo_632MB` (646 MB) with voice-detection
  chunks, four at a time; Best is the full-precision
  `openai_whisper-large-v3-v20240930_turbo` (1,638 MB) read through each song
  whole (`chunkingStrategy: .none`), as the Python app does (its MLX
  large-v3-turbo is the same model at full precision). The compressed model and
  the chunking were both there from the start; on music, which is never
  really quiet, voice detection cuts lines mid-word and each chunk loses the
  words before it, which hurt more than expected (the author's words: the
  Standard lyrics were often too far off to want). Only the chosen model is
  kept: switching removes the other download. "Write them again"
  (`LibraryStore.forgetLyrics`) forgets Whisper's lyrics and "no words" rows so
  the worker writes them again; .lrc rows stay.
- **Backups can be restored** (`Backup.restore`, `LibraryStore.snapshot` /
  `merge`). Siftr knows a song by its file name and size, and backups name
  files by title, so a library copied back from a backup used to lose its
  plays, lyrics and sorting history. Every backup now also writes
  `.siftr-restore.json` (each song's original place in the library) and
  `.siftr-library.db` (a copy of the database, `VACUUM INTO`). Restore copies
  songs back under their original names, never replacing anything, then merges
  the history (`INSERT OR IGNORE`, plays and skips without duplicates). The
  self-test restores its own backup into a new library and database and checks
  every song is known again, with its plays and lyrics.
- **One Siftr per data folder** (`InstanceLock`: a `flock` on `<data>/.lock`
  with the holder's process number). A second copy opens the folder it was
  given in the first one, brings it forward and quits. Tests and the demo use
  their own data folders, so they run beside the real app.
- **Songs over 20 minutes** (`longSongSeconds`, and `LONG_SONG` in `core.js`)
  aren't decoded for the visualizer (a 2-hour mix would hold ~300 MB) or sent
  to Whisper (lyrics source `long`); they play and can be sorted.
- **Up next is sent in a window** (250 rows around the current song,
  `SiftController.window`; `SIFTER_QUEUE_WINDOW` to compare). Measured with
  `SIFTER_BIG_BATCH=<folder>` (the self-test's big-batch timing): a
  3,000-song batch showed the next song after a Pass in 336 ms (median) and
  1,300 ms at worst with the whole queue, 117 ms and 125 ms with the window.
- **Hover highlights only while the pointer moves** (`.k-lines.pointing`):
  lines gliding under a resting pointer each flashed the highlight.
- **No blur, glow, translucency or radial gradients**, and one solid
  background.

### The author's list: status and notes

**Visual rendering**

- **EQ visualizer frame rate capped at 30 fps:** done. `FrameClock` asks
  for 30, and the page itself updates 4 times a second.
- **EQ on the GPU with Metal, one draw call:** not tried, and probably
  not worth it (measured 2026-09-25). The bars are already drawn by the
  GPU through Core Animation (2 × N CALayers masking two gradient layers).
  Sifting on Retina, alternating runs: with all 96 bars moving the app
  used 2.65% and the window server 18.2%; with **only one bar moving**,
  2.4% and 15.25%; with 24 bars, 2.5% and 15.4%. So nearly all of the cost
  is the window changing 30 times a second, not the number of layers, and
  a Metal layer would still change the window 30 times a second. What does
  move it is the frame rate: the window server used ~19% at 30 fps, ~14.5%
  at 20 and **~9% at 15** (the app 2.65 → 2.25 → 2.1%). 30 fps is the
  author's choice (like the Windows app), so a lower rate is theirs to make,
  for example as a "calm" setting.

  **Tried and rejected (2026-09-25): one gradient layer per bar, no
  masks.** Each bar a `CAGradientLayer` (rounded, `masksToBounds`) whose
  end point sits above it, so it shows its slice of the tall gradient;
  the reflection the same way. It looked identical, but measured against
  the masked bars in alternating runs it cost more everywhere: the app
  2.8% → 4.9% (sifting) and 5.6% (big visualizer), and the window server
  about 3 points more (16.5 → 19.6 while sifting on Retina). Masks weren't
  the window server's cost.
- **Lyric rasterization into one static texture:** not tried. It conflicts
  with the 3D wheel and the per-word fill as they are. Possible routes:
  - **Native lyrics** (likely the biggest win): draw the lyrics like the
    bars, natively over a spot the page reports. Each line is rendered once
    with Core Text into a CALayer, glides are CA animations on the
    compositor, and the word fill is an animated mask on the active line.
    That takes WebKit out of the lyrics entirely.
  - **Simpler inside the page:** drop the 3D wheel and use a flat list with
    an opacity falloff.
- **Lyric translation** (move the pre-rendered lyrics instead of laying
  them out again): **done**, see "Lyrics glide on the compositor" above.
  The lines kept their 3D: each line gets its own transform transition,
  not one container, because every line's tilt changes as the wheel turns.
  The main thread now works once per line change instead of every frame.
- **Resource pooling:**
  - Already pooled: `BarsView` is one view, moved between pages;
    `Spectrum` is rebuilt only when the bar count changes; `makeBars()`
    rebuilds layers only when the count changes.
  - Not tried: hidden pages keep their DOM. Options are to drop the Library
    rows when leaving the Library, or to render only the rows in view.

**Testing and profiling**

- **Memory while toggling the EQ bars and height back and forth:** not run.
  Add a bench phase that drives the Settings sliders through JS; the
  self-test already does this once. Flip between 24 and 128 bars about 50
  times, then compare footprints before and after. Watch the app process
  for leaked CALayers (`makeBars()` removes the old ones).
- **Lyric timing data structures:** not run, and probably negligible.
  `position()` scans the lines linearly (about 70) on each sync, and
  `schedule()` looks at 3 lines at most. Time them with `performance.now()`
  in the page before changing anything; switch to a binary search only if
  it shows up. The `.lrc` or Whisper data is parsed once per song in Swift.
- **What each part of the lyrics costs** (measured 2026-09-25, Retina,
  two runs each, switching one part off with `SIFTER_BENCH_CSS`, where an
  `!important` rule beats the page's inline values): the letter-by-letter
  fill **2.4 points** in the app's processes and **7.4 points** of window
  server (22.3% instead of 29.7%); the glow 0.7; the tints 0.45; the
  glides 0.45 plus about 0.8 of window server. The fill is a compositor
  animation for as long as a word is sung, at the screen's full rate
  (hence 55% of window server at 120 Hz). The author asked for the letter
  fill, so a word-at-a-time fill would be their call (as an option, say).
- **CPU spikes at the moment lyrics change lines:** not run. The WebKit
  processes can't be sampled here (they're Apple system binaries), and
  Instruments needs full Xcode (this Mac has only the Command Line Tools).
  Use in-page timing instead: wrap `sync()` and `place()` in
  `performance.now()`. `sifter.test.resetJank()` collects the page's frame
  times for 3 s into `K.jank.dts`. Compare with the per-process CPU from
  bench.sh.

### Other options worth measuring

- Lyrics page: update the page once a second instead of 4 times, since the
  time text only changes each second and the progress bar moves less than a
  pixel per update.
- Decode the song for the bars in pieces around the play position instead
  of all at once, saving about 10 MB for a 4-minute song. It must keep the
  bars in sync. An `installTap` was rejected because its ~100 ms buffers
  look laggy.
- ~~Settings → Visualizer "calm" option~~: done (see "Already done").
  Fewer bars barely matter; the frame rate does (see the Metal item).
- ~~The page's pictures while minimized~~: done, the page rests (see
  "Already done"). What was measured before choosing that (2026-09-25, Retina):
  on the Library page the page process owns 72 MB of drawn tiles (25
  surfaces, mostly 1024×1024 pixels: the page and the list's scroll area,
  each with margins), and minimized it keeps them. They didn't shrink over
  80 s minimized, with the web view hidden, or with it taken out of the
  window (3 MB). What would free them, and the page's heap: discarding the
  web view after a long time minimized and loading the page again on
  restore (a moment of blank window then). Drastic, and a UX trade the
  author should decide on.

### How to measure (read before trusting a number)

- **`scripts/bench.sh`** measures each state with realistic songs: 4
  minutes long, a 250-song library and 70 lines of lyrics. The songs are
  cached in `$TMPDIR/sifter-bench-songs`.
  - `scripts/bench.sh --compare <old.app>` does a comparison properly by
    itself: the two builds take turns (new, old, new, old…), each state's
    median is taken, and a table shows new, old and the change. Add
    `--runs 3` for three turns each (20 s holds unless you set another).
  - `--runs 3` on its own repeats one build and prints medians with the
    lowest and highest.
  - It won't start on a locked screen, and warns about Low Power Mode and
    battery power. A state whose window wasn't on screen is left out of the
    medians, and listed.
  Options:
  - `SIFTER_BENCH_ONLY=now-lyrics` measures just one or more states;
  - `SIFTER_BENCH_HOLD=20` holds each state longer;
  - `SIFTER_BENCH_CSS='…'` switches parts of the page off for an
    experiment;
  - `SIFTER_BENCH_SHOTS=<folder>` saves real window pictures, native bars
    included; add `SIFTER_BENCH_BURST=24` for that many more, 0.15 s apart
    (`SIFTER_BENCH_GAP=0.03` packs them closer), before the measuring
    starts (to see motion, like a lyrics glide). They
    picture the app's window only. A locked screen gives stale pictures
    (check `visible=` in the log).
- **Which screen the window is on changes everything.** A Retina (2×)
  screen has 4 times the pixels, so the page's layers take about twice the
  memory (the lyrics state: ~180 MB on the built-in screen, ~138 MB on a
  1× monitor), and a 120 Hz screen doubles the compositor's frames. A new
  window opens on whichever screen has the keyboard focus, so the bench
  puts its window on the screen with the menu bar (`SIFTER_BENCH_SCREEN=2`
  for the next one) and prints `screen=2x@60Hz` in each state's line.
  Compare runs only on the same screen.
- **Compare versions side by side, not against old numbers.**
  `scripts/bench.sh --compare <other.app>` alternates the two for you (the
  Mac warms up and slows down over a session). The other copy can be an
  older build, or this one with the old web files copied into
  `Contents/Resources/web/` and re-signed (`codesign --force --sign -
  --options runtime`).
- **Numbers are noisy.** Run each case 2–3 times with 20 s holds, and make
  sure each run's `mode=` line shows the state you expect. A run whose
  lyrics never loaded shows `mode=slow`. One run in a session came out
  `mode=slow` with the app's memory falling steadily from 110 to 47 MB,
  probably macOS reclaiming memory (this Mac has 8 GB); throw such runs out.
- **Other apps' web views get counted if you're not careful.** Safari,
  Mail and many other apps run the same WebKit processes. The bench now
  counts only the app's own: its page process (the app prints its number,
  `page=`, at every state; it changes when the page loads again after
  resting) and the graphics and networking processes that started with
  it. Before this, a WebKit app opened during a run added its processes
  to the numbers (graphics at 15–24% while minimized was the tell).
- **The states** are idle, sifting, sifting-calm (Settings → Visualizer →
  Calm), sift-paused, now-lyrics, now-lyrics-whole (letter by letter off),
  now-visualizer, library, minimized and resting (the page let go:
  `bench.sh` sets `SIFTER_REST_AFTER=30` so it happens 30 s after
  minimizing instead of 10 minutes; the self-test uses 5).
- **WindowServer** is the number after the `;`. Animations handed to Core
  Animation (the bars, the lyrics glides) run there, so it shows work that
  moved out of the app. It's kept out of the total because everything on
  screen shares it, and it swings by 20 points between runs when anything
  else moves.
- **Low Power Mode caps the page at 30 fps**; check with `pmset -g`. A
  locked screen pauses the page completely, so keep the screen unlocked and
  the window uncovered.
- **`scripts/self_test.sh` must say ALL PASSED** after every change. Use
  `SIFTER_NO_SNAPSHOTS=1` for clean memory numbers, because screenshots
  inflate the app process. Test runs no longer save the window's size and
  place into the real preferences (they used to).
- **Keep the Mac awake for long sessions:** the screen saver locks this Mac
  after 10 minutes without input, and a locked screen stops all drawing.
  `caffeinate -d -t 10800` holds the display awake for 3 hours.
- **Profiling tools:**
  - `footprint`, `heap <pid>` and `sample <pid>` work on the app process;
  - `heap` shows live allocations against the footprint;
  - the WebKit processes can only be measured, not profiled.
- **Rules for tests:**
  - scratch folders only (`SIFTER_DATA`, `SIFTER_LIBRARY` and
    `SIFTER_TRASH`);
  - never your real library;
  - never delete music;
  - no personal names or real songs in files: placeholders only.
