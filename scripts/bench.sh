#!/bin/bash
# Measures memory and CPU in each everyday state -- sifting, paused, lyrics,
# the big visualizer, browsing, minimized -- with realistic songs: 4 minutes
# long, a 250-song library, 70 lines of synced lyrics. Scratch folders only
# (never your real library or settings), volume 0. A window shows for about
# two minutes a run: keep the screen unlocked and the window uncovered.
#
#   scripts/bench.sh                         one run of build/Siftr.app (after ./build.sh)
#   scripts/bench.sh --runs 3                three runs, and the median of each state
#   scripts/bench.sh --compare <old.app>     this build against another, runs alternating
#                                            (new, old, new, old...), medians and the difference
#   scripts/bench.sh <other.app>             measure another copy of the app instead
#   SIFTER_BENCH_HOLD=20 scripts/bench.sh    hold each state longer (default 12 s; 20 s for comparisons)
#   SIFTER_BENCH_ONLY=sifting,now-lyrics scripts/bench.sh    just those states
#   SIFTER_BENCH_SHOTS=<folder> [SIFTER_BENCH_BURST=20 SIFTER_BENCH_GAP=0.05]   pictures of the app window
#   SIFTER_BENCH_SCREEN=2 scripts/bench.sh   on the second screen (default: the one with the menu bar)
#
# A state whose window wasn't on screen (a locked or covered screen) is left
# out of the medians, and said so: nothing is drawn then, so it would look cheap.
# Needs ffmpeg for the test songs (brew install ffmpeg).
set -uo pipefail
cd "$(dirname "$0")/.."
APP=build/Siftr.app OTHER="" RUNS=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --runs) RUNS=${2:?--runs needs a number}; shift 2 ;;
    --compare) OTHER=${2:?--compare needs another app}; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) APP=$1; shift ;;
  esac
done
for a in "$APP" ${OTHER:+"$OTHER"}; do
  [[ -x "$a/Contents/MacOS/Siftr" ]] || { echo "No app at $a (run ./build.sh first)" >&2; exit 1; }
done
[[ -n $OTHER ]] && export SIFTER_BENCH_HOLD=${SIFTER_BENCH_HOLD:-20}

# What makes numbers wrong without anything failing
if ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  echo "The screen is locked: macOS draws nothing then, so nothing can be measured. Unlock it first." >&2; exit 1
fi
pmset -g | grep -Eq 'lowpowermode +1' && echo "WARNING: Low Power Mode is on: the page runs at 30 frames a second, so animations cost less than usual. Compare only with runs made the same way."
pmset -g batt | grep -q "Battery Power" && echo "WARNING: on battery. Plugged in, the Mac runs more steadily."

FF=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
CACHE="${TMPDIR:-/tmp}/sifter-bench-songs"          # made once, reused
RESULTS=$(mktemp -d "${TMPDIR:-/tmp}/sifter-bench-results.XXXXXX")

song() {  # out, seconds, tone Hz, cover colors (or -), then encoder options
  local out=$1 len=$2 hz=$3 art=$4; shift 4
  local inputs=(-f lavfi -i "anoisesrc=d=$len:c=pink:a=0.35:r=44100" -f lavfi -i "sine=f=$hz:d=$len:sample_rate=44100")
  local maps=(-map "[a]")
  if [[ $art != - ]]; then
    "$FF" -loglevel error -y -f lavfi -i "gradients=s=600x600:c0=${art%/*}:c1=${art#*/}:x0=0:y0=0:x1=600:y1=600:d=1" -frames:v 1 "$CACHE/cover.png"
    inputs+=(-i "$CACHE/cover.png"); maps+=(-map 2:v -disposition:v attached_pic)
  fi
  "$FF" -loglevel error -y "${inputs[@]}" \
    -filter_complex "[0:a][1:a]amix=inputs=2:weights=1 0.6,volume='0.55+0.45*sin(2*PI*1.7*t)':eval=frame,aformat=channel_layouts=stereo[a]" \
    "${maps[@]}" "$@" "$out"
}
if [[ ! -f "$CACHE/done" ]]; then
  echo "Making realistic test songs once (about a minute)..."
  mkdir -p "$CACHE/songs" "$CACHE/library/Short"
  song "$CACHE/songs/01 Batch One.mp3"   240 220 0x6c8cff/0xff78be -c:a libmp3lame -b:a 192k -c:v mjpeg -id3v2_version 3 -metadata "title=Batch One" -metadata "artist=Bench Artist" -metadata "album=Bench Batch"
  song "$CACHE/songs/02 Batch Two.m4a"   240 330 0x2fd06f/0x1b3a8c -c:a aac -b:a 192k -c:v png -metadata "title=Batch Two" -metadata "artist=Bench Artist" -metadata "album=Bench Batch"
  song "$CACHE/songs/03 Batch Three.flac" 240 440 0xffb347/0xd6336c -c:a flac -c:v png -metadata "title=Batch Three" -metadata "artist=Bench Artist" -metadata "album=Bench Batch"
  song "$CACHE/library/Long L.mp3" 240 260 0x6c8cff/0xff78be -c:a libmp3lame -b:a 192k -c:v mjpeg -id3v2_version 3 -metadata "title=Long L" -metadata "artist=Bench Artist" -metadata "album=Bench Album"
  song "$CACHE/library/Long N.mp3" 240 390 0xffb347/0xd6336c -c:a libmp3lame -b:a 192k -c:v mjpeg -id3v2_version 3 -metadata "title=Long N" -metadata "artist=Bench Artist" -metadata "album=Bench Album"
  # 70 synced lines across the song, about as many as a real one
  { echo "[ti:Long L]"
    words=(Riding through the city all night headlights burning on the highway I ain\'t tired I can\'t sleep clouds rolling past my window hold a stance by the water paper lanterns over the harbor)
    for i in $(seq 0 69); do
      t=$((2 + i * 33 / 10)); line=""
      for j in 0 1 2 3 4 5; do line+="${words[$(( (i * 7 + j * 5) % ${#words[@]} ))]} "; done
      printf "[%02d:%02d.00]%s\n" $((t / 60)) $((t % 60)) "${line% }"
    done; } > "$CACHE/library/Long L.lrc"
  # 250 short songs so the Library page has a realistic number of rows
  song "$CACHE/short.mp3" 3 500 - -c:a libmp3lame -b:a 128k
  for i in $(seq -w 1 250); do cp "$CACHE/short.mp3" "$CACHE/library/Short/Track $i.mp3"; done
  touch "$CACHE/done"
fi

# One run of one app: measures every state, prints its table, and writes one
# CSV line per state to $RESULTS/<label>-<n>.csv for the summary.
run_once() {  # app, label, run number
  local bin="$1/Contents/MacOS/Siftr" csv="$RESULTS/$2-$3.csv"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/sifter-bench.XXXXXX")
  mkdir -p "$WORK/data" "$WORK/library" "$WORK/trash" "$WORK/songs"
  cp -R "$CACHE/songs/." "$WORK/songs/"
  cp -R "$CACHE/library/." "$WORK/library/"

  echo "Running the bench (a window shows for about two minutes; keep it uncovered)..."
  now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
  before=" $(pgrep -f 'com.apple.WebKit' | tr '\n' ' ') "
  # macOS's compositor: animations handed to Core Animation run there, so it's
  # measured too -- apart, since everything else on screen shares it
  ws=$(pgrep -x WindowServer | head -1)
  # the page rests 30 s after the window is minimized (10 minutes for real), after "minimized" is measured
  SIFTER_REST_AFTER=30 SIFTER_DATA="$WORK/data" SIFTER_LIBRARY="$WORK/library" SIFTER_TRASH="$WORK/trash" \
    "$bin" --self-test "$WORK/songs" "$WORK/report.txt" --bench > "$WORK/log.txt" 2>&1 &
  pid=$!
  : > "$WORK/samples.txt"
  measured=" "
  # Which WebKit processes are the app's: its page process, as the app reports
  # it at each state (it changes when the page loads again after resting), and
  # the graphics and networking processes new by the first state. WebKit
  # processes that start later belong to some other app and aren't counted.
  shared=""
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -z "$shared" ]] && grep -q '^START' "$WORK/log.txt" 2>/dev/null; then
      shared=$(pgrep -f 'com.apple.WebKit.(GPU|Networking)' | while read -r p; do [[ "$before" == *" $p "* ]] || echo "$p"; done | paste -sd, -)
      shared=${shared:-none}
    fi
    page=$(grep '^START' "$WORK/log.txt" 2>/dev/null | tail -1 | sed -n 's/.* page=\([0-9]*\).*/\1/p')
    if [[ -n "$shared" && -n "$page" && "$page" != 0 ]]; then
      kids="$page${shared:+,$shared}"; kids=${kids%,none}
    else    # until the first state (or without the page's number): every new WebKit process
      kids=$(pgrep -f 'com.apple.WebKit' | while read -r p; do [[ "$before" == *" $p "* ]] || echo "$p"; done | paste -sd, -)
    fi
    ps -o pid=,rss=,time=,comm= -p "$pid${kids:+,$kids}${ws:+,$ws}" 2>/dev/null | sed "s|^|$(now) |" >> "$WORK/samples.txt"
    for ph in $(grep '^START ' "$WORK/log.txt" 2>/dev/null | awk '{print $2}'); do
      if [[ "$measured" != *" $ph "* ]]; then
        measured+="$ph "
        sleep 2
        footprint $pid ${kids//,/ } > "$WORK/footprint-$ph.txt" 2>&1
      fi
    done
    sleep 0.5
  done
  wait "$pid"

  echo
  grep -E "^library:|FAIL|^page " "$WORK/log.txt"
  grep "^START" "$WORK/log.txt" | grep "visible=no" | grep -vE "START (minimized|resting)" | sed 's/^/WARNING (window not on screen: locked or covered?) /'
  grep "^END" "$WORK/log.txt" | awk '{printf "  %-16s %s %s %s\n", $2, $4, $5, $6}'
  awk -v logf="$WORK/log.txt" -v dir="$WORK" -v csv="$csv" -v apppid="$pid" '
    function mb(s,  v) { v = s + 0; if (s ~ /KB/) v /= 1024; else if (s ~ /GB/) v *= 1024; return v }
    function secs(t,  a, n) { n = split(t, a, /[:.]/); return (n == 3) ? a[1]*60 + a[2] + a[3]/100 : a[1]*3600 + a[2]*60 + a[3] + a[4]/100 }
    BEGIN {
      while ((getline line < logf) > 0) {
        split(line, f, " ")
        if (f[1] == "START") { order[++n] = f[2]; st[f[2]] = f[3]; vis[f[2]] = f[4] }
        if (f[1] == "END") en[f[2]] = f[3]
      }
    }
    $5 ~ /^\(/ { next }                               # a process that has just quit
    { ts = $1; pid = $2; nm = $5; sub(/.*\//, "", nm); if (pid == apppid) nm = "Siftr"; name[pid] = nm; cpu = secs($4)   # by pid: an app path can have spaces
      for (i = 1; i <= n; i++) { p = order[i]
        if (ts >= st[p] + 2.5 && !(p SUBSEP pid in c0)) { c0[p, pid] = cpu; t0[p, pid] = ts }
        if (ts <= en[p]) { c1[p, pid] = cpu; t1[p, pid] = ts }
      }
    }
    END {
      printf "\n%-16s %8s %8s %8s %8s %8s   %s\n", "state", "memory", "app", "page", "graphics", "CPU", "(CPU: % of one core; app / page / graphics; window server, shared)"
      for (i = 1; i <= n; i++) { p = order[i]; tot = 0; parts = ""
        for (q in name) if ((p, q) in c0 && t1[p, q] > t0[p, q]) {
          v = 100 * (c1[p, q] - c0[p, q]) / (t1[p, q] - t0[p, q]); if (name[q] != "WindowServer") tot += v
          cp[name[q]] = v
        }
        mem = ""; ma = mp = mg = ""
        fp = dir "/footprint-" p ".txt"
        while ((getline l < fp) > 0) {
          if (l ~ /Summary Footprint/) { split(l, x, ": "); mem = x[2]; gsub(/ +$/, "", mem) }
          if (l ~ /Footprint: / && l ~ /64-bit/) {
            m = l; sub(/.*Footprint: /, "", m); sub(/ \(.*/, "", m)
            if (l ~ /^Siftr/) ma = m; else if (l ~ /WebContent/) mp = m; else if (l ~ /WebKit.GPU/) mg = m
          }
        }
        close(fp)
        printf "%-16s %8s %8s %8s %8s %7.1f%%   %.1f / %.1f / %.1f; %.1f\n", p, mem, ma, mp, mg, tot, cp["Siftr"], cp["com.apple.WebKit.WebContent"], cp["com.apple.WebKit.GPU"], cp["WindowServer"]
        # shown on screen, as it should be? (minimized and resting are meant to be put away)
        ok = (vis[p] == "visible=yes" || p == "minimized" || p == "resting") ? 1 : 0
        printf "%s,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n", p, mb(mem), mb(ma), mb(mp), mb(mg), tot, cp["Siftr"], cp["com.apple.WebKit.WebContent"], cp["com.apple.WebKit.GPU"], cp["WindowServer"], ok > csv
        delete cp
      }
    }' "$WORK/samples.txt"
  echo "Details: $WORK"
  rm -rf "${WORK:?}/songs" "${WORK:?}/library" "${WORK:?}/data" "${WORK:?}/trash" 2>/dev/null
}

# The Mac warms up and slows down over a session, so two builds take turns
# (new, old, new, old...) instead of one going first every time.
labels=() apps=() nums=()
for ((i = 1; i <= RUNS; i++)); do
  labels+=(new) apps+=("$APP") nums+=("$i")
  [[ -n $OTHER ]] && { labels+=(old) apps+=("$OTHER") nums+=("$i"); }
done
for k in "${!labels[@]}"; do
  echo
  echo "== Run ${nums[$k]} of $RUNS: ${labels[$k]} (${apps[$k]})"
  run_once "${apps[$k]}" "${labels[$k]}" "${nums[$k]}"
done

# The summary: each state's median over the runs where its window was on screen
if (( RUNS > 1 )) || [[ -n $OTHER ]]; then
  python3 - "$RESULTS" "$RUNS" "$([[ -n $OTHER ]] && echo compare)" <<'PY'
import csv, glob, os, statistics, sys
results, runs, compare = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "compare"
rows, order, skipped = {}, [], []
for path in sorted(glob.glob(os.path.join(results, "*.csv"))):
    label = os.path.basename(path).split("-")[0]
    for r in csv.reader(open(path)):
        state = r[0]
        if state not in order: order.append(state)
        if r[10] != "1": skipped.append(f"{label} {state}"); continue
        rows.setdefault((label, state), []).append([float(x) for x in r[1:10]])
def med(label, state, col):
    v = [r[col] for r in rows.get((label, state), [])]
    return (statistics.median(v), len(v)) if v else (None, 0)
fmt = lambda v, unit: "   --" if v is None else f"{v:6.1f}{unit}"
print()
if compare:
    print(f"Medians over {runs} alternating run(s) each; memory in MB, CPU in % of one core (window server apart)")
    print(f"{'state':<17}{'memory new':>11}{'old':>8}{'change':>9}   {'CPU new':>8}{'old':>8}{'change':>9}   {'window server new / old':>24}")
    for s in order:
        (mn, n1), (mo, n2) = med("new", s, 0), med("old", s, 0)
        (cn, _), (co, _) = med("new", s, 4), med("old", s, 4)
        (wn, _), (wo, _) = med("new", s, 8), med("old", s, 8)
        dm = "" if mn is None or mo is None else f"{mn - mo:+8.1f}"
        dc = "" if cn is None or co is None else f"{cn - co:+8.1f}"
        print(f"{s:<17}{fmt(mn, ''):>11}{fmt(mo, ''):>8}{dm:>9}   {fmt(cn, '%'):>8}{fmt(co, '%'):>8}{dc:>9}   "
              f"{fmt(wn, '%'):>11} / {fmt(wo, '%'):<8}{'' if n1 == n2 == runs else f'  ({n1} new, {n2} old runs counted)'}")
else:
    print(f"Medians over {runs} runs (lowest to highest in brackets); memory in MB, CPU in % of one core")
    for s in order:
        v = rows.get(("new", s), [])
        if not v: print(f"{s:<17} no run counted"); continue
        m, c = [r[0] for r in v], [r[4] for r in v]
        print(f"{s:<17}{statistics.median(m):7.1f} MB ({min(m):.0f}-{max(m):.0f})   {statistics.median(c):5.1f}% ({min(c):.1f}-{max(c):.1f})"
              f"{'' if len(v) == runs else f'   ({len(v)} of {runs} runs counted)'}")
if skipped:
    print("Left out (the window wasn't on screen: a locked or covered screen?):", ", ".join(skipped))
PY
fi
