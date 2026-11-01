#!/usr/bin/env python3
"""The TV side of the end-to-end suite (scripts/e2e.sh, ios/TVRemoteUITests/TVRemoteEndToEndTests.swift).

A small HTTP server on this Mac that the UI test, running in the iOS Simulator, calls to look at and poke the Android
TV emulator over adb: read the pairing code off its screen, accept the "Allow USB debugging?" prompt, see which app is
in front, press keys, read the launcher's config. Listens on 127.0.0.1 only and exists only while a test run does.

  scripts/e2e-helper.py serve [--port 17555] [--serial emulator-5554] [--forward 15555]
  scripts/e2e-helper.py console "avd snapshot load clean"      an emulator console command (works with adbd stopped)
  scripts/e2e-helper.py approve [--timeout 120]                accept the next "Allow USB debugging?" prompt, then exit
  scripts/e2e-helper.py forward                                adbd in TCP mode and the port forwards (15555, 6466, 6467, 9764)

Every endpoint answers JSON: {"ok": true, ...} or {"ok": false, "error": "..."}.
"""
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ANDROID_HOME = os.environ.get("ANDROID_HOME", os.path.expanduser("~/Library/Android/sdk"))
ADB = os.environ.get("ADB", os.path.join(ANDROID_HOME, "platform-tools", "adb"))
SERIAL = "emulator-5554"
CONSOLE_PORT = 5554
# Mac port -> emulator port. adb forward for all of them: the emulator's own port redirection doesn't reach the
# remote service or the launcher (docs/emulator.md), and the ADB one needs `adb tcpip 5555` first.
FORWARDS = {15555: 5555, 6466: 6466, 6467: 6467, 9764: 9764}

PACKAGE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
KEYCODE_RE = re.compile(r"^[A-Z0-9_]{1,40}$")


class AdbError(Exception):
    pass


def adb(*args, timeout=30):
    """Runs adb against the emulator and returns stdout. Raises AdbError when adb can't reach it."""
    try:
        done = subprocess.run([ADB, "-s", SERIAL, *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise AdbError("adb %s timed out after %ss" % (args[0], timeout))
    if done.returncode != 0:
        raise AdbError((done.stderr or done.stdout).strip() or "adb %s failed" % args[0])
    return done.stdout


def shell(command, timeout=30):
    return adb("shell", command, timeout=timeout).replace("\r\n", "\n")


def ui_nodes():
    """Every node of the TV's current view hierarchy, as dicts of its attributes."""
    xml = shell("uiautomator dump /sdcard/e2e-ui.xml >/dev/null 2>&1; cat /sdcard/e2e-ui.xml", timeout=40)
    start = xml.find("<?xml")
    if start < 0:
        start = xml.find("<hierarchy")
    if start < 0:
        return []
    try:
        root = ET.fromstring(xml[start:])
    except ET.ParseError:
        return []
    return [node.attrib for node in root.iter("node")]


def bounds_center(bounds):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds or "")
    if not m:
        return None
    x1, y1, x2, y2 = (int(v) for v in m.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


def tap(node):
    center = bounds_center(node.get("bounds"))
    if not center:
        raise AdbError("node without bounds: %s" % node.get("text"))
    shell("input tap %d %d" % center)


def focus():
    """The window in front (package, activity) and the resumed activity, from dumpsys."""
    out = shell("dumpsys window 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp'; dumpsys activity activities 2>/dev/null | grep -m1 -E 'ResumedActivity'")
    result = {"window": "", "resumed": ""}
    m = re.search(r"mCurrentFocus=Window\{\S+ u0 ([A-Za-z0-9_./$]+)", out)
    if m:
        result["window"] = m.group(1)
    m = re.search(r"ResumedActivity[^\n]*? u0 ([A-Za-z0-9_./$]+)", out)
    if m:
        result["resumed"] = m.group(1)
    result["package"] = (result["window"] or result["resumed"]).split("/")[0]
    return result


def deadline(seconds):
    return time.time() + float(seconds)


# ---- endpoints -----------------------------------------------------------------------------------------------------

def ep_ping(q):
    return {"serial": SERIAL, "adb": ADB}


def ep_pairing_code(q):
    """The 6-character code the Android TV Remote Service shows while pairing, read off the screen.
    `not=` an earlier code to ignore (a fresh pairing shows a new one)."""
    avoid = (q.get("not") or "").upper()
    until = deadline(q.get("timeout", 30))
    seen = []
    while True:
        for node in ui_nodes():
            for attr in ("text", "content-desc"):
                for code in re.findall(r"\b[0-9A-F]{6}\b", node.get(attr, "")):
                    seen.append(code)
                    if code != avoid:
                        return {"code": code, "package": node.get("package", "")}
        if time.time() > until:
            raise AdbError("no pairing code on the TV's screen (saw %s)" % (seen or "nothing"))
        time.sleep(1)


def ep_approve_debugging(q):
    """Accepts "Allow USB debugging?" with "Always allow from this computer" ticked."""
    until = deadline(q.get("timeout", 60))
    while True:
        nodes = ui_nodes()
        if any("Allow USB debugging" in n.get("text", "") for n in nodes):
            always = next((n for n in nodes if n.get("resource-id", "").endswith("alwaysUse")), None)
            if always is not None and always.get("checked") != "true":
                tap(always)
                time.sleep(0.5)
            allow = next((n for n in nodes if n.get("resource-id", "").endswith("button1")), None)
            if allow is None:
                raise AdbError("the debugging prompt has no Allow button")
            tap(allow)
            time.sleep(1)
            return {"approved": True, "always": always is not None}
        if time.time() > until:
            raise AdbError("the TV never showed 'Allow USB debugging?'")
        time.sleep(1)


APPROVER = {"until": 0.0, "count": 0, "thread": None}


def approver_loop():
    """Accepts every debugging prompt until the deadline. The emulator image can't persist "Always allow"
    (AdbDebuggingManager: EACCES on /data/misc/adb/adb_keys), so it prompts for each new connection."""
    import threading
    while time.time() < APPROVER["until"]:
        try:
            nodes = ui_nodes()
            if any("Allow USB debugging" in n.get("text", "") for n in nodes):
                always = next((n for n in nodes if n.get("resource-id", "").endswith("alwaysUse")), None)
                if always is not None and always.get("checked") != "true":
                    tap(always)
                    time.sleep(0.5)
                allow = next((n for n in nodes if n.get("resource-id", "").endswith("button1")), None)
                if allow is not None:
                    tap(allow)
                    APPROVER["count"] += 1
                    time.sleep(1.5)
                    continue
        except AdbError:
            pass
        time.sleep(1)
    APPROVER["thread"] = None


def ep_auto_approve(q):
    """Approves any debugging prompt for the next `seconds`, in the background; /approvals says how many came."""
    import threading
    APPROVER["until"] = time.time() + float(q.get("seconds", 120))
    if q.get("reset") == "1":
        APPROVER["count"] = 0
    if APPROVER["thread"] is None:
        APPROVER["thread"] = threading.Thread(target=approver_loop, daemon=True)
        APPROVER["thread"].start()
    return {"count": APPROVER["count"]}


def ep_approvals(q):
    return {"count": APPROVER["count"], "active": APPROVER["thread"] is not None}


def ep_debugging_prompt(q):
    """Whether the debugging prompt is on screen right now (it must not be, after an approved key reconnects)."""
    return {"shown": any("Allow USB debugging" in n.get("text", "") for n in ui_nodes())}


def ep_focus(q):
    return focus()


def ep_wait_foreground(q):
    package = q.get("package", "")
    if not PACKAGE_RE.match(package):
        raise AdbError("bad package")
    until = deadline(q.get("timeout", 20))
    last = {}
    while True:
        last = focus()
        if last["package"] == package:
            return last
        if time.time() > until:
            raise AdbError("%s never came to the front; in front: %s" % (package, last))
        time.sleep(0.5)


def ep_key(q):
    code = q.get("code", "")
    if not KEYCODE_RE.match(code):
        raise AdbError("bad keycode")
    shell("input keyevent " + code)
    return {}


def ep_start(q):
    package = q.get("package", "")
    if not PACKAGE_RE.match(package):
        raise AdbError("bad package")
    out = shell("monkey -p %s -c android.intent.category.LEANBACK_LAUNCHER 1 2>&1 | tail -n 2" % package)
    return {"output": out.strip()}


def ep_home(q):
    out = shell("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -n 1")
    return {"home": out.strip()}


def packages(flag):
    out = shell("pm list packages %s --user 0" % flag)
    return sorted(line[8:].strip() for line in out.splitlines() if line.startswith("package:"))


def ep_disabled(q):
    return {"packages": packages("-d")}


def ep_installed(q):
    return {"packages": packages("")}


def ep_prop(q):
    name = q.get("name", "")
    if not re.match(r"^[A-Za-z0-9_.]{1,80}$", name):
        raise AdbError("bad property")
    return {"value": shell("getprop " + name).strip()}


def ep_setting(q):
    namespace, key = q.get("namespace", "global"), q.get("key", "")
    if namespace not in ("global", "secure", "system") or not re.match(r"^[A-Za-z0-9_.]{1,80}$", key):
        raise AdbError("bad setting")
    return {"value": shell("settings get %s %s" % (namespace, key)).strip()}


def ep_launcher_config(q):
    out = shell("cat /sdcard/Android/data/com.gathin.tvhome/files/config.json 2>/dev/null")
    try:
        return {"config": json.loads(out) if out.strip() else None}
    except json.JSONDecodeError:
        raise AdbError("config.json is not JSON: %r" % out[:200])


def ep_logcat(q):
    pattern = q.get("grep", "")
    lines = int(q.get("lines", 400))
    out = adb("logcat", "-d", "-t", str(lines), timeout=40)
    if pattern:
        out = "\n".join(line for line in out.splitlines() if re.search(pattern, line))
    return {"lines": out.splitlines()[-200:]}


def forward_all():
    """Adds the forwards and checks they hold: a forward added while adbd is restarting dies with the transport."""
    for attempt in range(10):
        for mac, tv in FORWARDS.items():
            adb("forward", "tcp:%d" % mac, "tcp:%d" % tv)
        time.sleep(2)
        listed = adb("forward", "--list")
        if all(("tcp:%d tcp:%d" % (mac, tv)) in listed for mac, tv in FORWARDS.items()):
            return listed.strip().splitlines()
        adb("wait-for-device", timeout=60)
    raise AdbError("the forwards keep disappearing: is the emulator's adbd restarting?")


def tcp_mode():
    """Puts the emulator's adbd in TCP mode (a second entrance next to the emulator's own port), waiting for the
    restarted adbd. Already in TCP mode: nothing to do."""
    def adbd():
        try:
            return shell("pidof adbd", timeout=8).strip()
        except AdbError:
            return ""
    if shell("getprop service.adb.tcp.port").strip() == "5555" and adbd():
        return
    before = adbd()
    adb("tcpip", "5555")
    for _ in range(40):
        time.sleep(1)
        now = adbd()
        if now and now != before:
            break
    adb("wait-for-device", timeout=60)


def ep_drop_adb(q):
    """Drops every connection the simulator has to the emulator (the TV link 'went idle'): adb reconnects its
    transport, which closes the forwarded sockets, then the forwards are put back."""
    adb("reconnect")
    adb("wait-for-device", timeout=60)
    time.sleep(1)
    return {"forwards": forward_all()}


def ep_adb(q):
    """Whether the TV still answers adb, and what its adb_enabled setting says (both change when debugging goes off)."""
    try:
        enabled = shell("settings get global adb_enabled", timeout=8).strip()
        return {"alive": True, "adb_enabled": enabled}
    except AdbError as e:
        return {"alive": False, "adb_enabled": None, "error": str(e)}


def ep_shell(q):
    return {"output": shell(q.get("cmd", "true"), timeout=int(q.get("timeout", 60)))}


ENDPOINTS = {name[3:].replace("_", "-"): fn for name, fn in globals().items() if name.startswith("ep_")}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        fn = ENDPOINTS.get(url.path.strip("/"))
        if fn is None:
            self.reply(404, {"ok": False, "error": "unknown endpoint", "endpoints": sorted(ENDPOINTS)})
            return
        try:
            result = fn(q)
            result["ok"] = True
            self.reply(200, result)
        except AdbError as e:
            self.reply(200, {"ok": False, "error": str(e)})
        except Exception as e:  # a bug in this helper: say so instead of hanging the test
            self.reply(500, {"ok": False, "error": "%s: %s" % (type(e).__name__, e)})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s helper %s\n" % (time.strftime("%H:%M:%S"), fmt % args))


def console(command, port=CONSOLE_PORT):
    """Sends one command to the emulator console (telnet 127.0.0.1:5554) and returns its reply."""
    import socket
    token_file = os.path.expanduser("~/.emulator_console_auth_token")
    token = open(token_file).read().strip() if os.path.exists(token_file) else ""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as s:
        s.settimeout(60)
        def read():
            data = b""
            while not (data.endswith(b"OK\r\n") or b"KO:" in data):
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            return data.decode(errors="replace")
        read()
        if token:
            s.sendall(("auth %s\n" % token).encode())
            read()
        s.sendall((command + "\n").encode())
        return read()


def main():
    global SERIAL, CONSOLE_PORT
    args = sys.argv[1:]
    if not args or args[0] not in ("serve", "console", "approve", "forward"):
        print(__doc__)
        sys.exit(2)
    if "--serial" in args:
        SERIAL = args[args.index("--serial") + 1]
        if SERIAL.startswith("emulator-"):
            CONSOLE_PORT = int(SERIAL.split("-")[1])
    if args[0] == "forward":
        try:
            tcp_mode()
            print("\n".join(forward_all()))
        except AdbError as e:
            print("forwarding failed: %s" % e, file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    if args[0] == "approve":
        timeout = args[args.index("--timeout") + 1] if "--timeout" in args else "120"
        try:
            print(ep_approve_debugging({"timeout": timeout}))
        except AdbError as e:
            print("not approved: %s" % e)
            sys.exit(1)
        sys.exit(0)
    if args[0] == "console":
        port = CONSOLE_PORT
        if "--console-port" in args:
            port = int(args[args.index("--console-port") + 1])
        reply = console(args[-1], port)
        print(reply.strip())
        sys.exit(0 if "OK" in reply else 1)
    port = 17555
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    server = HTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write("helper listening on http://127.0.0.1:%d for %s\n" % (port, SERIAL))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
