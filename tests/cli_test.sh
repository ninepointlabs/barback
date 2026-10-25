#!/bin/bash

# CLI tests for bin/barback.
#
# Isolated from the live shell in two ways, both of which matter:
#
#   * scratch HOME — omarchy-shell-config computes CONFIG_FILE from $HOME at
#     the moment it is sourced, so the real helper writes to a scratch
#     shell.json and the live one is never opened. The helper itself is the
#     real /usr/bin/omarchy-shell-config; nothing about the writer is faked.
#   * mock reload — the helper's last step is `omarchy-shell shell
#     reloadConfig`. A stub earlier on PATH records the call instead of
#     reaching the running shell, and the tests assert it was made.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/tests/tmp/cli"
BARBACK="$ROOT/bin/barback"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

command -v jq >/dev/null 2>&1 || { echo "cli_test: jq is required" >&2; exit 2; }
command -v omarchy-shell-config >/dev/null 2>&1 \
  || { echo "cli_test: omarchy-shell-config not on PATH" >&2; exit 2; }

# ----------------------------------------------------------------- fixtures

LIVE_CONFIG="$HOME/.config/omarchy/shell.json"
LIVE_MTIME_BEFORE=""
[[ -f $LIVE_CONFIG ]] && LIVE_MTIME_BEFORE=$(stat -c %Y "$LIVE_CONFIG")

rm -rf "$SCRATCH"
PLUGINS="$SCRATCH/home/.config/omarchy/plugins"
CONFIG="$SCRATCH/home/.config/omarchy/shell.json"
RELOADS="$SCRATCH/reloads.log"
mkdir -p "$PLUGINS" "$SCRATCH/bin"
: >"$RELOADS"

cat >"$SCRATCH/bin/omarchy-shell" <<'STUB'
#!/bin/bash
printf 'omarchy-shell %s\n' "$*" >>"$BARBACK_RELOAD_LOG"
exit 0
STUB
chmod +x "$SCRATCH/bin/omarchy-shell"

# plugin <dir> <id> <kinds> <entry> [defaults] [extra-manifest-json] [noentry]
#
#   extra-manifest-json  merged into the manifest (recursively), for the keys
#                        that decide eligibility rather than settings
#   noentry              declare the entry point but do not create the file,
#                        which is a real state: a half-deleted plugin
plugin() {
  local dir="$1" id="$2" kinds="$3" entry="$4" defaults="${5:-{\}}" extra="${6:-{\}}" noentry="${7:-}"
  mkdir -p "$PLUGINS/$dir"
  jq -n --arg id "$id" --argjson kinds "$kinds" --arg entry "$entry" \
        --argjson defaults "$defaults" --argjson extra "$extra" '
    { schemaVersion: 1, id: $id, name: $id, version: "1.0.0", kinds: $kinds,
      entryPoints: (if $entry == "" then {} else { barWidget: $entry } end),
      barWidget: { displayName: $id, defaults: $defaults } } * $extra' >"$PLUGINS/$dir/manifest.json"
  [[ -n $entry && -z $noentry ]] && { mkdir -p "$(dirname "$PLUGINS/$dir/$entry")"; : >"$PLUGINS/$dir/$entry"; }
  return 0
}

plugin ninepointlabs.barback   ninepointlabs.barback   '["bar-widget"]' BarWidget.qml '{}' \
  '{"barWidget":{"hostsBarWidgets":true}}'
plugin example.alpha           example.alpha           '["bar-widget"]' BarWidget.qml '{"showTrack":true,"maxLabelWidth":180}'
plugin beta-folder             example.beta            '["bar-widget"]' ui/Bar.qml
plugin example.serviceonly     example.serviceonly     '["service"]'    ''
# Never on the bar, so parking it has no settings to carry across.
plugin example.offbar          example.offbar          '["bar-widget"]' BarWidget.qml '{"mode":"quiet"}'
# Another drawer, and a clone of this one: nested drawers are out of scope.
plugin example.shelf           example.shelf           '["bar-widget"]' BarWidget.qml '{}' \
  '{"barWidget":{"hostsBarWidgets":true}}'
plugin example.clone           example.clone           '["bar-widget"]' BarWidget.qml '{}' \
  '{"omarchy":{"clonedFrom":"ninepointlabs.barback"}}'
# A manifest that promises a QML file that is not there.
plugin example.noqml           example.noqml           '["bar-widget"]' BarWidget.qml '{}' '{}' noentry
# Turned off by the user, recorded in disabledPlugins[].
plugin example.off             example.off             '["bar-widget"]' BarWidget.qml
# A hidden `omarchy plugin remove` backup: never a candidate, never resolvable.
plugin .example.gone.bak.20260909154215 example.gone   '["bar-widget"]' BarWidget.qml

cat >"$CONFIG" <<'JSON'
{
  "version": 1,
  "bar": {
    "layout": {
      "left": [{ "id": "omarchy.menu" }],
      "center": [{ "id": "example.beta", "units": "metric" }],
      "right": [
        { "id": "omarchy.tray" },
        { "id": "ninepointlabs.barback" },
        { "id": "example.alpha", "showTrack": false }
      ]
    },
    "position": "top"
  },
  "disabledPlugins": ["example.off"],
  "plugins": []
}
JSON

run() {
  env HOME="$SCRATCH/home" \
      OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}" \
      BARBACK_RELOAD_LOG="$RELOADS" \
      PATH="$SCRATCH/bin:$PATH" \
      bash "$BARBACK" "$@"
}

cfg() { jq -c "$1" "$CONFIG"; }

echo
echo "list and probe on an empty drawer"

out="$(run list)"
# The empty drawer is a small discoverable chip now, not nothing at all, and
# `list` is where someone checks what it is doing. See DEVIATIONS.md.
if grep -q "drawer is empty" <<<"$out" && grep -q "click it to add a widget" <<<"$out"; then
  ok "list reports an empty drawer and points at the chip that fills it"
else
  bad "list reports an empty drawer" "$out"
fi
grep -q "takes no space" <<<"$out" \
  && bad "list no longer claims an empty drawer is invisible" "$out" \
  || ok "list no longer claims an empty drawer takes no bar space"

run probe >/dev/null 2>&1 \
  && ok "probe passes with no residents" \
  || bad "probe passes with no residents" "exit $?"

echo
echo "add"

out="$(run add example.alpha --compact 2>&1)"
grep -q "parked example.alpha" <<<"$out" \
  && ok "add parks a resident" || bad "add parks a resident" "$out"

grep -q "kept the settings it had on the bar" <<<"$out" \
  && ok "add says it carried the widget's bar settings across" \
  || bad "add says it carried the settings across" "$out"

[[ $(cfg '[.bar.layout.left[],.bar.layout.center[],.bar.layout.right[] | .id] | index("example.alpha") // "none"') == '"none"' ]] \
  && ok "add deletes the resident's entry from every layout section" \
  || bad "add deletes the resident's layout entry" "$(cfg '.bar.layout')"

[[ $(cfg '[.bar.layout.right[] | select(.id == "ninepointlabs.barback")] | length') -eq 1 ]] \
  && ok "Barback's own entry is still there, exactly once" \
  || bad "Barback's own entry survives" "$(cfg '.bar.layout.right')"

# The spec's State section, verbatim:
#   { id, section, items: [ { id, settings, compact? } ] }
#
# example.alpha was on the bar with `showTrack: false` while its manifest
# defaults say `showTrack: true`. Moving a widget into the drawer must not
# silently reset it, so the defaults are the floor and the settings it actually
# had on the bar win.
if jq -e '
  (.bar.layout.right[] | select(.id == "ninepointlabs.barback")) as $e
  | ($e | keys_unsorted | sort) == ["id", "items", "section"]
  and $e.section == "right"
  and ($e.items | length) == 1
  and ($e.items[0] | keys_unsorted | sort) == ["compact", "id", "settings"]
  and $e.items[0].id == "example.alpha"
  and $e.items[0].compact == true
  and $e.items[0].settings == { showTrack: false, maxLabelWidth: 180 }
' "$CONFIG" >/dev/null; then
  ok "the entry is the spec's State shape, with the bar settings preserved over the manifest defaults"
else
  bad "the entry is exactly the spec's State shape" "$(cfg '.bar.layout.right[] | select(.id=="ninepointlabs.barback")')"
fi

grep -q "reloadConfig" "$RELOADS" \
  && ok "the write asked the shell to reload (mocked, never reached the live shell)" \
  || bad "the write asked the shell to reload" "$(cat "$RELOADS")"

out="$(run add example.alpha 2>&1)"
grep -q "already in the drawer" <<<"$out" \
  && ok "adding a resident twice is a no-op" || bad "adding twice is a no-op" "$out"

# Second resident: no compact flag, and its own layout entry gets dropped too.
run add example.beta >/dev/null 2>&1
if jq -e '
  (.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items as $i
  | ($i | length) == 2
  and ($i[1] | keys_unsorted | sort) == ["id", "settings"]
  and $i[1].id == "example.beta"
  and ($i | map(.id)) == ["example.alpha", "example.beta"]
' "$CONFIG" >/dev/null; then
  ok "a second resident appends in order, with no compact key when it is off"
else
  bad "a second resident appends in order" "$(cfg '(.bar.layout.right[]|select(.id=="ninepointlabs.barback")).items')"
fi

# example.beta has no manifest defaults at all, so the only settings it can
# arrive with are the ones it had in the center section.
[[ $(cfg '(.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items[1].settings') == '{"units":"metric"}' ]] \
  && ok "a widget moved in from the center keeps the settings it had there" \
  || bad "a widget moved in from the center keeps its settings" \
       "$(cfg '(.bar.layout.right[]|select(.id=="ninepointlabs.barback")).items[1]')"

[[ $(cfg '.bar.layout.center | length') -eq 0 ]] \
  && ok "parking a widget from the center section empties that slot" \
  || bad "parking clears the center entry" "$(cfg '.bar.layout.center')"

# A widget that was never on the bar has nothing to preserve: it gets its
# manifest defaults, which is what add has always done.
out="$(run add example.offbar 2>&1)"
if [[ $(cfg '(.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items[2].settings') == '{"mode":"quiet"}' ]] \
   && ! grep -q "kept the settings" <<<"$out"; then
  ok "parking a widget that was off the bar seeds it from the manifest defaults"
else
  bad "parking an off-bar widget seeds the manifest defaults" "$out"
fi
run remove example.offbar >/dev/null 2>&1

echo
echo "add refusals"

for case in "ninepointlabs.barback:cannot hold itself" \
            "omarchy.clock:stay on the bar" \
            "example.serviceonly:not a bar widget" \
            "example.nope:not installed" \
            "example.gone:not installed" \
            "example.shelf:a drawer cannot hold another drawer" \
            "example.clone:a drawer cannot hold another drawer" \
            "example.noqml:its barWidget file is gone" \
            "example.off:turned off in shell.json" \
            "../../etc:invalid plugin id"; do
  id="${case%%:*}"; want="${case#*:}"
  out="$(run add "$id" 2>&1)"
  if [[ $? -ne 0 ]] && grep -qF "$want" <<<"$out"; then
    ok "add refuses $id ($want)"
  else
    bad "add refuses $id" "$out"
  fi
done

[[ $(cfg '(.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items | length') -eq 2 ]] \
  && ok "no refusal changed the drawer" \
  || bad "no refusal changed the drawer" "$(cfg '(.bar.layout.right[]|select(.id=="ninepointlabs.barback")).items')"

echo
echo "list and probe with residents"

out="$(run list)"
grep -q "example.alpha" <<<"$out" && grep -q "compact" <<<"$out" \
  && ok "list shows residents, ids and the compact flag" || bad "list shows residents" "$out"

out="$(run list --json)"
[[ $(jq -r '.residents | map(.id) | join(",")' <<<"$out") == "example.alpha,example.beta" ]] \
  && ok "list --json reports both residents" || bad "list --json" "$out"
[[ $(jq -r '[.residents[] | .ok] | all' <<<"$out") == true ]] \
  && ok "list --json reports both as resolved" || bad "list --json resolution" "$out"
[[ $(jq -r '.residents[] | select(.id == "example.beta") | .entryPoint' <<<"$out") == "$PLUGINS/beta-folder/ui/Bar.qml" ]] \
  && ok "a resident whose folder name differs from its id still resolves" \
  || bad "folder name != plugin id resolves" "$out"

run probe >/dev/null 2>&1 \
  && ok "probe passes when every resident resolves" || bad "probe passes" "$(run probe 2>&1)"

# Uninstall a resident behind Barback's back.
mv "$PLUGINS/beta-folder" "$SCRATCH/removed-beta"
run probe >/dev/null 2>&1 \
  && bad "probe fails when a resident vanishes" "probe still reported success" \
  || ok "probe fails when a resident is uninstalled behind our back"
grep -q "not installed" <<<"$(run probe 2>&1)" \
  && ok "probe names the reason" || bad "probe names the reason" "$(run probe 2>&1)"
mv "$SCRATCH/removed-beta" "$PLUGINS/beta-folder"

echo
echo "remove and clear"

: >"$RELOADS"
out="$(run remove example.alpha 2>&1)"
grep -q "still installed" <<<"$out" \
  && ok "remove says the plugin stays installed" || bad "remove wording" "$out"

[[ -d "$PLUGINS/example.alpha" ]] \
  && ok "eject never touches the plugin folder" || bad "eject never touches the folder" "folder gone"

[[ $(cfg '(.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items | map(.id) | join(",")') == '"example.beta"' ]] \
  && ok "remove ejects exactly one resident" \
  || bad "remove ejects one resident" "$(cfg '(.bar.layout.right[]|select(.id=="ninepointlabs.barback")).items')"

[[ $(cfg '[.bar.layout.left[],.bar.layout.center[],.bar.layout.right[] | .id] | index("example.alpha") // "none"') == '"none"' ]] \
  && ok "an ejected plugin is off the bar, not back on it" \
  || bad "an ejected plugin is off the bar" "$(cfg '.bar.layout')"

grep -q "reloadConfig" "$RELOADS" \
  && ok "remove reloaded the shell too" || bad "remove reloaded the shell" "$(cat "$RELOADS")"

before="$(cat "$CONFIG")"
out="$(run remove example.alpha 2>&1)"
if [[ $? -ne 0 ]] && grep -q "not in the drawer" <<<"$out" && [[ $(cat "$CONFIG") == "$before" ]]; then
  ok "removing a non-resident fails, says so, and changes nothing"
else
  bad "removing a non-resident" "$out"
fi

run clear >/dev/null 2>&1
[[ $(cfg '(.bar.layout.right[] | select(.id == "ninepointlabs.barback")).items | length') -eq 0 ]] \
  && ok "clear ejects everything" || bad "clear ejects everything" "$(cfg '.bar.layout.right')"
[[ -d "$PLUGINS/beta-folder" ]] \
  && ok "clear leaves every plugin installed" || bad "clear leaves plugins installed" "folder gone"

out="$(run clear 2>&1)"
grep -q "already empty" <<<"$out" \
  && ok "clearing an empty drawer is a no-op" || bad "clearing an empty drawer" "$out"

echo
echo "no drawer on the bar"

jq '.bar.layout.right |= map(select(.id != "ninepointlabs.barback"))' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
out="$(run add example.alpha 2>&1)"
if [[ $? -ne 0 ]] && grep -q "omarchy bar put ninepointlabs.barback" <<<"$out"; then
  ok "add refuses when Barback is not on the bar, and says how to fix it"
else
  bad "add refuses with no drawer" "$out"
fi

out="$(run probe 2>&1)"
if [[ $? -ne 0 ]] && grep -q "not on the bar" <<<"$out"; then
  ok "probe fails, and says why, when Barback is not on the bar"
else
  bad "probe with no drawer" "$out"
fi

echo
echo "a shell.json that does not parse"

cp "$CONFIG" "$SCRATCH/good.json"
printf '{ "bar": { broken\n' >"$CONFIG"
cp "$CONFIG" "$SCRATCH/broken.json"
for cmd in list probe "add example.alpha"; do
  out="$(run $cmd 2>&1)"
  if [[ $? -ne 0 ]] && grep -qF "could not parse $CONFIG" <<<"$out" && ! grep -q "not on the bar" <<<"$out"; then
    ok "$cmd names the unparseable shell.json instead of saying Barback is not on the bar"
  else
    bad "$cmd on a broken shell.json" "$out"
  fi
done
cmp -s "$CONFIG" "$SCRATCH/broken.json" \
  && ok "a broken shell.json is left exactly as it was" \
  || bad "a broken shell.json is left alone" "$(cat "$CONFIG")"
cp "$SCRATCH/good.json" "$CONFIG"

echo
echo "--version"

out="$(run --version 2>&1)"; rc=$?
want="barback $(jq -r .version "$ROOT/manifest.json")"
[[ $rc -eq 0 && $out == "$want" ]] \
  && ok "--version prints the version from manifest.json" \
  || bad "--version" "got '$out', want '$want'"

echo
echo "the live config was never touched"

if [[ -n $LIVE_MTIME_BEFORE ]]; then
  [[ $(stat -c %Y "$LIVE_CONFIG") == "$LIVE_MTIME_BEFORE" ]] \
    && ok "the live ~/.config/omarchy/shell.json was not modified" \
    || bad "the live shell.json was not modified" "its mtime moved during this run"
else
  bad "the live shell.json was not modified" "no live shell.json found to compare against"
fi

stray=$(grep -vc 'shell reloadConfig\|shell rescanPlugins' "$RELOADS")
[[ $stray -eq 0 ]] \
  && ok "every omarchy-shell call the helper made was a reload, and went to the stub" \
  || bad "every omarchy-shell call went to the stub" "$(cat "$RELOADS")"

echo
echo "$pass passed, $fail failed"
exit $((fail == 0 ? 0 : 1))
