#!/bin/bash
# Sets up a clean Siftr profile for recording screenshots and the demo GIF:
# ten short generated songs (tones, so there's nothing to license), a small
# library with two songs' synced lyrics and a few weeks of made-up listening
# history, and Siftr started with its own data, library, Trash and
# preferences. Your real library, decisions and settings aren't touched (the
# Open dialog may remember the demo folder as the last place you opened).
#
#   scripts/demo-setup.sh            make the demo (once) and open Siftr on it
#   scripts/demo-setup.sh --reset    throw the demo away and start over (quit Siftr first)
#   scripts/demo-setup.sh --drive    also mount a small disk image as a pretend
#                                    thumb drive, for the Backup page
#   scripts/demo-setup.sh --no-open  make it, don't start Siftr
#   DEMO=<folder> scripts/demo-setup.sh    somewhere else (default: ~/Siftr Demo)
#
# Needs ffmpeg (brew install ffmpeg) and the built app (./build.sh), or
# SIFTR_APP=/Applications/Siftr.app.
set -euo pipefail
cd "$(dirname "$0")/.."
DEMO="${DEMO:-$HOME/Siftr Demo}"
APP="${SIFTR_APP:-build/Siftr.app}"
PREFS=com.siftr.demo                     # the demo's own preferences domain
DRIVE="DEMO DRIVE"
reset=0 drive=0 open=1
for arg in "$@"; do
  case $arg in
    --reset) reset=1 ;;
    --drive) drive=1 ;;
    --no-open) open=0 ;;
    *) echo "Unknown option: $arg (see the top of $0)" >&2; exit 2 ;;
  esac
done
FF=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
[[ -x "$FF" ]] || { echo "Needs ffmpeg: brew install ffmpeg" >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/Siftr" || $open == 0 ]] || { echo "No app at $APP: run ./build.sh first, or set SIFTR_APP" >&2; exit 1; }

if [[ $reset == 1 && -e "$DEMO" ]]; then
  # only ever a folder this script made
  [[ -f "$DEMO/.siftr-demo" && "$DEMO" != "$HOME" && "$DEMO" != / ]] || { echo "$DEMO isn't a Siftr demo folder: leaving it alone" >&2; exit 1; }
  hdiutil detach "/Volumes/$DRIVE" -quiet 2>/dev/null || true
  rm -rf "$DEMO"
  defaults delete "$PREFS" 2>/dev/null || true
  echo "Removed the old demo."
fi

NEW="$DEMO/New Music"          # the folder to sort on camera
LIB="$DEMO/Library"            # the demo's library
DATA="$DEMO/Profile/Data"      # its decisions, plays and lyrics (library.db)
TRASH="$DEMO/Profile/Trash"    # where Finish batch sends New Music

if [[ ! -f "$DEMO/.siftr-demo" ]]; then
  if [[ -e "$DEMO" && -n "$(ls -A "$DEMO" 2>/dev/null)" ]]; then
    echo "$DEMO already exists and isn't a Siftr demo: pick another place with DEMO=<folder>" >&2; exit 1
  fi
  echo "Making the demo in $DEMO ..."
  mkdir -p "$NEW" "$LIB" "$DATA" "$TRASH"
  touch "$DEMO/.siftr-demo"

  cover() {  # out, two colors
    "$FF" -loglevel error -y -f lavfi -i "gradients=s=600x600:c0=$2:c1=$3:x0=0:y0=0:x1=600:y1=600:d=1" -frames:v 1 "$1"
  }
  cover "$DEMO/Profile/ep.png" 0x6c8cff 0xff78be
  cover "$DEMO/Profile/a.png" 0xffb347 0xd6336c
  cover "$DEMO/Profile/b.png" 0x2fd06f 0x1b3a8c

  # A made-up tune: four chords (Am F C G, moved to another key), a kick on
  # every beat, a hi-hat between, bass and an arpeggio -- enough for the
  # visualizer to dance to.
  song() {  # out, title, album, cover, semitones, bpm, chord offset, encoder options...
    local out=$1 title=$2 album=$3 art=$4 key b off; shift 4
    key=$(awk -v s="$1" 'BEGIN { printf "%.5f", 2 ^ (s / 12) }')
    b=$(awk -v bpm="$2" 'BEGIN { printf "%.4f", 60 / bpm }')
    off=$3; shift 3
    local e="st(0,floor(t/(4*$b)));st(1,mod(ld(0)+$off,4))"
    e+=";st(2,$key*if(eq(ld(1),0),220,if(eq(ld(1),1),174.61,if(eq(ld(1),2),261.63,196))))"
    e+=";st(3,if(eq(ld(1),0),1.1892,1.2599));st(4,mod(t,$b));st(5,mod(t+$b/2,$b))"
    e+=";st(6,mod(floor(t/($b/2)),3));st(7,mod(t,$b/2))"
    e+=";0.7*(0.07*(sin(2*PI*ld(2)*t)+sin(2*PI*ld(2)*ld(3)*t)+sin(2*PI*ld(2)*1.4983*t))*(0.7+0.3*sin(2*PI*0.25*t))"
    e+="+0.5*sin(2*PI*(45+110*exp(-ld(4)*35))*ld(4))*exp(-ld(4)*9)"
    e+="+0.1*(2*random(9)-1)*exp(-ld(5)*55)"
    e+="+0.22*sin(PI*ld(2)*t)*exp(-ld(4)*3)"
    e+="+0.09*sin(4*PI*ld(2)*if(eq(ld(6),0),1,if(eq(ld(6),1),ld(3),1.4983))*t)*exp(-ld(7)*7))"
    "$FF" -loglevel error -y -f lavfi -i "aevalsrc=exprs='$e':s=44100:d=45" -i "$art" \
      -filter_complex "[0:a]afade=t=in:d=1.5,afade=t=out:st=42:d=3,volume=1.5,aformat=channel_layouts=stereo[a]" \
      -map "[a]" -map 1:v -disposition:v attached_pic \
      -metadata "title=$title" -metadata "artist=Sample Artist" -metadata "album=$album" "$@" "$out"
  }
  mp3=(-c:a libmp3lame -b:a 192k -c:v mjpeg -id3v2_version 3)
  m4a=(-c:a aac -b:a 192k -c:v png)
  flac=(-c:a flac -c:v png)
  song "$NEW/Sample Song 01.mp3"  "Sample Song 01" "Sample EP" "$DEMO/Profile/ep.png"   0 112 0 "${mp3[@]}"
  song "$NEW/Sample Song 02.m4a"  "Sample Song 02" "Sample EP" "$DEMO/Profile/ep.png"   3  96 1 "${m4a[@]}"
  song "$NEW/Sample Song 03.flac" "Sample Song 03" "Sample EP" "$DEMO/Profile/ep.png"  -2 124 2 "${flac[@]}"
  song "$NEW/Sample Song 04.mp3"  "Sample Song 04" "Sample EP" "$DEMO/Profile/ep.png"   5 104 3 "${mp3[@]}"
  song "$NEW/Sample Song 05.m4a"  "Sample Song 05" "Sample EP" "$DEMO/Profile/ep.png"  -4 118 0 "${m4a[@]}"
  song "$NEW/Sample Song 06.mp3"  "Sample Song 06" "Sample EP" "$DEMO/Profile/ep.png"   2 100 2 "${mp3[@]}"
  song "$LIB/Sample Song 07.mp3"  "Sample Song 07" "Sample Album A" "$DEMO/Profile/a.png"  7  98 1 "${mp3[@]}"
  song "$LIB/Sample Song 08.m4a"  "Sample Song 08" "Sample Album A" "$DEMO/Profile/a.png" -3 108 3 "${m4a[@]}"
  song "$LIB/Sample Song 09.flac" "Sample Song 09" "Sample Album B" "$DEMO/Profile/b.png"  4 120 0 "${flac[@]}"
  song "$LIB/Sample Song 10.mp3"  "Sample Song 10" "Sample Album B" "$DEMO/Profile/b.png" -5  92 2 "${mp3[@]}"

  # synced lyrics for two library songs (made up), one line every 3.4 s
  lrc() {  # out, title, then the lines
    local out=$1 title=$2 i=0 t; shift 2
    { echo "[ti:$title]"; echo "[ar:Sample Artist]"
      for line in "$@"; do
        t=$(awk -v i="$i" 'BEGIN { s = 2 + i * 3.4; printf "%02d:%05.2f", int(s / 60), s - 60 * int(s / 60) }')
        echo "[$t]$line"; i=$((i + 1))
      done; } > "$out"
  }
  lrc "$LIB/Sample Song 07.lrc" "Sample Song 07" \
    "Porch light humming in the evening" "Counting cars along the avenue" \
    "Every window holds a different story" "I keep the ones that sound like you" \
    "Paper maps across the kitchen table" "Pencil circles where we never went" \
    "Radio is playing something older" "Half the words we never really meant" \
    "Porch light humming in the evening" "Counting cars along the avenue" \
    "Every window holds a different story" "I keep the ones that sound like you"
  lrc "$LIB/Sample Song 08.lrc" "Sample Song 08" \
    "Morning comes in shades of silver" "Coffee cooling on the windowsill" \
    "Somewhere out there someone's humming" "Every song I haven't heard yet still" \
    "Turn it up and let the room decide" "Hold it close or let it pass me by" \
    "Every little tune a door left open" "Every little tune a reason why" \
    "Turn it up and let the room decide" "Hold it close or let it pass me by" \
    "Every little tune a door left open" "Every little tune a reason why"

  # when each library song "arrived" (the Library takes it from the file's date)
  back() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  back 50 "$LIB/Sample Song 07.mp3"; back 50 "$LIB/Sample Song 08.m4a"
  back 70 "$LIB/Sample Song 09.flac"; back 5 "$LIB/Sample Song 10.mp3"

  # The database, with the app's own tables (LibraryStore.swift). A song's
  # library ID is the first 16 hex digits of SHA-256("<file name, lowercase>|<bytes>").
  libid() { printf '%s' "$(basename "$1" | tr '[:upper:]' '[:lower:]')|$(stat -f %z "$1")" | shasum -a 256 | cut -c1-16; }
  at() { date -v-"$1"d -v"$2"H -v"$3"M -v0S +%s; }   # days ago, hour, minute
  {
    cat <<'SQL'
CREATE TABLE IF NOT EXISTS sorted (key TEXT PRIMARY KEY, decision TEXT, title TEXT, src TEXT, copied TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS library (id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT, artist TEXT, album TEXT,
  duration REAL, size INTEGER, mtime REAL, added REAL, art TEXT);
CREATE TABLE IF NOT EXISTS plays (id TEXT, at REAL);
CREATE INDEX IF NOT EXISTS plays_id ON plays(id);
CREATE TABLE IF NOT EXISTS skips (id TEXT, at REAL);
CREATE TABLE IF NOT EXISTS lyrics (id TEXT PRIMARY KEY, segments TEXT, source TEXT, made REAL);
CREATE TABLE IF NOT EXISTS timing (id TEXT PRIMARY KEY, seconds REAL);
BEGIN;
SQL
    # "no words" for every song without an .lrc -- including the six to sort,
    # whose IDs stay the same once kept -- so Whisper never starts in the demo
    for f in "$NEW"/*.* "$LIB/Sample Song 09.flac" "$LIB/Sample Song 10.mp3"; do
      echo "INSERT INTO lyrics VALUES ('$(libid "$f")', '[]', 'none', $(date +%s));"
    done
    s07=$(libid "$LIB/Sample Song 07.mp3") s08=$(libid "$LIB/Sample Song 08.m4a")
    s09=$(libid "$LIB/Sample Song 09.flac") s10=$(libid "$LIB/Sample Song 10.mp3")
    # 07 heats up (6 plays this week, 2 the week before), 08 cools off (1 vs 5)
    for d in 1 2 3 4 5 6 8 11 16 20; do echo "INSERT INTO plays VALUES ('$s07', $(at "$d" 20 $((d * 5 % 60))));"; done
    for d in 2 8 9 10 12 13 18 22 25; do echo "INSERT INTO plays VALUES ('$s08', $(at "$d" 19 $((d * 2))));"; done
    # 09: the most played, but not for a month (a forgotten favorite)
    for d in 60 58 55 52 50 47 45 43 40 38 36 35; do echo "INSERT INTO plays VALUES ('$s09', $(at "$d" 21 10));"; done
    # 10: new this week and mostly skipped
    echo "INSERT INTO plays VALUES ('$s10', $(at 3 18 30));"
    for d in 1 2 3 4; do echo "INSERT INTO skips VALUES ('$s10', $(at "$d" 17 45));"; done
    echo "COMMIT;"
  } | sqlite3 "$DATA/library.db"

  # its own preferences: lyrics on (so there's no one-time question), the rest default
  defaults delete "$PREFS" 2>/dev/null || true
  defaults write "$PREFS" lyrics -bool true
  rm -f "$DEMO/Profile/"*.png
else
  echo "Using the demo already in $DEMO (--reset starts over)."
fi

if [[ $drive == 1 ]]; then
  img="$DEMO/Profile/Demo Drive.dmg"
  [[ -f "$img" ]] || hdiutil create -quiet -size 64m -fs ExFAT -volname "$DRIVE" "$img"
  [[ -d "/Volumes/$DRIVE" ]] || hdiutil attach -quiet "$img"
  echo "Mounted \"$DRIVE\" for the Backup page (eject: hdiutil detach \"/Volumes/$DRIVE\")."
fi

if [[ $open == 1 ]]; then
  SIFTER_PREFS=$PREFS SIFTER_DATA="$DATA" SIFTER_LIBRARY="$LIB" SIFTER_TRASH="$TRASH" \
    nohup "$APP/Contents/MacOS/Siftr" >/dev/null 2>&1 &
  echo "Siftr is starting on the demo profile."
fi
echo
echo "To sort on camera: Open Folder (or drag it onto the window): $NEW"
echo "For a fresh take afterwards: quit Siftr, then scripts/demo-setup.sh --reset"
