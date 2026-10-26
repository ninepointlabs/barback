# Barback

A drawer for the Omarchy bar. One chip holds several third-party bar widgets,
so a stack of plugins you are trialling takes a single slot instead of one
each.

Barback is the one who stocks the bar. Sibling to
[Barkeep](https://github.com/ninepointlabs/barkeep) — Barkeep tends, Barback
shelves.

The drawer is **storage, not management**. It renders what it is told to
render and nothing more.

- **An empty drawer is one small dimmed chip.** Click it and pick a widget —
  that is the whole of the empty state.
- **Collapsed it is one glyph and a count.** Hover expands the row of
  residents along the bar axis, the same 600ms feel as `omarchy.tray`.
- **Click pins it open**, `Esc` closes, and clicking away closes it too.
- **Right-click for the menu**: eject a resident, *Add a widget…*, *Manage in
  Barkeep…*, *Eject all*, and 󰋽 for [About](#about).
- **Vertical bars** get `vertical: true` passed through, so hosted widgets
  pick their own compact forms for free.

Stock `omarchy.*` widgets stay on the bar; the drawer is for third-party
plugins that are installed and working but do not need to be looked at every
minute.

## Install

```bash
git clone https://github.com/ninepointlabs/barback ~/Projects/barback
cd ~/Projects/barback
./install.sh                                        # copies + validates only
omarchy bar put ninepointlabs.barback --section right
barback add com.omastorm.radar
```

`install.sh` stages the copy beside the live plugin directory, runs
`omarchy plugin validate` against the staged copy, and only then swaps it in
with an atomic rename. It does not enable the plugin, touch the bar layout, or
restart the shell.

That last step is optional: once the chip is on the bar, clicking it opens the
picker and you can fill the drawer from there.

## Add a widget

Two ways in:

- **Click the chip while the drawer is empty.** An empty drawer has nothing to
  expand, so the click that would pin it opens the picker instead.
- **Right-click → *Add a widget…*** once the drawer has something in it, because
  then the chip's own click is the pin gesture.

It lists every eligible installed third-party bar widget by display name, with
the plugin id beside it. Picking one runs `barback add` — the picker has no
writer of its own — which takes the widget off the bar, **keeps the settings it
had there**, and parks it in the drawer.

What it will not offer you, and why:

| Excluded | Why |
|---|---|
| hidden `.`-directories | `omarchy plugin remove` backups and clone staging dirs are not plugins any more |
| `omarchy.*` | stock widgets stay on the bar |
| Barback itself | a drawer cannot hold itself |
| another drawer | `barWidget.hostsBarWidgets`, or a clone of Barback: nested drawers are out of scope for v1 |
| anything already in the drawer | it is already in the drawer |
| service- or panel-only plugins | nothing to draw on a bar |
| a missing or unsafe `entryPoints.barWidget`, or one whose file is gone | the shell could not load it either |
| a manifest the shell would reject | missing `name`/`version`, empty `kinds`, bad `defaultSection` |
| anything in `disabledPlugins[]` | you turned it off |

The picker and `barback add` share one rule set, so the picker can never offer
something the CLI then refuses.

### The `hostsBarWidgets` marker

Barback's own manifest declares it:

```json
{ "barWidget": { "hostsBarWidgets": true } }
```

It means "this widget hosts other bar widgets", and it is how Barback recognises
a drawer — including a clone of itself, which `omarchy plugin clone` gives a new
id but the same manifest. A drawer is never offered as a resident and never
mounted as one. If you write another drawer-shaped widget, set it.

Both of these — the visible empty chip and the picker itself — are deliberate
departures from the design spec, authorised by Tim on 2026-09-12. See
[DEVIATIONS.md](DEVIATIONS.md).

## About

The 󰋽 button at the top right of the chip's right-click menu, or of the
*Add a widget* picker, opens **About** in the menu: the version (read from
`manifest.json`), the license (*Read it* shows the full text in place), Nine
Point Labs, when Barback was created, what it does with your data, and the
support address, [help@ninepointlabs.com](mailto:help@ninepointlabs.com), with
*Email* (your mail app, with the version details filled in), *Copy* and *Copy
version details* buttons. *Back* (or `Esc`) returns to the menu; closing the
menu leaves About.

## The CLI

```
barback list [--json]                 residents, their ids, and whether each resolved
barback add <plugin-id> [--compact]   park it: drop its layout entry, keep its settings,
                                      add to items[]
barback remove <plugin-id>            eject: back off the bar, still installed
barback clear                         eject everything
barback probe [--json]                re-check each resident resolves to a live entry point
barback --version                     print the installed version
```

Every write goes through `omarchy-shell-config`, the same shared helper
`omarchy-bar` itself sources: one jq program, an atomic replace, then the
running shell is told to reload. There is no `omarchy bar remove <id>` — the
stock bar group is `use / reset / defaults / position / transparent / put /
move / set` — so taking a widget off the bar means deleting its entry from the
layout array through that helper, which is what `barback add` does before it
parks anything.

### Eject is not uninstall

These are two different things and Barback never conflates them.

| Intent | Where | What happens |
|---|---|---|
| **Eject** | `barback remove`, the chip's right-click menu, Barkeep | Leaves the drawer. The plugin stays installed, its folder is untouched, and it has no layout entry — it is now "off the bar". Never prompts. |
| **Uninstall** | Barkeep, with its own confirmation | Deletes the plugin. Barback only has to prune its `items[]` afterwards, which it does on the next scan. |

`barback remove` and `barback clear` never call `omarchy plugin remove`, and
never delete anything from disk.

## State

Barback's own `shell.json` entry is the only home its residents have. They have
no entry of their own in `bar.layout`, and their settings live inside Barback's
entry. On the first add the plugin's `manifest.barWidget.defaults` are the
floor, and anything the widget actually had set in its own layout entry wins, so
moving a configured widget off the bar does not reset it.

```json
{
  "id": "ninepointlabs.barback",
  "section": "right",
  "items": [
    { "id": "io.github.dougfour.grok-usage", "settings": {}, "compact": true },
    { "id": "com.omastorm.radar", "settings": { "units": "imperial" } }
  ]
}
```

`compact` is a per-item toggle. Expanded, a text-bearing widget makes the
drawer wide, so `compact` injects the settings widgets in the wild use to drop
their text label (`showTrack`, `showNext`, `showTime`, `showLabel`, …) unless
that item's settings already say otherwise. A widget that has never heard of
those keys ignores them.

## The `barbackBadge` convention (optional, soft)

A hosted widget may expose either of these on its bar-widget root:

```qml
property int  barbackBadge      // > 0 means "I am signalling"
property bool barbackAttention  // true counts as 1
```

Barback reads whichever it finds off the live item and shows a dot on the
collapsed chip, with the total in the chip's tooltip. Widgets that implement
neither simply never signal, which is fine and is the expected case.

The default is **badge only, no auto-expand**. A resident that genuinely needs
eyes can opt in per item:

```json
{ "id": "tim.ring-cameras", "settings": { "autoExpandOnAttention": true } }
```

which expands the drawer while that resident is signalling and folds it again
when it clears. Anything whose whole job is to alert you belongs on the bar,
not in the drawer; this is an escape hatch, not a design goal.

## How hosting works

The `shell.json` bar layout is flat — `bar.layout.{left,center,right}`, entries
are `{id, ...settings}` — and there is no container or group kind, so a drawer
cannot be expressed as config. Barback is a plugin that mounts other plugins'
QML itself, the same way `shell.qml` does:

1. Scan `~/.config/omarchy/plugins` from disk. A bar widget is handed `bar`,
   `moduleName` and `settings` and nothing else — no `pluginRegistry`, no
   `manifest` — so the catalogue is rebuilt rather than asked for. Plugins are
   keyed by **manifest id, not folder name**; several plugins in the wild
   disagree on those. Dot-directories are skipped, which is what keeps an
   `omarchy plugin remove` backup from ever being mounted. The same scan checks
   that each `entryPoints.barWidget` is really a file on disk, and reads
   `disabledPlugins[]` out of `shell.json`, because both decide what the picker
   may offer.
2. Read `entryPoints.barWidget` from the resident's manifest and load it.
3. Inject `bar`, `moduleName` and `settings` — exactly the three properties
   `Bar.qml`'s `ModuleSlot` injects into every widget slot.

The `bar` a resident receives is a real `qs.Ui PluginBarApi`, the same type the
host hands a third-party widget, with its scalars copied from Barback's own
facade and its operations delegated back through it. Two entries matter:

- **`serviceFor(id)` returns `null` on purpose.** The common pattern in the
  wild is `sharedService: bar.shell.serviceFor(moduleName) … : null` then
  `service: sharedService || localService` with `Service { active: sharedService === null }`.
  Returning null puts each widget on its own tested local-service path.
- **`moduleWidgets(id)` returns that widget's live instances across monitors.**
  Barback tracks its residents per monitor, so it can answer this as well as
  the stock bar answers it for a widget that is really in the layout.

`updateEntryInline(id, entry)` from a resident merges into `items[id].settings`
inside Barback's own entry and persists; nothing else in the drawer is touched.

### What it costs

- **Identity moves.** A resident's click targets and popouts register under
  `ninepointlabs.barback`, so arrow-key panel switching walks within the drawer
  rather than on to the next bar item.
- **A resident has no layout entry, which is how the shell defines "enabled"
  for a bar widget.** While a plugin is in the drawer the shell will not mount
  its other kinds — a `service` kind is not started, a `panel` or `overlay`
  kind is not registered, and `omarchy-shell shell toggle <id>` will not reach
  it. Its bar widget still runs, with its own local service, inside the drawer.
  Barkeep lists it under "Off the bar" until Barkeep grows a Drawer group.
- **Width on a horizontal bar.** Collapsed is one chip; expanded, a
  text-bearing resident makes the drawer wide. That is what `compact` is for.
- **Outside the documented contract.** Nothing here touches upstream, but a
  shell update could move a property out from under the shim. Every resident is
  resolved before it is loaded and instantiated inside a guarded `Loader`; one
  that is gone is pruned with a single log line, and one that is installed but
  cannot be drawn renders an inert placeholder. Nothing throws. A drawer that
  goes quiet always beats a bar that dies.

## Tests

```bash
tests/run.sh
```

- `tests/model_test.js` — the pure model under node: resident resolution,
  pruning a plugin uninstalled behind our back, skipping dot-directories, every
  picker exclusion above, the settings-preserving move, the `shell.json` shapes.
- `tests/cli_test.sh` — the CLI against a scratch `shell.json` with a mocked
  shell reload, asserting the resulting entry is exactly the shape above, that a
  widget moved in off the bar keeps its settings, and that `add` refuses a
  nested drawer, a Barback clone, a plugin whose QML file is gone and a disabled
  plugin. The real `omarchy-shell-config` does the writing; only `$HOME` and the
  reload are isolated.
- `tests/about_test.js` — the About page's facts checked against
  `manifest.json`, `LICENSE` and the first commit, the prefilled support email,
  and that the privacy statement names every way the shipped code reaches the
  network (it fails if a host or network command is added without being named
  there).
- `tests/about_qml_test.sh` — the real `BarWidget.qml` under `qs` with a
  scratch `HOME`: opens About from the menu's 󰋽 button, checks what it shows,
  Back, and that closing the menu leaves it, and fails on any QML warning.
- `tests/qml_compat_test.sh` — the real `BarWidget.qml` hosting the real
  installed plugins, with no live side effects: scratch `HOME`, a copied
  plugins directory, every helper binary the residents spawn replaced by a
  logging stub, `bar.run` recorded rather than executed, and the whole run
  inside a network namespace the script verifies is empty before it starts. It
  loads a second, resident-free instance as well, which is where the empty chip
  and the picker are checked — including that picking a widget runs the bundled
  CLI exactly once, with the id it offered. The CLI is stubbed there too, so the
  run still writes nothing.

## Not in scope for v1

Drag-and-drop onto the chip, nested drawers, hosting stock `omarchy.*`
widgets, and marketplace submission.
