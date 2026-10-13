#!/usr/bin/env python3
"""Judges the logs tests/live_tap_test.sh wrote (one <scenario>.log per run in RESULTS_DIR) against the expectations in
tests/LIVE_TAP_TEST.md. Times are seconds after the first tap's first audio ("capture: audio callback #1"), with 2 s of
slack for the log's whole-second stamps. Prints PASS/FAIL per check; exit code 0 only if every check of every log
present passes.   usage: python3 tests/live_tap_eval.py <RESULTS_DIR>"""
import os, re, sys

SLACK = 2
LINE = re.compile(r"^(\d{4}-\d\d-\d\dT(\d\d):(\d\d):(\d\d)Z) (.*)$")


def load(path):
    rows = []
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = LINE.match(raw.rstrip("\n"))
        if m:
            rows.append((int(m.group(2)) * 3600 + int(m.group(3)) * 60 + int(m.group(4)), m.group(5)))
    return rows


class Run:
    def __init__(self, name, rows):
        self.name, self.rows, self.results = name, rows, []
        first = [t for t, msg in rows if "capture: audio callback #1" in msg]
        self.t0 = first[0] if first else None

    def at(self, t):
        return None if t is None or self.t0 is None else t - self.t0

    def find(self, pattern, after=None):
        """first line matching pattern (regex) at or after `after` (absolute seconds): (time, message) or (None, None)"""
        for t, msg in self.rows:
            if (after is None or t >= after - SLACK) and re.search(pattern, msg):
                return t, msg
        return None, None

    def count(self, pattern):
        return sum(1 for _, msg in self.rows if re.search(pattern, msg))

    def check(self, label, ok, evidence=""):
        self.results.append((label, bool(ok), evidence))

    def window(self, label, t, lo, hi, base=None, evidence=""):
        """t within [lo, hi] seconds after base (absolute) or after t0"""
        ref = base if base is not None else self.t0
        ok = t is not None and ref is not None and lo - SLACK <= t - ref <= hi + SLACK
        rel = "missing" if t is None or ref is None else f"{t - ref:+d} s"
        self.check(f"{label} [{lo}…{hi} s]", ok, f"{rel}  {evidence}".strip())

    def saved(self, lo, hi):
        _, msg = self.find(r"session saved: \d+ lines, \d+:\d\d")
        secs = None
        if msg:
            m = re.search(r"session saved: \d+ lines, (\d+):(\d\d)", msg)
            secs = int(m.group(1)) * 60 + int(m.group(2))
        self.check(f"recording length {lo}…{hi} s", secs is not None and lo <= secs <= hi, msg or "no 'session saved' line")

    def common(self, version):
        self.check(f"app started {version}", self.count(rf"app started {re.escape(version)}\b") >= 1)
        self.check("first tap's audio arrived", self.t0 is not None)
        self.check("no 'new tap failed'", self.count(r"capture: new tap failed") == 0)
        self.check("capture: stopped", self.count(r"capture: stopped") >= 1)
        caps = [msg for _, msg in self.rows if msg.startswith("capture:")]
        self.check("nothing from capture after 'capture: stopped'", bool(caps) and caps[-1] == "capture: stopped",
                   caps[-1] if caps else "")


SWITCHES = {   # what each scenario's "capture: test switches" line must say (the app's own reading of them)
    "heals": ["tone true", "playing true", "chop 20-300", "heals 1", "dead 0"],
    "never": ["tone true", "playing true", "silence 20-80", "heals never", "dead 0"],
    "dead": ["tone true", "playing true", "chop 20-300", "heals 1", "dead 1"],
    "stop": ["tone true", "playing true", "silence 15-300", "heals never", "dead 0"],
}


def judge(name, rows, version):
    r = Run(name, rows)
    if name in SWITCHES:
        _, sw = r.find(r"capture: test switches — ")
        r.check("the app read the test switches as meant", bool(sw) and all(x in sw for x in SWITCHES[name]), sw or "no switches line")
    if name == "permission":
        r.check("macOS let the tap start (prompt answered)", r.count(r"capture: start device → 0") >= 1)
        return r
    r.common(version)
    if name == "heals":
        t1, m1 = r.find(r"while another app plays sound → new tap #1$")
        r.window("new tap #1 once the chop starts", t1, 19, 26, evidence=m1 or "")
        t2, m2 = r.find(r"capture: new tap #1 hears the sound", t1)
        r.window("new tap #1 hears the sound", t2, 13, 19, base=t1, evidence=m2 or "")
        r.check("no second new tap", r.count(r"new tap #2") == 0)
        r.check("no 'didn't help'", r.count(r"didn't help") == 0)
        r.check("no notice to the user", r.count(r"told the user") == 0)
        r.check("no stall rebuild", r.count(r"nothing from the tap") == 0)
        r.saved(53, 60)
    elif name == "never":
        t1, m1 = r.find(r"s of exact silence while another app plays sound → new tap #1$")
        r.window("new tap #1 for silence", t1, 24, 29, evidence=m1 or "")
        t2, m2 = r.find(r"capture: new tap #1 didn't help — the next not before 15 s", t1)
        r.window("new tap #1 didn't help", t2, 14, 19, base=t1, evidence=m2 or "")
        t3, m3 = r.find(r"s of exact silence while another app plays sound → new tap #2$", t2)
        r.window("new tap #2 after the 15 s wait", t3, 14, 22, base=t2, evidence=m3 or "")
        t4, m4 = r.find(r"capture: new tap #2 didn't help — the next not before 60 s", t3)
        r.window("new tap #2 didn't help", t4, 14, 19, base=t3, evidence=m4 or "")
        t5, m5 = r.find(r"capture: told the user the sound isn't coming in")
        r.window("user told (once silence ≥ 45 s despite new taps)", t5, 0, 9, base=t4, evidence=m5 or "")
        r.check("told only once", r.count(r"told the user the sound isn't coming in") == 1)
        t6, m6 = r.find(r"capture: told the user the sound is back", t5)
        r.window("user told the sound is back (silence ends at 80 s)", t6, 88, 99, evidence=m6 or "")
        r.check("'sound is back' only once", r.count(r"told the user the sound is back") == 1)
        r.check("no third new tap", r.count(r"new tap #3") == 0)
        r.check("no stall rebuild", r.count(r"nothing from the tap") == 0)
        r.saved(122, 130)
    elif name == "dead":
        t1, m1 = r.find(r"while another app plays sound → new tap #1$")
        r.window("new tap #1 once the chop starts", t1, 19, 26, evidence=m1 or "")
        t2, m2 = r.find(r"capture: test: this tap hands nothing over", t1)
        r.window("that tap hands nothing over (test)", t2, 0, 3, base=t1, evidence=m2 or "")
        t3, m3 = r.find(r"capture: nothing from the tap for \d+ s while another app plays sound → new tap", t2)
        r.window("stall check makes a new tap", t3, 10, 25, base=t2, evidence=m3 or "")
        t4, m4 = r.find(r"capture: new tap #2 hears the sound", t3)
        r.window("new tap #2 hears the sound", t4, 13, 22, base=t3, evidence=m4 or "")
        r.check("no notice to the user", r.count(r"told the user") == 0)
        r.check("no third new tap", r.count(r"new tap #3") == 0)
        r.saved(62, 85)
    elif name == "stop":
        r.check("no notice to the user", r.count(r"told the user") == 0)
        r.saved(17, 23)
    return r


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    version = os.environ.get("EXPECT_VERSION", "2.6.1")
    all_ok, any_log = True, False
    for name in ["permission", "heals", "never", "dead", "stop"]:
        p = os.path.join(d, name + ".log")
        if not os.path.exists(p):
            continue
        any_log = True
        r = judge(name, load(p), version)
        print(f"\n== {name}" + (f"  (t0 = first audio at {r.t0 // 3600:02d}:{r.t0 % 3600 // 60:02d}:{r.t0 % 60:02d} UTC)" if r.t0 else ""))
        for label, ok, ev in r.results:
            all_ok &= ok
            print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"   — {ev}" if ev else ""))
    if not any_log:
        print("no logs found in", d)
        return 2
    print("\nALL PASS" if all_ok else "\nSOME CHECKS FAILED")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
