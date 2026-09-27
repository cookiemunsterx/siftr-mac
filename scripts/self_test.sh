#!/bin/bash
# Runs the app's built-in self-test (--self-test) on a folder of generated
# test songs, with scratch data / library / trash folders -- never your real
# ones -- and measures its memory and CPU while playing and paused.
# A window appears for about a minute; the test plays at volume 0.
#
#   scripts/self_test.sh                  (after ./build.sh)
#   scripts/self_test.sh --whisper        also switches lyrics on for real, with
#                                         Whisper's small test model (~75 MB download)
#
# Needs ffmpeg for the test songs (brew install ffmpeg).
set -uo pipefail
cd "$(dirname "$0")/.."
APP="build/Siftr.app"; [[ -n "${1:-}" && "${1:-}" != "--whisper" ]] && APP="$1"
BIN="$APP/Contents/MacOS/Siftr"
FF=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sifter-selftest.XXXXXX")
OUT="${SELFTEST_OUT:-$WORK}"
SONGS="$WORK/songs"
mkdir -p "$SONGS/.hidden" "$WORK/data" "$WORK/library" "$WORK/trash" "$OUT"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

echo "Making test songs in $SONGS ..."
cover() {
  "$FF" -loglevel error -y -f lavfi -i "gradients=s=600x600:c0=$2:c1=$3:x0=0:y0=0:x1=600:y1=600:d=1" -frames:v 1 "$1"
}
song() {  # out, tone Hz, cover png or -, then encoder options
  local out=$1 hz=$2 art=$3; shift 3
  local inputs=(-f lavfi -i "anoisesrc=d=30:c=pink:a=0.35:r=44100" -f lavfi -i "sine=f=$hz:d=30:sample_rate=44100")
  local maps=(-map "[a]")
  if [[ $art != - ]]; then inputs+=(-i "$art"); maps+=(-map 2:v -disposition:v attached_pic); fi
  "$FF" -loglevel error -y "${inputs[@]}" \
    -filter_complex "[0:a][1:a]amix=inputs=2:weights=1 0.6,volume='0.55+0.45*sin(2*PI*1.7*t)':eval=frame,aformat=channel_layouts=stereo[a]" \
    "${maps[@]}" "$@" "$out"
}
cover "$WORK/a.png" 0x6c8cff 0xff78be
cover "$WORK/b.png" 0x2fd06f 0x1b3a8c
cover "$WORK/c.png" 0xffb347 0xd6336c
song "$SONGS/01 Song A.mp3"  110 "$WORK/a.png" -c:a libmp3lame -b:a 160k -c:v mjpeg -id3v2_version 3 -metadata "title=Song A" -metadata "artist=Test Artist" -metadata "album=Album A"
song "$SONGS/02 Song B.m4a"  165 "$WORK/b.png" -c:a aac -b:a 160k -c:v png -metadata "title=Song B" -metadata "artist=Test Artist" -metadata "album=Album B"
song "$SONGS/03 Song C.flac" 220 "$WORK/c.png" -c:a flac -c:v png -metadata "title=Song C" -metadata "artist=Test Artist" -metadata "album=Album C"
song "$SONGS/04 Song D.ogg"  330 - -c:a vorbis -strict -2 -metadata "title=Song D" -metadata "artist=Test Artist" -metadata "album=Album D"
head -c 200000 /dev/urandom > "$SONGS/05 broken.mp3"
song "$SONGS/06 Song E.wav"  440 - -c:a pcm_s16le -metadata "title=Song E" -metadata "artist=Test Artist"
cp "$SONGS/01 Song A.mp3" "$SONGS/.hidden/secret.mp3"      # hidden folder: must be skipped
# the library starts with three songs: two in one album (one with synced lyrics), one on its own
song "$WORK/library/Song L.mp3"  196 "$WORK/a.png" -c:a libmp3lame -b:a 160k -c:v mjpeg -id3v2_version 3 -metadata "title=Song L" -metadata "artist=Test Artist" -metadata "album=Album L"
song "$WORK/library/Song M.m4a"  247 "$WORK/a.png" -c:a aac -b:a 160k -c:v png -metadata "title=Song M" -metadata "artist=Test Artist" -metadata "album=Album L"
mkdir -p "$WORK/library/Test Artist"
song "$WORK/library/Test Artist/Song N.flac" 294 "$WORK/c.png" -c:a flac -c:v png -metadata "title=Song N" -metadata "artist=Test Artist" -metadata "album=Album N"
cat > "$WORK/library/Song L.lrc" <<'LRC'
[ti:Song L]
[00:00.50]Riding through the city all night
[00:03.50]Headlights burning on the highway
[00:06.50]I ain't tired, I can't sleep
[00:09.50]Clouds rolling past my window
[00:12.50]Hold a stance by the water
[00:15.50]Paper lanterns over the harbor
[00:18.50]Everything I counted
[00:21.50]Slipping past the gate
[00:24.50]Echo in the hall
LRC
head -c 4096 /dev/zero > "$SONGS/._01 Song A.mp3"            # macOS shadow file: must be skipped
echo "not a song" > "$SONGS/notes.txt"
if [[ "${1:-}" == "--whisper" || "${2:-}" == "--whisper" ]]; then
  # a spoken clip for the real lyrics test (the small test model: about 75 MB, into the scratch folder)
  say -o "$WORK/spoken.aiff" "Riding through the city all night. The lights are shining on my face tonight."
  "$FF" -loglevel error -y -i "$WORK/spoken.aiff" -c:a aac -b:a 128k "$WORK/spoken.m4a"
  export SIFTER_SPOKEN="$WORK/spoken.m4a"
  export SIFTER_LYRICS_MODEL="${SIFTER_LYRICS_MODEL:-openai_whisper-tiny}"
fi

echo "Running the self-test (a window will appear for about a minute)..."
before=" $(pgrep -f 'com.apple.WebKit' | tr '\n' ' ') "
# the page rests 5 s after the window is put away, not 10 minutes (the last check tests it)
SIFTER_REST_AFTER=5 SIFTER_DATA="$WORK/data" SIFTER_LIBRARY="$WORK/library" SIFTER_TRASH="$WORK/trash" \
  "$BIN" --self-test "$SONGS" "$OUT/report.txt" > "$OUT/log.txt" 2>&1 &
pid=$!
: > "$OUT/samples.txt"
measured=0
while kill -0 "$pid" 2>/dev/null; do
  kids=$(pgrep -f 'com.apple.WebKit' | while read -r p; do [[ "$before" == *" $p "* ]] || echo "$p"; done | paste -sd, -)
  t=$(now)
  ps -o pid=,rss=,time=,comm= -p "$pid${kids:+,$kids}" 2>/dev/null | sed "s|^|$t |" >> "$OUT/samples.txt"
  if [[ $measured == 0 ]] && grep -q "PHASE playing" "$OUT/log.txt" 2>/dev/null; then
    measured=1
    sleep 3
    footprint $pid ${kids//,/ } > "$OUT/footprint-sifting.txt" 2>&1
  fi
  if [[ $measured == 1 ]] && grep -q "PHASE now-playing" "$OUT/log.txt" 2>/dev/null; then
    measured=2
    sleep 3
    footprint $pid ${kids//,/ } > "$OUT/footprint-now-playing.txt" 2>&1
  fi
  sleep 0.5
done
wait "$pid"; status=$?

echo
cat "$OUT/report.txt" 2>/dev/null || { echo "No report -- the app's output:"; cat "$OUT/log.txt"; }
echo
echo "=== Resource use (the app + its web engine processes) ==="
for f in sifting now-playing; do
  echo "Memory (what Activity Monitor calls Memory), $f page:"
  grep -E "Footprint:" "$OUT/footprint-$f.txt" 2>/dev/null | sed -E 's/ \[[0-9]+\]: 64-bit +Footprint: /|/; s/ \(.*//' | awk -F'|' '{printf "  %-30s %s\n", $1, $2}'
done
# CPU used per phase: cumulative CPU time at the phase's start and end
awk -v rep="$OUT/report.txt" '
  function secs(t,  a, n) { n = split(t, a, /[:.]/); return (n == 3) ? a[1]*60 + a[2] + a[3]/100 : a[1]*3600 + a[2]*60 + a[3] + a[4]/100 }
  BEGIN {
    while ((getline line < rep) > 0) if (line ~ /^PHASE /) { split(line, f, " "); ph[f[2]] = f[3] }
  }
  { ts = $1; pid = $2; rss[pid] = $3; name[pid] = $5; cpu = secs($4)
    if (ts <= ph["playing"] + 0.5)      { p0[pid] = cpu; }
    if (ts <= ph["paused-start"])        { p1[pid] = cpu; t1 = ts }
    if (ts <= ph["paused-start"] + 3.5)  { q0[pid] = cpu; tq = ts }
    if (ts <= ph["paused-end"])          { q1[pid] = cpu; t2 = ts }
    if (ts <= ph["playing"] + 0.5) tp = ts
    if (rss[pid] > peak[pid]) peak[pid] = rss[pid]
  }
  END {
    printf "%-34s %10s %10s %12s\n", "process", "playing", "paused", "peak RSS"
    for (p in name) {
      n = name[p]; sub(/.*\//, "", n)
      play = (t1 > tp) ? 100 * (p1[p] - p0[p]) / (t1 - tp) : 0
      rest = (t2 > tq) ? 100 * (q1[p] - q0[p]) / (t2 - tq) : 0
      printf "%-34s %9.1f%% %9.1f%% %9.0f MB\n", n, play, rest, peak[p] / 1024
      tpl += play; trs += rest; tpk += peak[p] / 1024
    }
    printf "%-34s %9.1f%% %9.1f%% %9.0f MB\n", "TOTAL", tpl, trs, tpk
  }' "$OUT/samples.txt"
# the bulky scratch files (test songs, library, any lyrics model) go; the report and screenshots stay
rm -rf "${WORK:?}/songs" "${WORK:?}/library" "${WORK:?}/data" "${WORK:?}/trash" 2>/dev/null
rm -f "${WORK:?}/a.png" "${WORK:?}/b.png" "${WORK:?}/c.png" "${WORK:?}/spoken.aiff" "${WORK:?}/spoken.m4a"
rm -rf "${OUT:?}/fake drive" 2>/dev/null
echo
echo "Screenshots, log and samples: $OUT"
exit $status
