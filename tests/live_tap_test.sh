#!/bin/bash
# Live test of the tap self-heal (TapWatch and SystemAudioSource in app/Audio.swift) — procedure and pass criteria in
# tests/LIVE_TAP_TEST.md. Silent: afplay plays a file of digital zeros so the output device runs (nothing audible);
# inside the app LECTURE_TEST_TAP_TONE puts a tone in place of what the tap hears, and the _CHOP / _SILENCE / _HEALS /
# _DEAD hooks make the tap fail the way macOS's does. LECTURE_SLIDES=0: no window picker.
# Reads only the app's own log in its container; the test recordings go to the container's tmp.
#
# usage: RESULTS_DIR=<dir> tests/live_tap_test.sh "<path to the .app>" <scenario>…
#        scenarios: permission heals never dead stop
set -u
APP="$1"; shift
C="$HOME/Library/Containers/io.github.joshichoi.lecture-scribe/Data"
LOG="$C/Library/Application Support/LectureScribe/logs/app.log"
OUT="$C/tmp/taptest-$(date +%Y%m%d-%H%M%S)"
RES="${RESULTS_DIR:-$(mktemp -d)}"
mkdir -p "$RES" "$OUT"
SIL="$RES/silence-180s.wav"
[ -f "$SIL" ] || python3 -c "import wave, sys
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(bytes(180 * 48000 * 4)); w.close()" "$SIL"
touch "$LOG"

run() {
  local name=$1 stop=$2; shift 2
  local before t0 player
  before=$(wc -l < "$LOG")
  afplay "$SIL" & player=$!
  t0=$(date +%s)
  open -n -W --env LECTURE_OUT_DIR="$OUT/$name" --env LECTURE_SLIDES=0 --env LECTURE_TEST_START=3 \
       --env LECTURE_TEST_STOP="$stop" --env LECTURE_TEST_QUIT=$((stop + 12)) --env LECTURE_TEST_QUIT_ANSWER=quit \
       "$@" "$APP"
  kill "$player" 2>/dev/null; wait "$player" 2>/dev/null
  tail -n +$((before + 1)) "$LOG" > "$RES/$name.log"
  echo "== $name: $(( $(date +%s) - t0 )) s wall · full log: $RES/$name.log"
  grep -E "app started|capture:|session saved" "$RES/$name.log" | grep -v "audio callback #200" | sed -E 's/^[0-9-]+T//'
}

TAP=(--env LECTURE_TEST_TAP_TONE=1 --env LECTURE_TEST_PLAYING=1)
for s in "$@"; do
  case $s in
    permission) run permission 60 ;;
    heals) run heals 60 "${TAP[@]}" --env LECTURE_TEST_TAP_CHOP=20-300 --env LECTURE_TEST_TAP_HEALS=1 ;;
    never) run never 130 "${TAP[@]}" --env LECTURE_TEST_TAP_SILENCE=20-80 ;;
    dead)  run dead 90 "${TAP[@]}" --env LECTURE_TEST_TAP_CHOP=20-300 --env LECTURE_TEST_TAP_HEALS=1 --env LECTURE_TEST_TAP_DEAD=1 ;;
    stop)  run stop 24 "${TAP[@]}" --env LECTURE_TEST_TAP_SILENCE=15-300 ;;
    *) echo "unknown scenario: $s"; exit 2 ;;
  esac
done
echo "== left running:"; pgrep -fl "Arc 강의|afplay" || echo "nothing"
