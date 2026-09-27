# Siftr guide

Everything Siftr does, page by page. The short version is in the
[README](../README.md).

Siftr keeps your whole music library in one folder, with one place to see
how you listen to it: plays, trends and lyrics. New music comes in by ear. Pick a folder of new songs (a "batch"),
and it plays each one for you to judge:

- **Keep (K):** copies the song into your library folder (`~/Music/Siftr` unless you pick another)
- **Pass (P):** remembers you passed, leaves the file alone
- **Skip (S):** decides nothing and sends the song to the back of the queue

Songs you've already judged are left out the next time you open that folder,
so you can stop and come back. Keep makes a copy, and undoing a Keep moves
that copy (and only that copy) to the Trash. Nothing else is ever moved or
deleted unless you ask with **Finish batch**:

- **Finish batch** (bottom right of Sifting, or File → Finish Batch…): when
  you're done with a batch, the app checks that every song you kept is safely
  in your library, shows what's about to happen, and after you say yes moves
  the batch folder to the Trash (you can still take it back out from there).
  Songs you haven't sorted yet need an extra tick. It won't finish your home
  folder, a whole drive, the library, or a Mac folder like Downloads.

**One library folder.** Everything lives in one folder (subfolders are
fine). Settings → Library → **Change…** points the app at a different
folder. That moves nothing: the app just looks there instead. Batches are
temporary: once they're finished, nothing about them needs tracking.

## The pages

Switch pages with the buttons in the middle of the toolbar, or ⌘1–⌘6.

- **Sifting**: the song being judged, with its cover, a live visualizer,
  back / forward 10 seconds around play, Keep / Pass / Skip right in the
  player, what's up next (double-click to jump to a song), what you've
  sorted this session, and Finish batch.
- **Library**: every song you've kept. **Songs** (sort by any column,
  search), **Albums** (covers, and a page per album), and **Lyrics** (find
  a song by a line you remember, even with the spelling a bit off, and it
  starts playing right at that line). Click anywhere on a song's row to
  play it (or press Enter on it); the list it's in plays on from there, and
  you stay in the Library: **Now Playing** on the mini player (or ⌘3) takes
  you there when you want. The **Status**
  column says where each song stands: Playing, New (added this week, not
  played yet), Lyrics, Lyrics soon or No words.
- **Now Playing**: whatever's playing, big, with previous / next song and
  back / forward 10 seconds. With lyrics, they roll past on a wheel and each
  word fills in, letter by letter, as it's sung (or lights up whole, if you
  turn that off in Settings), with the visualizer in the corner under the
  controls. Click a line to jump there.
  The **Edit ▾** menu holds the rest: nudge the timing Earlier / Later if
  it's off, Reset timing, or **Fix a line…** to correct a misheard word.
  Without lyrics, a big visualizer. While it's showing the
  song being sifted, Keep / Pass / Skip work here too.
- **Leaderboard**: your most played songs, with listening time. A song
  counts as played once it plays to the end.
- **Trends**: most played this week, heating up / cooling off (after two
  weeks), forgotten favorites, songs you skip a lot, fresh adds, and
  listening time by album.
- **Backup**: copies your library onto a thumb drive, SD card or external
  disk, in album folders with a playlist file, plus a copy of Siftr's
  history (plays, lyrics, what you sorted). Only new songs are copied after
  the first time, and nothing is ever deleted from the drive. **Restore…**
  (on a drive with a backup) puts the songs back into your library under
  their original names, so Siftr knows them again, and brings their history
  back. Songs already in your library are left as they are; nothing is
  replaced or deleted. Use it after losing your library, or on a new Mac.

A mini player sits at the bottom while you browse. **Settings** (the gear,
or ⌘,) has the color **looks** (Aurora, Hilltop, Original, Sunset, Ocean,
Forest, Fire, or your own), the **visualizer** (how many bars, 24–128, how
tall they reach, the same everywhere, and **Calm**: 15 frames a second
instead of 30, for the least load), lyrics (Whisper, and **Fill words
letter by letter**: off lights each word up whole, which is lighter), and
where your library is. With macOS's Reduce Motion on, the lyrics fade into
place instead of turning the wheel, and each word lights up whole.

## Lyrics

The first time you visit Now Playing or the Lyrics search, the app asks once
whether you'd like lyrics, and says exactly what that involves:

- **What:** Whisper large-v3-turbo, OpenAI's free, open-source speech-to-text
  model, in the version made for Apple's
  Neural Engine (WhisperKit). It's easy on the graphics chip.
- **Download:** once, from Hugging Face, into
  `~/Library/Application Support/Siftr/Models`, and only the one you pick:
  - **Standard, 646 MB:** a compressed version of the model, and quick. It
    can mishear busy songs.
  - **Best, 1.6 GB:** the full model, reading each song straight through.
    Much closer on busy songs, and slower.
- **Private:** it runs only on your Mac, and nothing is uploaded.
- **Time:** the first start takes a few minutes to get ready, then the songs
  are written out newest first, in the background while the app is open.
  The model is unloaded from memory when it's done.

Settings → Lyrics → **Quality** switches between the two (the downloaded
model is replaced, so only one is ever kept). **Write them again** redoes the
songs Whisper already did, with the quality chosen now; lyrics from `.lrc`
files stay, and lines you fixed by hand are written again too.

"No thanks" hides lyrics everywhere until you turn them on in Settings, where
you can also remove the model. A synced `.lrc` file with the same name as a
song is used automatically, with or without Whisper.

## Opening music

- The first time, macOS asks you to approve Siftr once: see Install in the
  [README](../README.md#install).
- Click **Open Folder** (or press ⌘O), or drag a folder onto the window or
  onto the app's Dock icon.

| Key | Does |
|---|---|
| K / P / S | Keep / Pass / Skip (on Sifting, or Now Playing while it shows the song being sifted) |
| Space | Play / pause |
| ← / → | Back / forward 5 seconds |
| ↑ / ↓ | Volume up / down 5 |
| ⌘← / ⌘→ | Previous / next song |
| ⌘Z | Undo the last Keep or Pass (the song comes back to play again) |
| ⌘1 – ⌘6 | The pages |
| ⌘O / ⌘, | Open a folder / Settings |

The shortcuts step aside while you're typing in a search box. The play/pause
key on your keyboard, headphone buttons and Control Center work too.

## Long songs and big batches

A batch can hold as many songs as you like: Up next shows the part around
the song playing. A single song longer than 20 minutes (a mix, a live set)
plays and can be sorted, but without the visualizer (it would mean holding
the whole song in memory) or lyrics (Whisper would take ages over it).

Only one Siftr runs at a time: opening it again (another copy, too) brings
the one that's running to the front.

## Where things go

- Your library: `~/Music/Siftr`, or the folder you picked in Settings
  (subfolders are fine: the Library lists everything in there)
- Finished batches: the Trash
- The app's memory of decisions, plays, lyrics and the library index:
  `~/Library/Application Support/Siftr/library.db`
- The lyrics model, if you say yes: `~/Library/Application Support/Siftr/Models`
- Backups: a `Siftr Backup` folder on the drive you pick
- Settings (look, volume, window size and place): macOS's normal preferences

Nothing is sent anywhere. The only network use is the optional lyrics model
download, and only after you say yes.

**Used it when it was called Music Sifter?** Nothing needs doing. The first
launch of Siftr moves `Application Support/Music Sifter Lite` to
`Application Support/Siftr` (your decisions, plays, lyrics and the model come
along). An existing `~/Music/Music Sifter` library stays where it is and stays
your library, and a drive that already has a `Music Sifter Backup` folder
keeps backing up into it. Your settings carry over too.

## Formats

MP3, M4A (AAC/ALAC), FLAC, WAV and OGG (Vorbis and Opus) all play through
macOS itself; nothing extra is installed. Title, artist, album and cover art
come from the songs' tags. Files that won't play say "Could not play this
file", and you can still Pass or Skip them.
