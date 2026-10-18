#!/bin/bash

# Real-plugin compatibility test for Barback.
#
# Loads the actual BarWidget.qml with the actual installed plugins as
# residents, and checks the compatibility shim against what those plugins do.
# Nothing live is touched:
#
#   * scratch HOME              — no plugin can read a token or write state
#   * scratch plugins directory — copies, so nothing edits an installed plugin
#   * stub bin directory first on PATH — every helper binary a resident spawns
#     is replaced by a logger that exits 0, including the ones that live inside
#     the plugin's own bin/ folder
#   * network namespace (unshare -Urn) — no resident can reach an API, and the
#     run is skipped rather than faked if unshare is unavailable
#   * `bar.run` is recorded by the harness, never executed
#   * the shell config it writes to is the harness's own JS object
#
# Usage: tests/qml_compat_test.sh [--keep]

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/tests/tmp/compat"
LIVE_PLUGINS="$HOME/.config/omarchy/plugins"
SHELL_SRC="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
KEEP=0
[[ ${1:-} == --keep ]] && KEEP=1

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }
info() { printf '  --   %s\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "qml_compat_test: missing $1" >&2; exit 2; }
}
need qs
need jq
need rsync

if ! unshare -Urn true 2>/dev/null; then
  echo "qml_compat_test: unshare -Urn unavailable; refusing to run residents with live network access" >&2
  exit 2
fi

# Prove the namespace really is empty before trusting it with a plugin that
# would otherwise phone an API.
netns_ifaces=$(unshare -Urn ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')
if [[ $(tr -d ' ' <<<"$netns_ifaces") != "lo" ]]; then
  echo "qml_compat_test: network namespace is not isolated (interfaces: $netns_ifaces)" >&2
  exit 2
fi

# ----------------------------------------------------------------- scratch

rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"/{root,bin,out}
PLUGINS="$SCRATCH/home/.config/omarchy/plugins"
mkdir -p "$PLUGINS" "$SCRATCH/home/.cache" "$SCRATCH/home/.local/state"

# qs resolves `qs.Ui` / `qs.Commons` relative to the config root, so the
# harness needs the shell's own Ui and Commons beside it. Copied, never
# symlinked: `omarchy plugin validate` refuses a symlink anywhere in the repo.
cp -r "$SHELL_SRC/Ui" "$SCRATCH/root/Ui"
cp -r "$SHELL_SRC/Commons" "$SCRATCH/root/Commons"
cp "$ROOT/tests/qml/Harness.qml" "$SCRATCH/root/shell.qml"

# Barback itself, as installed — including the bundled CLI, because the picker's
# add action runs it. The stub loop below replaces it (and every other plugin's
# bin/) with a logger, so the add is proved by its argv and writes nothing.
mkdir -p "$PLUGINS/ninepointlabs.barback/bin"
cp "$ROOT/manifest.json" "$ROOT/BarWidget.qml" "$ROOT/Model.js" "$PLUGINS/ninepointlabs.barback/"
# The About page (AboutView.qml) and the LICENSE it shows.
cp "$ROOT/About.js" "$ROOT/AboutView.qml" "$ROOT/LICENSE" "$PLUGINS/ninepointlabs.barback/"
cp "$ROOT/bin/barback" "$PLUGINS/ninepointlabs.barback/bin/barback"

# Residents under test. The brief asks for at least one plugin that reads
# bar.shell.serviceFor (spotify, upcoming — the null-fallback path) and one
# that does not (theme-rotate, ring-cameras).
RESIDENT_DIRS=(ninepointlabs.spotify ninepointlabs.upcoming tim.theme-rotate ring-cameras com.omastorm.radar)

for dir in "${RESIDENT_DIRS[@]}"; do
  [[ -d "$LIVE_PLUGINS/$dir" ]] || { info "skipped $dir (not installed)"; continue; }
  rsync -a \
    --exclude '.git' --exclude 'site' --exclude 'docs' --exclude 'golden' \
    --exclude 'target' --exclude 'tests' --exclude 'engine' --exclude '__pycache__' \
    "$LIVE_PLUGINS/$dir/" "$PLUGINS/$dir/"
done

# One hidden `omarchy plugin remove` backup, copied in so the dot-directory
# rule is proved against a real one rather than a fixture.
BACKUP_DIR=""
for candidate in "$LIVE_PLUGINS"/.*.bak.*; do
  [[ -d "$candidate" && -f "$candidate/manifest.json" ]] || continue
  BACKUP_DIR="$(basename "$candidate")"
  rsync -a --exclude '.git' "$candidate/" "$PLUGINS/$BACKUP_DIR/"
  break
done
BACKUP_ID=""
[[ -n $BACKUP_DIR ]] && BACKUP_ID="$(jq -r '.id // ""' "$PLUGINS/$BACKUP_DIR/manifest.json")"

# ------------------------------------------------------------------- stubs

CALLS="$SCRATCH/out/stub-calls.log"
: >"$CALLS"

make_stub() {
  local path="$1"
  cat >"$path" <<'STUB'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$BARBACK_STUB_LOG"
printf '{}\n'
exit 0
STUB
  chmod +x "$path"
}

# Helper binaries the residents call by name.
for binary in omarchy omarchy-shell omarchy-ring-cameras-ctl omarchy-theme-set \
              curl wget python3 systemctl notify-send wl-paste zenity spotify-bridge; do
  make_stub "$SCRATCH/bin/$binary"
done

# Helper binaries the residents call by path, from inside their own folder.
while IFS= read -r helper; do
  make_stub "$helper"
done < <(find "$PLUGINS" -path '*/bin/*' -type f -print)

# ------------------------------------------------------------------- run

ITEMS=$(jq -cn --arg backup "$BACKUP_ID" '
  [
    { id: "ninepointlabs.spotify", settings: {}, compact: true },
    { id: "ninepointlabs.upcoming", settings: {} },
    { id: "tim.theme-rotate", settings: {} },
    { id: "tim.ring-cameras", settings: {} },
    { id: "com.omastorm.radar", settings: { units: "imperial" } },
    { id: "ninepointlabs.definitely-not-installed", settings: {} }
  ]
  + (if $backup == "" then [] else [{ id: $backup, settings: {} }] end)
')

RESULT="$SCRATCH/out/result.json"
LOGFILE="$SCRATCH/out/quickshell.log"

echo "running the harness (network namespace, scratch HOME, stubbed helpers)…"
env -i \
  HOME="$SCRATCH/home" \
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
  XDG_CONFIG_HOME="$SCRATCH/home/.config" \
  XDG_CACHE_HOME="$SCRATCH/home/.cache" \
  XDG_STATE_HOME="$SCRATCH/home/.local/state" \
  WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
  HYPRLAND_INSTANCE_SIGNATURE="${HYPRLAND_INSTANCE_SIGNATURE:-}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}" \
  PATH="$SCRATCH/bin:/usr/bin:/bin" \
  QT_QPA_PLATFORM=wayland \
  BARBACK_STUB_LOG="$CALLS" \
  BARBACK_PLUGINS="$PLUGINS" \
  BARBACK_OUT="$RESULT" \
  BARBACK_ITEMS="$ITEMS" \
  BARBACK_SETTLE="${BARBACK_SETTLE:-6000}" \
  BARBACK_POSITION="${BARBACK_POSITION:-top}" \
  unshare -Urn \
  timeout 60 qs --no-color -p "$SCRATCH/root/shell.qml" >"$LOGFILE" 2>&1
rc=$?

if [[ ! -s $RESULT ]]; then
  echo "harness produced no result (qs exit $rc). Log tail:" >&2
  tail -30 "$LOGFILE" >&2
  exit 1
fi

# ----------------------------------------------------------------- asserts

echo
echo "harness"

jqr() { jq -r "$1" "$RESULT"; }

[[ $(jqr '.barback.loaded') == true ]] \
  && ok "Barback's real BarWidget.qml loaded under a PluginBarApi facade" \
  || bad "Barback's real BarWidget.qml loaded" "$(tail -5 "$LOGFILE")"

[[ $(jqr '.barback.scanned') == true ]] \
  && ok "scanned the plugins directory from inside the widget" \
  || bad "scanned the plugins directory" "scan never completed"

# Dot-directory rule, proved against a real backup folder.
if [[ -n $BACKUP_ID ]]; then
  if [[ $(jq -r --arg id "$BACKUP_ID" '.barback.indexedIds | index($id) // "none"' "$RESULT") == "none" ]]; then
    ok "never indexed $BACKUP_DIR (hidden removal backup)"
  else
    bad "never indexed $BACKUP_DIR" "the backup was resolved as a plugin"
  fi
  if [[ $(jq -r --arg id "$BACKUP_ID" '.barback.itemIds | index($id) // "none"' "$RESULT") == "none" ]]; then
    ok "pruned $BACKUP_ID from the drawer instead of mounting the backup"
  else
    bad "pruned $BACKUP_ID" "it is still a resident"
  fi
else
  info "no hidden .bak plugin folder on this machine to test against"
fi

[[ $(jqr '.barback.itemIds | index("ninepointlabs.definitely-not-installed") // "none"') == "none" ]] \
  && ok "pruned a resident that is not installed" \
  || bad "pruned a resident that is not installed" "it survived the prune"

[[ $(jq '[.persisted[] | select(has("items"))] | length' "$RESULT") -gt 0 ]] \
  && ok "persisted the pruned membership list back through updateEntryInline" \
  || bad "persisted the pruned membership list" "no write reached the shell facade"

# The spec's State shape: {id, section, items:[{id, settings, compact?}]}.
if jq -e '
  (.persisted | last) as $e
  | ($e.items | type) == "array"
  and ($e.items | all(has("id") and has("settings")))
  and ($e.section == "right")
' "$RESULT" >/dev/null; then
  ok "the persisted entry matches the spec's State shape"
else
  bad "the persisted entry matches the spec's State shape" "$(jq -c '.persisted | last' "$RESULT")"
fi

echo
echo "the empty drawer and its picker"

# Tim overrode two design-spec rules: an empty drawer must be discoverable, and
# the chip must offer a real picker. See DEVIATIONS.md. Both are checked here
# against a second, resident-free instance of the real widget.
[[ $(jqr '.empty.loaded') == true ]] \
  && ok "a second, empty Barback loaded alongside the populated one" \
  || bad "an empty Barback loaded" "$(tail -5 "$LOGFILE")"

[[ $(jqr '.empty.itemCount') -eq 0 ]] \
  && ok "the empty instance really has no residents" \
  || bad "the empty instance has no residents" "items=$(jqr '.empty.itemCount')"

[[ $(jqr '.empty.visible') == true ]] \
  && ok "an empty drawer is visible (overrides the spec's draw-nothing rule)" \
  || bad "an empty drawer is visible" "it drew nothing at all"

if [[ $(jqr '.empty.implicitWidth') -gt 0 && $(jqr '.empty.implicitHeight') -gt 0 ]]; then
  ok "the empty chip has a real size ($(jqr '.empty.implicitWidth')x$(jqr '.empty.implicitHeight'))"
else
  bad "the empty chip has a real size" "0 in one axis — it would be unclickable"
fi

[[ -n $(jqr '.empty.chipText') ]] \
  && ok "the empty chip draws the Barback glyph, with no count" \
  || bad "the empty chip draws a glyph" "chipText was empty"

grep -q "click to add a widget" <<<"$(jqr '.empty.tooltip' | tr 'A-Z' 'a-z')" \
  && ok "the empty chip's tooltip says what clicking it does" \
  || bad "the empty chip's tooltip is discoverable" "$(jqr '.empty.tooltip')"

[[ $(jqr '.empty.pickerOpened') == true ]] \
  && ok "clicking the empty chip opens a real picker" \
  || bad "clicking the empty chip opens a picker" "pickerOpen stayed false"

[[ $(jqr '.empty.pickerOpen') == false ]] \
  && ok "a successful pick closes the picker again" \
  || bad "a successful pick closes the picker" "it stayed open"

# The picker's eligibility rules, against the real installed plugins.
candidates=$(jq -r '.empty.candidateIds | join(" ")' "$RESULT")
if [[ -n $candidates ]]; then
  ok "the picker offered real installed widgets: $candidates"
else
  bad "the picker offered real installed widgets" "the list was empty"
fi

for forbidden in ninepointlabs.barback; do
  [[ " $candidates " != *" $forbidden "* ]] \
    && ok "the picker never offers $forbidden (a drawer cannot hold another drawer)" \
    || bad "the picker never offers $forbidden" "$candidates"
done

if [[ -n $BACKUP_ID ]]; then
  [[ " $candidates " != *" $BACKUP_ID "* ]] \
    && ok "the picker never offers $BACKUP_ID (hidden removal backup)" \
    || bad "the picker never offers $BACKUP_ID" "$candidates"
fi

[[ " $candidates " != *" omarchy."* ]] \
  && ok "the picker never offers a stock omarchy.* widget" \
  || bad "the picker never offers a stock widget" "$candidates"

# And the add action: one call to the bundled CLI, which is the shared writer's
# only entry point. The CLI here is a logging stub, so nothing was written.
add_calls=$(grep -c '^barback add ' "$CALLS")
if [[ $add_calls -eq 1 ]]; then
  ok "picking a widget ran the bundled CLI once: $(grep -m1 '^barback add ' "$CALLS")"
else
  bad "picking a widget ran the bundled CLI once" "$add_calls matching calls in $CALLS"
fi

added_id=$(grep -m1 '^barback add ' "$CALLS" | awk '{print $3}')
[[ -n $added_id && " $candidates " == *" $added_id "* ]] \
  && ok "the id it passed to the CLI is one the picker had offered" \
  || bad "the id passed to the CLI was offered" "added '$added_id', offered '$candidates'"

[[ -z $(jqr '.empty.addError') ]] \
  && ok "the add reported no error" \
  || bad "the add reported no error" "$(jqr '.empty.addError')"

echo
echo "the populated drawer"

[[ $(jq '[.facadeCalls[] | select(.call == "run")] | length' "$RESULT") -eq 0 ]] \
  && ok "no resident asked the bar to run a command" \
  || info "residents asked bar.run to run: $(jq -c '[.facadeCalls[]|select(.call=="run")|.detail]' "$RESULT")"

if [[ $(jqr '.vertical') == true ]]; then
  if jq -e '[.residents[] | select(.mounted) | .shimVertical] | length > 0 and all' "$RESULT" >/dev/null; then
    ok "vertical: true reached every mounted resident's shim"
  else
    bad "vertical: true reached every resident" "$(jq -c '[.residents[]|select(.mounted)|{id,shimVertical}]' "$RESULT")"
  fi
fi

echo
echo "residents"

resident_ids=$(jq -r '.residents[].id' "$RESULT")
for id in $resident_ids; do
  row=$(jq -c --arg id "$id" '.residents[] | select(.id == $id)' "$RESULT")
  mounted=$(jq -r '.mounted' <<<"$row")
  resolved=$(jq -r '.resolvedOk' <<<"$row")
  reason=$(jq -r '.reason' <<<"$row")

  if [[ $resolved != true ]]; then
    info "$id did not resolve ($reason)"
    continue
  fi

  if [[ $mounted == true ]]; then
    ok "$id mounted inside the drawer"
  else
    bad "$id mounted inside the drawer" "resolved but no live item"
    continue
  fi

  [[ $(jq -r '.shimIsPluginBarApi' <<<"$row") == true ]] \
    && ok "$id got a real PluginBarApi shim" \
    || bad "$id got a real PluginBarApi shim" "$row"

  [[ $(jq -r '.shimPluginId' <<<"$row") == "ninepointlabs.barback" ]] \
    && ok "$id's click/popout identity registers under Barback (accepted cost 2)" \
    || bad "$id's shim pluginId" "$(jq -r '.shimPluginId' <<<"$row")"

  [[ $(jq -r '.shimModuleName' <<<"$row") == "$id" && $(jq -r '.moduleNameInjected' <<<"$row") == "$id" ]] \
    && ok "$id keeps its own moduleName" \
    || bad "$id keeps its own moduleName" "$row"

  [[ $(jq -r '.moduleWidgetsCount' <<<"$row") -ge 1 ]] \
    && ok "$id's moduleWidgets($id) returns its live instance" \
    || bad "$id's moduleWidgets returns its live instance" "count=$(jq -r '.moduleWidgetsCount' <<<"$row")"

  if [[ $(jq -r '.usesServiceFor' <<<"$row") == true ]]; then
    if [[ $(jq -r '.serviceForReturnsNull' <<<"$row") == true ]]; then
      ok "$id: serviceFor returns null on purpose"
      case "$(jq -r '.hasLiveService' <<<"$row")" in
        true)  ok "$id fell back to its own local service" ;;
        false) bad "$id fell back to its own local service" "service is null" ;;
        *)     info "$id exposes no \`service\` property to check the fallback against" ;;
      esac
    else
      bad "$id: serviceFor returns null" "it returned something"
    fi
  fi

  size=$(jq -r 'if .implicitWidth > 0 or .implicitHeight > 0 then "yes" else "no" end' <<<"$row")
  [[ $size == yes ]] \
    && ok "$id painted a non-zero chip ($(jq -r '.implicitWidth' <<<"$row")x$(jq -r '.implicitHeight' <<<"$row"))" \
    || bad "$id painted a non-zero chip" "0x0 — it would be invisible in the drawer"

  errs=$(jq -r '.errors | join("; ")' <<<"$row")
  [[ -z $errs ]] || bad "$id raised no error while being inspected" "$errs"
done

echo
echo "runtime log"

for pattern in "TypeError" "ReferenceError" "is not a function" "Cannot read" "Unable to assign"; do
  hits=$(grep -c -- "$pattern" "$LOGFILE")
  if [[ $hits -eq 0 ]]; then
    ok "no \"$pattern\" in the shell log"
  else
    bad "no \"$pattern\" in the shell log" "$(grep -m3 -- "$pattern" "$LOGFILE")"
  fi
done

resident_warnings=$(grep -E 'WARN.*plugins/(ninepointlabs|tim|com|io)\.' "$LOGFILE" | sed 's/^/       /')
if [[ -n $resident_warnings ]]; then
  info "warnings raised by residents themselves (read these before blaming the shim):"
  printf '%s\n' "$resident_warnings"
fi

if [[ -s $CALLS ]]; then
  info "stubbed helper calls captured (none of these ran for real):"
  sort -u "$CALLS" | sed 's/^/       /'
else
  info "no resident spawned a helper binary during the run"
fi

echo
echo "$pass passed, $fail failed"
[[ $KEEP -eq 1 ]] && echo "scratch kept at $SCRATCH"
exit $((fail == 0 ? 0 : 1))
