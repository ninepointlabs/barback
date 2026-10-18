#!/bin/bash

# The About page, in the real BarWidget.qml under qs.
#
# Runs tests/qml/AboutHarness.qml against a scratch copy of Barback with no
# residents: scratch HOME and XDG dirs, no other plugins, and nothing on PATH
# but the system's. The harness never presses Email or Copy, so no mail app
# opens and the clipboard is left alone. Fails on a failed check or on any QML
# warning in the log.
#
# It needs a Wayland session, like tests/qml_compat_test.sh: Quickshell has no
# offscreen backend for the bar's windows. Nothing is mapped on screen unless
# BARBACK_SHOT=<file.png> is set, which opens the harness's own window (a
# standalone About page, nothing else) and saves its content to that file.
#
# Usage: tests/about_qml_test.sh [--keep]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/tests/tmp/about"
SHELL_SRC="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
SHOT="${BARBACK_SHOT:-}"
KEEP=0
[[ ${1:-} == --keep ]] && KEEP=1

command -v qs >/dev/null 2>&1 || { echo "about_qml_test: missing qs" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "about_qml_test: missing jq" >&2; exit 2; }

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"/{root,out}
PLUGINS="$SCRATCH/home/.config/omarchy/plugins"
mkdir -p "$PLUGINS/ninepointlabs.barback/bin" "$SCRATCH/home/.cache" "$SCRATCH/home/.local/state"

cp -r "$SHELL_SRC/Ui" "$SCRATCH/root/Ui"
cp -r "$SHELL_SRC/Commons" "$SCRATCH/root/Commons"
cp "$ROOT/tests/qml/AboutHarness.qml" "$SCRATCH/root/shell.qml"
cp "$ROOT/manifest.json" "$ROOT/BarWidget.qml" "$ROOT/Model.js" "$ROOT/About.js" "$ROOT/AboutView.qml" \
  "$ROOT/LICENSE" "$PLUGINS/ninepointlabs.barback/"
cp "$ROOT/bin/barback" "$PLUGINS/ninepointlabs.barback/bin/barback"

RESULT="$SCRATCH/out/result.json"
LOGFILE="$SCRATCH/out/quickshell.log"
[[ -n ${WAYLAND_DISPLAY:-} ]] || { echo "about_qml_test: needs a Wayland session" >&2; exit 2; }

env -i \
  HOME="$SCRATCH/home" \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
  XDG_CONFIG_HOME="$SCRATCH/home/.config" \
  XDG_CACHE_HOME="$SCRATCH/home/.cache" \
  XDG_STATE_HOME="$SCRATCH/home/.local/state" \
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
  HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-}" \
  PATH="/usr/bin:/bin" \
  QT_QPA_PLATFORM=wayland \
  BARBACK_PLUGINS="$PLUGINS" \
  BARBACK_OUT="$RESULT" \
  BARBACK_SHOT="$SHOT" \
  timeout 40 qs --no-color -p "$SCRATCH/root/shell.qml" >"$LOGFILE" 2>&1
rc=$?

if [[ ! -s $RESULT ]]; then
  echo "harness produced no result (qs exit $rc). Log tail:" >&2
  tail -30 "$LOGFILE" >&2
  exit 1
fi

pass=0
fail=0
while IFS=$'\t' read -r ok name detail; do
  if [[ $ok == true ]]; then
    printf '  ok   %s\n' "$name"; pass=$((pass + 1))
  else
    printf '  FAIL %s\n     %s\n' "$name" "$detail"; fail=$((fail + 1))
  fi
done < <(jq -r '.checks[] | [(.ok|tostring), .name, .detail] | @tsv' "$RESULT")

# Any QML warning at all: a binding loop, a missing property, a type error.
warnings=$(grep -E 'WARN|TypeError|ReferenceError|is not a function|Cannot read|Unable to assign|binding loop' "$LOGFILE")
if [[ -z $warnings ]]; then
  printf '  ok   %s\n' "no QML warnings in the log"; pass=$((pass + 1))
else
  printf '  FAIL %s\n' "no QML warnings in the log"; printf '%s\n' "$warnings" | sed 's/^/     /'; fail=$((fail + 1))
fi

if [[ -n $SHOT ]]; then
  if [[ $(jq -r '.shotSaved' "$RESULT") == true && -s $SHOT ]]; then
    printf '  --   saved the About window to %s\n' "$SHOT"
  else
    printf '  FAIL %s\n' "saved the About window to $SHOT"; fail=$((fail + 1))
  fi
fi

echo
echo "$pass passed, $fail failed"
if [[ $KEEP -eq 1 ]]; then echo "scratch kept at $SCRATCH"; else rm -rf "$SCRATCH"; fi
exit $((fail == 0 ? 0 : 1))
