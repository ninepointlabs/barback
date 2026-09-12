# Deviations from the design spec

The authoritative design spec is
`~/Documents/Notes/Projects/Barback/Specs/Barback-Design.md`. It is not edited
from this repo. Where this implementation knowingly departs from it, the
departure is recorded here, with who authorised it and what was built instead.

## 1. An empty drawer is visible (authorised 2026-09-12, Tim)

**Spec says** — *Chip behavior*: "**Empty drawer occupies no space.** With zero
residents the chip is not drawn at all. A drawer you are not using costs
nothing." The brief repeats it: "Empty drawer draws nothing at all. Zero
residents means zero bar space used."

**Tim overrode this explicitly.** An invisible empty drawer is an
undiscoverable one: after installing Barback and putting it on the bar there was
nothing on screen to confirm it was there, and no way in other than the CLI or
the config file.

**Built instead** — with zero residents Barback draws one small chip: the
Barback glyph, no count, dimmed to 0.45 opacity until the pointer is on it, with
the tooltip *"Barback — the drawer is empty. Click to add a widget."* One bar
slot's worth of icon, and it is the only thing on the chip that can be clicked.

There is deliberately no setting to restore the old behaviour. The drawer has
one empty state, so what the README describes is always what is on the bar.

## 2. The chip has a real widget picker (authorised 2026-09-12, Tim)

**Spec says** — *Adding and removing → The chip's own right-click menu*: the
menu's "Add a plugin…" summons Barkeep, and "Deliberately **not** a plugin
picker. The chip holds a membership list and hands the choosing to Barkeep.
This follows the existing rule for the bar: one chip per concern, and never
stuff a full client into a dropdown."

**Tim overrode this explicitly.** Clicking the empty chip has to do something,
and bouncing the user to another application to answer "which widget?" is not
that. Barkeep's Drawer destination (deliverable 2 in the brief) is still the
primary, keyboard-driven path; this is the quick one.

**Built instead** — *Add a widget*, a `PopupCard` anchored to the chip, reached
two ways: clicking the chip while the drawer is empty, and the "Add a widget…"
row in the right-click menu when it is not. It lists every eligible installed
third-party bar widget by display name, with the plugin id beside it. Picking
one parks it.

What it does **not** become: it lists widgets and nothing else. No settings, no
enable/disable, no uninstall, no search-and-install. The "Manage in Barkeep…"
row is still there, and uninstalling is still Barkeep's job with Barkeep's
confirmation.

### What the picker will not offer

One rule set, in `Model.candidates`, mirrored by `resolve` in `bin/barback`, so
the picker can never offer something `barback add` then refuses. A model test
asserts that contract directly (*"every picker row is an id barback add
accepts"*).

| Excluded | Why |
|---|---|
| hidden `.`-directories | `omarchy plugin remove` backups and clone staging dirs; never indexed at all |
| `omarchy.*` | stock widgets stay on the bar — spec, *Not in scope* |
| `ninepointlabs.barback` | a drawer cannot hold itself |
| another drawer | `barWidget.hostsBarWidgets`, or `omarchy.clonedFrom: ninepointlabs.barback` — nested drawers are out of scope for v1, and mounting one in another recurses |
| already a resident | it is in the drawer; offering it again is noise |
| not a `bar-widget` | a service- or panel-only plugin has nothing to draw |
| no `entryPoints.barWidget`, or the file is gone | the shell could not load it either |
| a manifest the shell would reject | missing `name`/`version`, empty `kinds`, unsafe entry point, bad `defaultSection` |
| in `disabledPlugins[]` | the user turned it off |

## 3. Moving a widget into the drawer keeps its settings

Not a deviation from anything the spec says, but it is new behaviour and it
belongs with the picker it was built for. The spec's *State* section says
residents' settings are "seeded from the plugin's `manifest.barWidget.defaults`
on first add", which silently reset a widget that was already configured on the
bar. Now the manifest defaults are the floor and whatever the widget actually
had in its own layout entry wins (`Model.settingsForAdd`, mirrored in
`cmd_add`). A widget that was off the bar still gets plain defaults.

## What did not change

The architecture is untouched. Route B, hosted widget loading, the
`PluginBarApi` shim with `serviceFor` returning `null` on purpose, the `items[]`
state shape, hover-expand and click-to-pin on a populated drawer, prune-or-
placeholder failure handling, and the single-writer rule — every mutation still
goes through the shared `omarchy-shell-config` helper, via `bin/barback`. The
picker has no writer of its own: it runs `barback add`.
