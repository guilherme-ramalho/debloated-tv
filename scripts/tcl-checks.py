#!/usr/bin/env python3
"""TV side of the TCLChecks UI test (TESTING.md REM-17/18/19 on a real TV): answers <dir>/<step>.ready with
<dir>/<step>.go after reading or pressing things on the TV over ADB (mute state from dumpsys audio, the TV's own
mute key, the D-pad keys the remote service injects as seen by getevent). Writes tv.* lines to <dir>/results.txt
next to the app's lines, and raw captures beside them. Needs network debugging on and this Mac's key allowed.

  python3 scripts/tcl-checks.py <dir> &          # TV_ADB=<host:port>, default 192.168.0.13:5555
  (cd ios && TEST_RUNNER_TCL_CHECKS_DIR=<dir> xcodebuild test -project TVRemote.xcodeproj \
     -scheme "Debloated TV Dev" -destination "id=<simulator paired with the TV>" \
     -only-testing:TVRemoteUITests/TCLChecks -parallel-testing-enabled NO)

The simulator needs the RELEASE app installed and paired (scripts/store-shots-auto.sh builds it). Mutes and unmutes
the TV and sends a few D-pad keys to whatever is on screen; it leaves the TV unmuted."""
import os, subprocess, sys, time

DIR = sys.argv[1]
SERIAL = os.environ.get("TV_ADB", "192.168.0.13:5555")
RESULTS = os.path.join(DIR, "results.txt")


def adb(*args, timeout=20):
    return subprocess.run(["adb", "-s", SERIAL, *args], capture_output=True, text=True, timeout=timeout).stdout


def tv_muted():
    out = adb("shell", "dumpsys audio")
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "- STREAM_MUSIC:":
            for nxt in lines[i + 1:i + 4]:
                if nxt.strip().startswith("Muted:"):
                    return nxt.split(":", 1)[1].strip()
    return "?"


def foreground():
    out = adb("shell", "dumpsys window | grep mCurrentFocus")
    return out.strip().split("/")[0].split()[-1] if out.strip() else "?"


def note(name, value):
    line = f"tv.{name}={value}\n"
    print(line, end="", flush=True)
    with open(RESULTS, "a") as f:
        f.write(line)


capture = {}


def start_capture(tag):
    adb("logcat", "-c")
    f = open(os.path.join(DIR, f"{tag}-getevent.txt"), "w")
    capture[tag] = (subprocess.Popen(["adb", "-s", SERIAL, "shell", "getevent", "-lt"], stdout=f, stderr=subprocess.STDOUT), f)


def stop_capture(tag):
    proc, f = capture.pop(tag)
    time.sleep(1)
    proc.terminate(); f.close()
    adb("shell", "pkill getevent")
    with open(os.path.join(DIR, f"{tag}-logcat.txt"), "w") as out:
        out.write(adb("logcat", "-d", timeout=30))
    keys = []
    for line in open(os.path.join(DIR, f"{tag}-getevent.txt")):
        if "EV_KEY" in line and line.split()[-1] == "DOWN":
            keys.append(line.split("EV_KEY")[1].split()[0])
    return keys


def go(step):
    open(os.path.join(DIR, f"{step}.go"), "w").close()


handled = set()
deadline = time.time() + 1800
while time.time() < deadline:
    for name in sorted(os.listdir(DIR)):
        if not name.endswith(".ready"):
            continue
        step = name[:-6]
        if step in handled:
            continue
        handled.add(step)
        print(f"-- {step}", flush=True)
        if step == "rem17-start":
            note("rem17.start.muted", tv_muted()); note("foreground", foreground())
        elif step == "rem17-muted-from-app":
            note("rem17.afterAppMute.muted", tv_muted())
            adb("shell", "input keyevent KEYCODE_VOLUME_MUTE"); time.sleep(1.5)
            note("rem17.afterTVKey1.muted", tv_muted())
        elif step == "rem17-unmuted-from-tv":
            adb("shell", "input keyevent KEYCODE_VOLUME_MUTE"); time.sleep(1.5)
            note("rem17.afterTVKey2.muted", tv_muted())
        elif step == "rem17-done":
            note("rem17.end.muted", tv_muted())
        elif step.endswith("-before"):
            start_capture(step[:-7])
        elif step.endswith("-after"):
            note(f"{step[:-6]}.keys", ",".join(stop_capture(step[:-6])) or "none")
            note("foreground", foreground())
        go(step)
        if step == "done":
            note("end.muted", tv_muted())
            sys.exit(0)
    time.sleep(0.3)
print("driver timed out")
