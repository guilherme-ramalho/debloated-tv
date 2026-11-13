#!/usr/bin/env python3
"""Bring every TV list from cleanyourtv into the app as a community profile.

Usage: scripts/import-tv-lists.py [path to cleanyourtv checkout] [git ref]
Defaults: ../cleanyourtv and origin/main (run `git -C ../cleanyourtv fetch origin` first).

For each examples/<id>/ upstream it writes ios/Resources/Profiles/<id>/ with debloat.txt, tv.json and config.json
copied unchanged (MIT, credited in the app), plus a generated profile.json (format in Resources/Profiles/README.md):

- community: true. The app matches it by scoring, not by an exact `match` (DebloatProfile / ProfileMatcher).
- homeScreen: whether setup may offer the new Home screen. Only lists that ship a launcher config.json, never on
  Fire TV or a debloat-only list, not on CVTE boards (a com.cvte.* package, or the list calls itself CVTE; they need a
  Home procedure the app doesn't have, #741), and not where the tester had to build the launcher under another
  application ID (customBuild: the app carries one fixed build).
- stockLauncher: the vendor launcher the list names ("Stock launcher: x", STOCK_LAUNCHER=x, or its Undo line).
- launcher: the remote-key helpers, read from the install command the list's tester ran
  (`HOME_KEY_SERVICE=1 ... build-and-install.sh`, also when the command wraps across comment lines), never guessed
  from prose; keepStockLauncher when the tester installed with STOCK_LAUNCHER=none or the notes say to keep the stock
  launcher on. A theme setting that only works with a helper the command didn't turn on is reported, and settled by
  hand in scripts/tv-list-overrides.json (reviewed per list; the importer refuses to run while one is unsettled).
- names: the TV's device, product and model as the list identifies its own unit (first paragraph, tv.json's title,
  fingerprint lines), never from sentences that point to another list. ProfileMatcher claims "made for this model"
  only from these.
- warnings: sentences from the list's header that tell people to keep something or warn of a failure, shown on the
  review screen in place of an agent reading the notes.

Hand-written profiles (no "community": true, such as tcl-43c645) are never touched. Community folders whose list
is gone upstream are removed. Reads the repo through git, so the checkout's own branch doesn't matter.
"""
import json
import os
import re
import shutil
import subprocess
import sys

OVERRIDES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tv-list-overrides.json")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILES = os.path.join(ROOT, "ios", "Resources", "Profiles")
DOCK = ["com.netflix.ninja", "com.google.android.youtube.tv", "com.amazon.amazonvideo.livingroom",
        "com.disney.disneyplus", "com.wbd.stream", "com.spotify.tv.android", "com.crunchyroll.crunchyroid"]
PKG_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,80}$")
WARN_RE = re.compile(
    r"\b(do not|don't|never|left out|leave [^.]{0,60}\b(on|enabled|alone)\b|keep [^.]{0,60}\b(on|enabled)\b|"
    r"boot ?loop|factory reset|black screen|no signal|hung (on|at)|stuck (on|at)|bricked|would not|wouldn't|broke (the|its)|"
    r"re-?enabled? (itself|themselves|at boot)|full reboot)", re.I)


COMMAND_RE = re.compile(r"TV_HOST|tools/|\.sh\b|\.py\b|examples/|docs/|\b(pm|cmd|settings|adb|am) (enable|disable|install|put|get|shell|start|package)\b|^(Apply|Undo|Restore)\b|=1\b|`", re.I)
KEEP_STOCK_RE = re.compile(r"(keep|leave)[^.#\n]{0,50}(launcher|patchwall|tvhome|launcherx|stock home)[^.#\n]{0,30}\b(on|enabled|alone)\b", re.I)
# Theme keys and the helper each needs (themes/README.md upstream).
NEEDS_HOME = ["settings_key_keycodes", "stock_home_redirect", "power_on_home", "power_on_home_always", "home_long_press_home"]
NEEDS_INPUT = ["input_key_keycodes"]
TOKEN = r"[A-Za-z0-9][A-Za-z0-9_.\-]{1,40}"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True).stdout


def header_lines(text):
    """Comment lines before the first package line, '#' stripped."""
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if not line.startswith("#"):
            break
        out.append(line.lstrip("#").strip())
    return out


def warnings(header):
    text = " ".join(header)
    sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z(])", text)
    found = []
    for s in sentences:
        s = s.strip()
        if COMMAND_RE.search(s):
            continue   # commands and repo paths mean nothing to someone using the app
        if WARN_RE.search(s) and 20 <= len(s) <= 400 and s not in found:
            found.append(s)
    return found[:6]


def commands(text):
    """Install commands with their wrapped continuation: comment lines joined into one string per paragraph, cut at
    each build-and-install, keeping the 160 characters before it (where the flags go) and the 80 after."""
    joined = re.sub(r"\s*\n\s*#?\s*", " ", text)
    return [joined[max(0, m.start() - 160): m.end() + 80] for m in re.finditer(r"build-and-install|Install-Launcher", joined)]


def install_flags(texts):
    """Key helper switches from the list's own install commands only."""
    flags = {"homeKeyService": False, "inputKeyService": False, "restoreKeyServices": False}
    for text in texts:
        for line in commands(text):
            flags["homeKeyService"] |= "HOME_KEY_SERVICE=1" in line or "-HomeKeyService" in line
            flags["inputKeyService"] |= "INPUT_KEY_SERVICE=1" in line or "-InputKeyService" in line
            flags["restoreKeyServices"] |= "RESTORE_KEY_SERVICES=1" in line or "-RestoreKeyServices" in line
    return flags


def stock_launcher(header, texts):
    m = re.search(r"Stock launcher:?\s*([A-Za-z_][\w]*(?:\.[\w]+)+)", " ".join(header))
    if m:
        return m.group(1)
    for text in texts:   # STOCK_LAUNCHER=<package> on an install line, else the package the Undo line hands back
        for pattern in (r"STOCK_LAUNCHER=([A-Za-z_]\w*(?:\.\w+)+)", r"restore\.(?:sh|ps1)\s+\S*debloat\.txt\s+([A-Za-z_]\w*(?:\.\w+)+)"):
            m = re.search(pattern, text)
            if m:
                return m.group(1)
    return None


def keeps_stock(texts, stock):
    """STOCK_LAUNCHER=none, "keep/leave the launcher on", or "do not disable <its stock launcher>"."""
    forbid = stock and re.compile(r"(do not|don't|never)[^.\n]{0,30}disabl\w*[^.\n]{0,10}\b" + re.escape(stock.split(".")[-1]), re.I)
    return any("STOCK_LAUNCHER=none" in t or KEEP_STOCK_RE.search(t) or (forbid and forbid.search(t)) for t in texts)


def calls_itself_cvte(text):
    """"CVTE board", but not "not CVTE" / "not the CVTE boards of …" (sharp-4t-c43dl1)."""
    return any(not re.search(r"\bnot\b", text[max(0, m.start() - 15):m.start()], re.I) for m in re.finditer(r"\bCVTE\b", text))


def needed_helpers(theme):
    """Which helper flags the theme's own settings rely on."""
    on = lambda k: bool(theme.get(k)) and theme.get(k) not in ([], "", 0)
    return {"homeKeyService": any(on(k) for k in NEEDS_HOME), "inputKeyService": any(on(k) for k in NEEDS_INPUT),
            "restoreKeyServices": on("restore_key_services")}


def identity(header, title):
    """Device, product and model as the list identifies its own unit."""
    first = []
    for line in header:   # the first paragraph
        if not line:
            if first: break
            continue
        first.append(line)
    text = " ".join(first + [title])
    sentences = [x for x in re.split(r"(?<=[.;])\s+", text) if not re.search(r"examples/|docs/|same .{0,40} as\b|not (to|the|a|on)\b", x, re.I)]
    fingerprints = [l for l in header if re.search(r"fingerprint", l, re.I)]
    text = " ".join(sentences + fingerprints)
    out = {"device": [], "product": [], "model": []}
    def add(kind, value):
        value = value.strip("\"'.,;:()[]")
        if len(value) >= 2 and value.lower() not in ("android", "tv", "the", "and", "is", "unknown") and value not in out[kind]:
            out[kind].append(value)
    for m in re.finditer(r"fingerprint:?\s*([^/\s]+)/([^/\s]+)/([^/:\s]+):", text, re.I):
        add("product", m.group(2)); add("device", m.group(3))
    for kind, pattern in (("device", rf"\b(?:device|codename|ro\.product\.device)\s*[:=]?\s*\[?\"?({TOKEN})"),
                          ("product", rf"\b(?:product|ro\.product\.name)\s*[:=]?\s*\[?\"?({TOKEN})"),
                          ("model", rf"\b(?:model|ro\.product\.model)\s*[:=]?\s*\[?\"?({TOKEN})")):
        for m in re.finditer(pattern, text, re.I):
            # A model token needs letters and digits ("QS01", "P2897"), not words such as "as" or "4K".
            if kind != "model" or (len(m.group(1)) >= 4 and re.search(r"\d", m.group(1)) and re.search(r"[A-Za-z]", m.group(1))):
                add(kind, m.group(1))
    return {k: v for k, v in out.items() if v}


def main():
    repo = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "cleanyourtv"))
    ref = sys.argv[2] if len(sys.argv) > 2 else "origin/main"
    sha = git(repo, "rev-parse", "--short=8", ref).decode().strip()
    files = git(repo, "ls-tree", "-r", "--name-only", ref, "examples").decode().splitlines()
    folders = sorted({f.split("/")[1] for f in files if f.count("/") >= 2})

    with open(OVERRIDES) as fh:
        overrides = {k: v for k, v in json.load(fh).items() if not k.startswith("_")}
    unsettled = []
    existing = {}
    for name in os.listdir(PROFILES):
        path = os.path.join(PROFILES, name, "profile.json")
        if os.path.isfile(path):
            with open(path) as fh:
                manifest = json.load(fh)
                # Hand-written (tcl-43c645) and development-only lists (dev-community-*) are never touched.
                existing[name] = manifest.get("community") is True and manifest.get("developmentOnly") is not True

    written, skipped, stats = [], [], {"home": 0, "fire": 0, "cvte": 0, "debloatOnly": 0, "customBuild": 0, "special": 0, "noConfig": 0}
    for fid in folders:
        if not ID_RE.match(fid):
            skipped.append(f"{fid}: unusual folder name"); continue
        if existing.get(fid) is False:
            skipped.append(f"{fid}: hand-written profile kept"); continue
        names = {f.split("/", 2)[2] for f in files if f.startswith(f"examples/{fid}/")}
        if "debloat.txt" not in names or "tv.json" not in names:
            skipped.append(f"{fid}: no debloat.txt or tv.json"); continue
        read = lambda n: git(repo, "show", f"{ref}:examples/{fid}/{n}")
        debloat, tv_raw = read("debloat.txt"), read("tv.json")
        tv = json.loads(tv_raw)
        config_raw = read("config.json") if "config.json" in names else None
        readme = read("README.md").decode("utf-8", "replace") if "README.md" in names else ""
        list_text = debloat.decode("utf-8", "replace")
        header = header_lines(list_text)

        brand, osname = tv.get("brand", ""), tv.get("os", "")
        blob = " ".join([list_text, tv.get("notes", ""), osname])
        fire = "amazon" in brand.lower() or "fire os" in osname.lower()
        cvte = (re.search(r"\bcom\.cvte\.[a-z]", list_text) is not None
                or calls_itself_cvte(" ".join(header[:12] + [tv.get("tv", ""), tv.get("notes", "")])))
        custom_build = re.search(r"launcherApplicationId|APPLICATION_ID=", list_text + readme) is not None
        debloat_only = re.search(r"debloat only|launcher/ does not apply", blob, re.I) is not None
        if fire: reason = "fireOS"
        elif debloat_only: reason = "debloatOnly"
        elif cvte: reason = "cvte"
        elif custom_build: reason = "customBuild"
        elif config_raw is None: reason = "noConfig"
        else: reason = None

        theme = {}
        if config_raw is not None:
            try:
                theme = json.loads(config_raw)
            except ValueError:
                theme, reason = {}, reason or "noConfig"
        launcher = install_flags([list_text, readme])
        stock = stock_launcher(header, [list_text, readme])
        if keeps_stock([list_text, readme], stock):
            launcher["keepStockLauncher"] = True
        override = overrides.get(fid, {})
        if "homeScreenNote" in override:   # a Home procedure the app doesn't have (read in the list)
            reason = override["homeScreenNote"]
        launcher.update(override.get("launcher", {}))
        stats["fire" if reason == "fireOS" else reason or "home"] += 1
        if reason is None:
            missing = [k for k, v in needed_helpers(theme).items() if v and not launcher.get(k)]
            if missing and "launcher" not in override:
                unsettled.append(f"{fid}: its theme needs {', '.join(missing)} but the install command doesn't turn it on")
        # The tester's dock comes first among the dock suggestions; the app fills the dock from what the user keeps.
        tested_dock = [p for p in theme.pop("dock_apps", []) if isinstance(p, str) and PKG_RE.match(p)]

        profile = {
            "id": fid,
            "name": tv.get("tv", fid),
            "source": f"cleanyourtv examples/{fid} at {sha}",
            "community": True,
            "brand": brand,
            "os": osname,
            "match": {},
            "names": identity(header, tv.get("tv", "")),
            "stockLauncher": stock,
            "launcher": launcher,
            "homeScreen": reason is None,
            "homeScreenNote": reason,
            "dockCandidates": list(dict.fromkeys(tested_dock + DOCK)),
            "warnings": warnings(header),
            "theme": theme,
        }
        if profile["stockLauncher"] is None:
            del profile["stockLauncher"]

        out = os.path.join(PROFILES, fid)
        if os.path.isdir(out):
            shutil.rmtree(out)
        os.makedirs(out)
        with open(os.path.join(out, "debloat.txt"), "wb") as fh: fh.write(debloat)
        with open(os.path.join(out, "tv.json"), "wb") as fh: fh.write(tv_raw)
        if config_raw is not None:
            with open(os.path.join(out, "config.json"), "wb") as fh: fh.write(config_raw)
        with open(os.path.join(out, "profile.json"), "w") as fh:
            json.dump(profile, fh, indent=2, ensure_ascii=False); fh.write("\n")
        written.append(fid)

    removed = [n for n, community in existing.items() if community and n not in written]
    for name in removed:
        shutil.rmtree(os.path.join(PROFILES, name))

    print(f"cleanyourtv {ref} at {sha}: {len(written)} community profiles written, {len(removed)} removed")
    print(f"  new Home screen offered: {stats['home']}; debloat only: Fire TV {stats['fire']}, "
          f"CVTE {stats['cvte']}, list says debloat only {stats['debloatOnly']}, custom launcher build {stats['customBuild']}, "
          f"special Home procedure {stats['special']}, "
          f"no launcher config {stats['noConfig']}")
    for line in skipped:
        print("  skipped " + line)
    if unsettled:
        print("Settle these in scripts/tv-list-overrides.json (read the list, set its launcher flags):", file=sys.stderr)
        for line in unsettled:
            print("  " + line, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
