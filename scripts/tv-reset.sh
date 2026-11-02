#!/usr/bin/env bash
# Puts a test TV back to stock after a setup run, so the next run starts clean (development only; users undo a
# setup in the app, Settings › Undo TV setup). Over network debugging, with the upstream tools in tv-launcher/tools:
#   - switches back on every disabled app, except the ones you name as disabled from the factory;
#   - makes the stock launcher Home again;
#   - uninstalls the new Home screen (com.gathin.tvhome) and clears its remote-button helper.
# It shows the plan and asks before changing anything, then checks the result.
#
#   TV_HOST=192.168.1.50 scripts/tv-reset.sh [--keep-disabled pkg[,pkg…]] [--stock <launcher package>] [--yes]
#
# --keep-disabled: apps that were already off before any setup (look at `pm list packages -d` on a fresh TV, or the
# app's recovery record: packages recorded "disabled"). Without it, every disabled app is switched back on.
# --stock: the stock launcher package, when it isn't one of the four known ones.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/tv-launcher/tools"
KNOWN_STOCK="com.google.android.apps.tv.launcherx com.google.android.tvlauncher com.google.android.leanbacklauncher com.mitv.tvhome"
KEEP=""; STOCK=""; YES=0

usage() { sed -n '9,13p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-disabled) KEEP="${2:-}"; shift 2 ;;
    --stock) STOCK="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "tv-reset.sh doesn't take $1. Nothing was sent to the TV." >&2; usage >&2; exit 2 ;;
  esac
done
if [ -z "${TV_HOST:-}" ]; then echo "Set TV_HOST to the TV's address. Nothing was sent to the TV." >&2; usage >&2; exit 2; fi
valid() { [[ "$1" =~ ^[A-Za-z0-9_.]+$ ]]; }
for p in ${KEEP//,/ } $STOCK; do valid "$p" || { echo "Not a package name: $p. Nothing was sent to the TV." >&2; exit 2; }; done

PY="$TOOLS/venv/bin/python"
if [ ! -x "$PY" ]; then
  echo "Setting up the TV tools (once)…"
  python3 -m venv "$TOOLS/venv"
  "$TOOLS/venv/bin/pip" install -q -r "$TOOLS/requirements.txt"
fi
tv() { TV_HOST="$TV_HOST" "$PY" -I "$TOOLS/tv.py" "$1" | tr -d '\r'; }
home_now() { tv "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME | tail -n 1"; }
disabled_now() { tv "pm list packages -d" | sed -n 's/^package://p' | sort; }
tvhome_count() { tv "pm list packages com.gathin.tvhome" | grep -c "package:com.gathin.tvhome$" || true; }

echo "Reading $TV_HOST…"
INSTALLED="$(tv "pm list packages" | sed -n 's/^package://p')"
[ -n "$INSTALLED" ] || { echo "The TV listed no apps. Is network debugging on and this computer allowed? Nothing was changed." >&2; exit 1; }
if [ -z "$STOCK" ]; then
  for p in $KNOWN_STOCK; do if printf '%s\n' "$INSTALLED" | grep -qx "$p"; then STOCK="$p"; break; fi; done
fi
[ -n "$STOCK" ] || { echo "No known stock launcher on this TV: pass --stock <package>. Nothing was changed." >&2; exit 1; }
DISABLED="$(disabled_now)"
KEEP_LIST="$(printf '%s\n' ${KEEP//,/ } | sort)"
ENABLE="$(comm -23 <(printf '%s\n' "$DISABLED" | sed '/^$/d') <(printf '%s\n' "$KEEP_LIST" | sed '/^$/d'))"
HAS_TVHOME="$(tvhome_count)"

echo
echo "Home now:        $(home_now)"
echo "Stock launcher:  $STOCK"
echo "Switch back on:  $(printf '%s\n' "$ENABLE" | sed '/^$/d' | wc -l | tr -d ' ') apps"
printf '%s\n' "$ENABLE" | sed '/^$/d; s/^/  /'
echo "Leave off:       ${KEEP:-(none)}"
echo "Uninstall the new Home screen: $([ "$HAS_TVHOME" -gt 0 ] && echo yes || echo "no (not installed)")"
if [ -z "$KEEP" ] && [ -n "$ENABLE" ]; then
  echo "Note: no --keep-disabled given, so apps that were off from the factory are switched on too."
fi
if [ "$YES" != 1 ]; then
  read -r -p "Reset the TV like this? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Nothing was changed."; exit 0; }
fi

CMD=""
while IFS= read -r p; do [ -n "$p" ] && CMD+="pm enable $p >/dev/null; "; done <<< "$ENABLE"
CMD+="pm enable $STOCK >/dev/null; "
CMD+="cmd package set-home-activity --user 0 \$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME $STOCK | tail -n 1); "
[ "$HAS_TVHOME" -gt 0 ] && CMD+="pm uninstall com.gathin.tvhome; "
CMD+='case "$(settings get secure enabled_accessibility_services)" in *gathin*) settings put secure enabled_accessibility_services ""; settings put secure accessibility_enabled 0;; esac; echo reset-done'
OUT="$(tv "$CMD")"
printf '%s\n' "$OUT" | grep -q '^reset-done$' || { echo "$OUT"; echo "The TV didn't finish the reset. Run this again; nothing is lost by repeating it." >&2; exit 1; }

echo
HOME_AFTER="$(home_now)"; DISABLED_AFTER="$(disabled_now)"; TVHOME_AFTER="$(tvhome_count)"
ok=1
case "$HOME_AFTER" in "$STOCK"/*) echo "✓ Home: $HOME_AFTER" ;; *) echo "✗ Home is $HOME_AFTER, not $STOCK"; ok=0 ;; esac
if [ "$DISABLED_AFTER" = "$(printf '%s\n' "$KEEP_LIST" | sed '/^$/d')" ]; then echo "✓ Off: ${KEEP:-nothing}"; else echo "✗ Still off:"; printf '%s\n' "$DISABLED_AFTER" | sed 's/^/  /'; ok=0; fi
if [ "$TVHOME_AFTER" = 0 ]; then echo "✓ New Home screen not installed"; else echo "✗ The new Home screen is still installed"; ok=0; fi
[ "$ok" = 1 ] || exit 1
echo "Done. Restart the TV, and keep network debugging on for the next setup run."
