# Live test: the self-healing system-audio tap

Written so it can be handed to a smaller model as-is. Follow it literally; when anything doesn't match what this page
says, **stop and report** — do not improvise, do not change code.

## What is being tested

macOS 26 can keep the app's system-audio tap running while it delivers only silence (chopped, then total). The app
(app/Audio.swift: `TapWatch`, `SystemAudioSource`) now watches what the tap delivers and makes a new tap when it goes
silent while another app plays sound, judges each new tap on its first 15 s, backs off when new taps don't help, makes a
new tap when the tap hands over nothing at all (stall check), and tells the user only when the sound really isn't coming
in. This test runs the real app with the real tap and real tap rebuilds, but no sound is heard:

- `afplay` plays a file of **digital silence** so the Mac's audio output is running (the tap delivers nothing otherwise);
- inside the app, `LECTURE_TEST_TAP_TONE=1` replaces what the tap hears with a tone, and the test switches
  `LECTURE_TEST_TAP_CHOP` / `_SILENCE` / `_HEALS` / `_DEAD` make the tap fail the way macOS's does;
  `LECTURE_TEST_PLAYING=1` answers "another app is playing sound";
- `LECTURE_SLIDES=0` keeps 슬라이드 PDF off (no window picker); `LECTURE_TEST_START/STOP/QUIT` press 시작, 정지 and quit.

Files: `tests/live_tap_test.sh` (runs the scenarios), `tests/live_tap_eval.py` (judges the logs, PASS/FAIL).

## Rules (all of them, always)

1. Never play audible sound. The only audio is `afplay` of the silence file the script makes.
2. Never click, type or answer dialogs on screen. The macOS permission prompt is answered **by the owner**.
3. Never touch `/Applications/Arc 강의 받아쓰기.app` (no copy, move, open or quit) and never quit an app the owner is using.
4. Never write to `~/Downloads/강의기록` or `~/강의기록`; never read or write anything in the app's container
   (`~/Library/Containers/io.github.joshichoi.lecture-scribe/`) except reading `…/Data/Library/Application
   Support/LectureScribe/logs/app.log` — the script already does exactly that and nothing else.
5. Never edit, commit or push anything in the repo. Never run `rm`.
6. Run one scenario at a time, never two apps at once.
7. If a check fails or anything unexpected happens (a dialog you didn't expect, the app doesn't quit, a crash report,
   a process left running), stop and report what you saw. Do not retry a failing scenario more than once.

## Step 0 — preconditions (all must hold, otherwise stop and report)

```bash
APP="/Users/josh/dev/lecture-scribe/build/v2-fix/Arc 강의 받아쓰기.app"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"   # must print 2.6.1
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"              # must print 261
pgrep -fl "Arc 강의"                                                                         # must print nothing
pgrep -fl afplay                                                                            # must print nothing
ls -t ~/Library/Logs/DiagnosticReports | head -3                                            # note what is there
date -u +%Y-%m-%dT%H:%M:%SZ                                                                 # note the start time
```

If `pgrep -fl "Arc 강의"` prints anything, the owner may be recording a lecture: **stop and report, do not quit it.**

Make a results folder in the session scratchpad (the path is given to you), e.g. `R=<scratchpad>/livetest-results`,
and `mkdir -p "$R"`.

## Step 1 — the permission prompt (owner clicks Allow)

This build is newly signed, so macOS asks once whether "Arc 강의 받아쓰기" may record system audio. The owner has been
told to click **Allow** when it appears. Run:

```bash
cd /Users/josh/dev/lecture-scribe && RESULTS_DIR="$R" tests/live_tap_test.sh "$APP" permission
```

It takes about 75 s (the app window appears; the prompt appears a few seconds in). Then:

```bash
python3 tests/live_tap_eval.py "$R"
```

`permission` must show `PASS  macOS let the tap start (prompt answered)`. If it FAILs, run Step 1 once more. If it
fails again, stop and report "permission prompt not answered" — do not run the scenarios.

## Step 2 — the four scenarios, one at a time

Run each command, wait for it to return (the script waits until the app has quit), then go to the next:

```bash
cd /Users/josh/dev/lecture-scribe
RESULTS_DIR="$R" tests/live_tap_test.sh "$APP" heals    # ~75 s
RESULTS_DIR="$R" tests/live_tap_test.sh "$APP" never    # ~145 s
RESULTS_DIR="$R" tests/live_tap_test.sh "$APP" dead     # ~105 s
RESULTS_DIR="$R" tests/live_tap_test.sh "$APP" stop     # ~40 s
```

After each run the script prints the run's capture lines and "left running: nothing". If anything is left running,
stop and report. Use a Bash timeout of at least 300000 ms per command.

What each scenario does and what must happen (times = seconds after the first audio):

| Scenario | The test makes the tap… | Must happen | Must NOT happen |
|---|---|---|---|
| `heals` | chop (110 ms silent / 20 ms sound) from 20 s; the first new tap is healthy | new tap #1 at ~20–26 s; "new tap #1 hears the sound" 13–19 s later; recording ~57 s | a second new tap, "didn't help", any "told the user" |
| `never` | totally silent from 20 s to 80 s; new taps don't help | new tap #1 at ~25 s → "didn't help — next not before 15 s" → new tap #2 → "didn't help — next not before 60 s" → "told the user the sound isn't coming in" (once) → after the sound returns at 80 s, "told the user the sound is back" at ~88–99 s; recording ~127 s | new tap #3, stall rebuilds, a second notice |
| `dead` | chop from 20 s; new tap #1 hands over nothing at all; the next is healthy | new tap #1 → "test: this tap hands nothing over" → 10–25 s later "nothing from the tap … → new tap" → "new tap #2 hears the sound" 13–22 s later | any "told the user", new tap #3 |
| `stop` | silent from 15 s; 정지 is pressed at ~21 s, around a new tap | "capture: stopped" is the last capture line; recording ~20 s | any "told the user"; any capture line after "capture: stopped" |

Every scenario also needs: `app started 2.6.1`, a "capture: test switches — …" line showing the switches as meant
(the evaluator checks it: a misread switch makes the scenario test nothing), "capture: audio callback #1", no "new tap
failed", "capture: stopped", and the app quitting by itself.

## Step 3 — judge and check for crashes

```bash
python3 tests/live_tap_eval.py "$R" > "$R/eval.txt"; echo "evaluator exit code: $?"; cat "$R/eval.txt"
ls -t ~/Library/Logs/DiagnosticReports | head -5     # any NEW file mentioning LectureScribe or Arc = a crash: report it
pgrep -fl "Arc 강의|afplay" || echo "nothing left running"
```

## Step 4 — report

Report, in this order:
1. The preconditions (version/build printed, nothing running at the start).
2. Whether the permission step passed (and on which attempt).
3. For each scenario: the lines the script printed (capture lines only) and the evaluator's PASS/FAIL lines.
4. The evaluator's last line (`ALL PASS` or `SOME CHECKS FAILED`) and its exit code.
5. New crash reports (or "none") and leftover processes (or "none").
6. Anything unexpected you saw, verbatim. Do not interpret failures or suggest code changes — just report.

All logs stay in `$R` (`<scenario>.log`, `eval.txt`); give that path.
