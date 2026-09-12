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

plugin() {
  local dir="$1" id="$2" kinds="$3" entry="$4" defaults="${5:-{\}}"
  mkdir -p "$PLUGINS/$dir"
  jq -n --arg id "$id" --argjson kinds "$kinds" --arg entry "$entry" --argjson defaults "$defaults" '
    { schemaVersion: 1, id: $id, name: $id, version: "1.0.0", kinds: $kinds,
      entryPoints: (if $entry == "" then {} else { barWidget: $entry } end),
      barWidget: { displayName: $id, defaults: $defaults } }' >"$PLUGINS/$dir/manifest.json"
  [[ -n $entry ]] && { mkdir -p "$(dirname "$PLUGINS/$dir/$entry")"; : >"$PLUGINS/$dir/$entry"; }
  return 0
}

plugin ninepointlabs.barback   ninepointlabs.barback   '["bar-widget"]' BarWidget.qml
plugin example.alpha           example.alpha           '["bar-widget"]' BarWidget.qml '{"showTrack":true,"maxLabelWidth":180}'
plugin beta-folder             example.beta            '["bar-widget"]' ui/Bar.qml
plugin example.serviceonly     example.serviceonly     '["service"]'    ''
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
grep -q "drawer is empty" <<<"$out" \
  && ok "list reports an empty drawer and says it costs no bar space" \
  || bad "list reports an empty drawer" "$out"

run probe >/dev/null 2>&1 \
  && ok "probe passes with no residents" \
  || bad "probe passes with no residents" "exit $?"

echo
echo "add"

out="$(run add example.alpha --compact 2>&1)"
grep -q "parked example.alpha" <<<"$out" \
  && ok "add parks a resident" || bad "add parks a resident" "$out"

[[ $(cfg '[.bar.layout.left[],.bar.layout.center[],.bar.layout.right[] | .id] | index("example.alpha") // "none"') == '"none"' ]] \
  && ok "add deletes the resident's entry from every layout section" \
  || bad "add deletes the resident's layout entry" "$(cfg '.bar.layout')"

[[ $(cfg '[.bar.layout.right[] | select(.id == "ninepointlabs.barback")] | length') -eq 1 ]] \
  && ok "Barback's own entry is still there, exactly once" \
  || bad "Barback's own entry survives" "$(cfg '.bar.layout.right')"

# The spec's State section, verbatim:
#   { id, section, items: [ { id, settings, compact? } ] }
if jq -e '
  (.bar.layout.right[] | select(.id == "ninepointlabs.barback")) as $e
  | ($e | keys_unsorted | sort) == ["id", "items", "section"]
  and $e.section == "right"
  and ($e.items | length) == 1
  and ($e.items[0] | keys_unsorted | sort) == ["compact", "id", "settings"]
  and $e.items[0].id == "example.alpha"
  and $e.items[0].compact == true
  and $e.items[0].settings == { showTrack: true, maxLabelWidth: 180 }
' "$CONFIG" >/dev/null; then
  ok "the entry is exactly the spec's State shape, settings seeded from the manifest defaults"
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

[[ $(cfg '.bar.layout.center | length') -eq 0 ]] \
  && ok "parking a widget from the center section empties that slot" \
  || bad "parking clears the center entry" "$(cfg '.bar.layout.center')"

echo
echo "add refusals"

for case in "ninepointlabs.barback:cannot hold itself" \
            "omarchy.clock:stay on the bar" \
            "example.serviceonly:not a bar widget" \
            "example.nope:not installed" \
            "example.gone:not installed" \
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

out="$(run remove example.alpha 2>&1)"
grep -q "not in the drawer" <<<"$out" \
  && ok "removing a non-resident is a no-op" || bad "removing a non-resident" "$out"

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
