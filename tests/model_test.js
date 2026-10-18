#!/usr/bin/env node
"use strict";

// Node tests for Model.js.
//
// Model.js is a QML `.pragma library`: that first line is not valid
// JavaScript, and QML libraries have no export statement. Both are handled the
// way the file itself promises — strip the pragma, evaluate the rest in a
// fresh context, and read the top-level declarations straight off it. Nothing
// is duplicated here, so a test can never pass against a stale copy.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const ROOT = path.resolve(__dirname, "..");

function loadModel() {
  const source = fs.readFileSync(path.join(ROOT, "Model.js"), "utf8");
  const body = source.replace(/^\s*\.pragma\s+library\s*$/m, "");
  const context = vm.createContext({ console, JSON, Math, isFinite, Array, Object, String, Number });
  vm.runInContext(body, context, { filename: "Model.js" });
  return context;
}

const Model = loadModel();

let passed = 0;
const failures = [];

function check(name, fn) {
  try {
    fn();
    passed++;
    console.log("  ok   " + name);
  } catch (error) {
    failures.push({ name, error });
    console.log("  FAIL " + name + "\n       " + error.message);
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message || "assertion failed");
}

function equal(actual, expected, message) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error((message || "mismatch") + "\n       expected " + b + "\n       actual   " + a);
}

// --------------------------------------------------------------- fixtures

const PLUGINS = "/home/tim/.config/omarchy/plugins";

function record(dir, manifest, entryExists) {
  const out = { dir, path: PLUGINS + "/" + dir, manifest };
  // Left off entirely when the caller does not say: "nobody looked" is not the
  // same answer as "the file is not there".
  if (entryExists !== undefined) out.entryExists = entryExists;
  return out;
}

// Shaped after the real plugins installed on this machine, including the two
// whose folder name does not match their manifest id and the three hidden
// `omarchy plugin remove` backups sitting in the same directory.
const REAL_RECORDS = [
  record("com.omastorm.radar", {
    schemaVersion: 1, id: "com.omastorm.radar", name: "Omastorm", version: "1.0.0",
    kinds: ["bar-widget", "panel"],
    entryPoints: { barWidget: "ui/RadarBar.qml", panel: "ui/Panel.qml" },
    barWidget: { displayName: "Omastorm", defaultSection: "right" }
  }),
  record("io.github.dougfour.grok-usage", {
    schemaVersion: 1, id: "io.github.dougfour.grok-usage", name: "Grok Usage", version: "1.0.0",
    kinds: ["service"], entryPoints: { service: "Service.qml" }, barWidget: null
  }),
  record("ninepointlabs.spotify", {
    schemaVersion: 1, id: "ninepointlabs.spotify", name: "Spotify", version: "1.0.0",
    kinds: ["service", "bar-widget"],
    entryPoints: { service: "Service.qml", barWidget: "BarWidget.qml" },
    barWidget: { displayName: "Spotify", defaults: { showTrack: true, maxLabelWidth: 180 } }
  }),
  record("omostrich", {
    schemaVersion: 1, id: "tim.omostrich", name: "Omostrich", version: "1.0.0",
    kinds: ["bar-widget", "overlay"],
    entryPoints: { barWidget: "Panel.qml", overlay: "Overlay.qml" },
    barWidget: { displayName: "Omostrich" }
  }),
  record("ring-cameras", {
    schemaVersion: 1, id: "tim.ring-cameras", name: "Ring Cameras", version: "1.0.0",
    kinds: ["bar-widget"], entryPoints: { barWidget: "Panel.qml" },
    barWidget: { displayName: "Ring Cameras", defaults: { pollIntervalSec: 30 } }
  }),
  record("tim.theme-rotate", {
    schemaVersion: 1, id: "tim.theme-rotate", name: "Theme Rotate", version: "1.0.0",
    kinds: ["bar-widget"], entryPoints: { barWidget: "Panel.qml" },
    barWidget: { displayName: "Theme Rotate" }
  }),
  // The three backups `omarchy plugin remove` left behind, plus a clone
  // staging dir. All hidden, none of them plugins any more.
  record(".ninepointlabs.dopewars.bak.20260909154215", {
    schemaVersion: 1, id: "ninepointlabs.dopewars", name: "Dopewars", version: "1.0.0",
    kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
  }),
  record(".zorkmachy.bak.20260909154202", {
    schemaVersion: 1, id: "ninepointlabs.zorkmachy", name: "Zorkmachy", version: "1.0.0",
    kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
  }),
  record(".ninepointlabs.hey-calendar.bak.20260910155859", {
    schemaVersion: 1, id: "ninepointlabs.hey-calendar", name: "HEY Calendar", version: "1.0.0",
    kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
  })
];

const INDEX = Model.buildIndex(REAL_RECORDS);

// ------------------------------------------------------------------ tests

console.log("\nindex");

check("indexes by manifest id, not by folder name", () => {
  assert(INDEX["tim.ring-cameras"], "tim.ring-cameras should be indexed");
  assert(INDEX["tim.omostrich"], "tim.omostrich should be indexed");
  equal(INDEX["tim.ring-cameras"].dir, "ring-cameras");
  equal(INDEX["tim.omostrich"].dir, "omostrich");
  assert(!INDEX["ring-cameras"], "folder name must not become an id");
});

check("skips hidden backup and staging directories", () => {
  assert(!INDEX["ninepointlabs.dopewars"], "a .bak backup must never resolve");
  assert(!INDEX["ninepointlabs.zorkmachy"], "a .bak backup must never resolve");
  assert(!INDEX["ninepointlabs.hey-calendar"], "a .bak backup must never resolve");
  equal(Object.keys(INDEX).sort(), [
    "com.omastorm.radar",
    "io.github.dougfour.grok-usage",
    "ninepointlabs.spotify",
    "tim.omostrich",
    "tim.ring-cameras",
    "tim.theme-rotate"
  ]);
});

check("isHiddenDir matches the shell's own dot rule", () => {
  assert(Model.isHiddenDir(".ninepointlabs.dopewars.bak.20260909154215"));
  assert(Model.isHiddenDir(".git"));
  assert(Model.isHiddenDir(""));
  assert(!Model.isHiddenDir("ninepointlabs.spotify"));
});

check("rejects a reserved omarchy.* id and a bad schemaVersion", () => {
  const index = Model.buildIndex([
    record("omarchy.clock", { schemaVersion: 1, id: "omarchy.clock", kinds: ["bar-widget"], entryPoints: { barWidget: "C.qml" } }),
    record("old.plugin", { schemaVersion: 2, id: "old.plugin", kinds: ["bar-widget"], entryPoints: { barWidget: "C.qml" } }),
    record("bad..id", { schemaVersion: 1, id: "bad..id", kinds: ["bar-widget"], entryPoints: { barWidget: "C.qml" } })
  ]);
  equal(Object.keys(index), []);
});

console.log("\nresident resolution");

check("resolves a real bar widget to a file:// entry point URL", () => {
  const resident = Model.resolveItem({ id: "ninepointlabs.spotify" }, INDEX);
  equal(resident.ok, true);
  equal(resident.reason, "ok");
  equal(resident.url, "file:///home/tim/.config/omarchy/plugins/ninepointlabs.spotify/BarWidget.qml");
  equal(resident.displayName, "Spotify");
  equal(resident.defaults, { showTrack: true, maxLabelWidth: 180 });
  equal(resident.placeholder, false);
  equal(resident.prunable, false);
});

check("resolves a nested entry point under a mismatched folder name", () => {
  const resident = Model.resolveItem("com.omastorm.radar", INDEX);
  equal(resident.ok, true);
  equal(resident.url, "file:///home/tim/.config/omarchy/plugins/com.omastorm.radar/ui/RadarBar.qml");

  const ring = Model.resolveItem("tim.ring-cameras", INDEX);
  equal(ring.ok, true);
  equal(ring.url, "file:///home/tim/.config/omarchy/plugins/ring-cameras/Panel.qml");
});

check("a service-only plugin is a placeholder, not a resident", () => {
  // The design spec's own State example parks io.github.dougfour.grok-usage,
  // which ships kinds:["service"] and no barWidget entry point at all.
  const resident = Model.resolveItem("io.github.dougfour.grok-usage", INDEX);
  equal(resident.ok, false);
  equal(resident.reason, "not-a-bar-widget");
  equal(resident.placeholder, true);
  equal(resident.prunable, false);
});

check("an unsafe or absent entry point resolves to no-entry-point", () => {
  const index = Model.buildIndex([
    record("escape", { schemaVersion: 1, id: "x.escape", kinds: ["bar-widget"], entryPoints: { barWidget: "../../evil.qml" } }),
    record("absolute", { schemaVersion: 1, id: "x.absolute", kinds: ["bar-widget"], entryPoints: { barWidget: "/etc/passwd" } }),
    record("none", { schemaVersion: 1, id: "x.none", kinds: ["bar-widget"], entryPoints: {} })
  ]);
  for (const id of ["x.escape", "x.absolute", "x.none"]) {
    const resident = Model.resolveItem(id, index);
    equal(resident.reason, "no-entry-point", id);
    equal(resident.placeholder, true, id);
  }
});

check("refuses to hold itself, a reserved id, or a malformed id", () => {
  equal(Model.resolveItem("ninepointlabs.barback", INDEX).reason, "self");
  equal(Model.resolveItem("omarchy.clock", INDEX).reason, "reserved");
  equal(Model.resolveItem("../../etc", INDEX).reason, "invalid-id");
  for (const id of ["ninepointlabs.barback", "omarchy.clock", "../../etc"])
    equal(Model.resolveItem(id, INDEX).prunable, true, id);
});

check("resolveAll keeps order and per-item settings", () => {
  const residents = Model.resolveAll([
    { id: "tim.theme-rotate", compact: true },
    { id: "com.omastorm.radar", settings: { units: "imperial" } }
  ], INDEX);
  equal(residents.map(r => r.id), ["tim.theme-rotate", "com.omastorm.radar"]);
  equal(residents[0].compact, true);
  equal(residents[1].settings, { units: "imperial" });
});

console.log("\npruning");

check("prunes a plugin uninstalled behind our back", () => {
  const items = [
    { id: "ninepointlabs.spotify", settings: {} },
    { id: "ninepointlabs.dopewars", settings: {} },
    { id: "tim.theme-rotate", settings: {}, compact: true }
  ];
  const result = Model.prune(items, INDEX);
  equal(result.changed, true);
  equal(result.items.map(i => i.id), ["ninepointlabs.spotify", "tim.theme-rotate"]);
  equal(result.pruned, [{ id: "ninepointlabs.dopewars", reason: "missing" }]);
  equal(Model.pruneLog(result.pruned),
    ["barback: dropped ninepointlabs.dopewars from the drawer (not installed)"]);
});

check("never resolves a resident through a hidden backup directory", () => {
  // ninepointlabs.hey-calendar exists on disk only as
  // .ninepointlabs.hey-calendar.bak.20260910155859. Parking it must prune,
  // not mount the removed copy.
  const result = Model.prune([{ id: "ninepointlabs.hey-calendar" }], INDEX);
  equal(result.items, []);
  equal(result.pruned, [{ id: "ninepointlabs.hey-calendar", reason: "missing" }]);
});

check("keeps an installed-but-unloadable resident as a placeholder", () => {
  const result = Model.prune([{ id: "io.github.dougfour.grok-usage" }], INDEX);
  equal(result.changed, false);
  equal(result.items.map(i => i.id), ["io.github.dougfour.grok-usage"]);
  equal(result.pruned, []);
});

check("an empty drawer stays empty and reports no change", () => {
  const result = Model.prune([], INDEX);
  equal(result, { items: [], pruned: [], changed: false });
});

console.log("\nmembership");

check("addItem seeds settings and refuses duplicates", () => {
  let items = Model.addItem([], "tim.theme-rotate", {}, false);
  items = Model.addItem(items, "ninepointlabs.spotify", INDEX["ninepointlabs.spotify"].defaults, true);
  items = Model.addItem(items, "ninepointlabs.spotify", {}, false);
  equal(Model.serializeItems(items), [
    { id: "tim.theme-rotate", settings: {} },
    { id: "ninepointlabs.spotify", settings: { showTrack: true, maxLabelWidth: 180 }, compact: true }
  ]);
});

check("removeItem ejects exactly one resident", () => {
  const items = Model.normalizeItems([{ id: "a.one" }, { id: "a.two" }]);
  equal(Model.removeItem(items, "a.one").map(i => i.id), ["a.two"]);
  equal(Model.removeItem(items, "a.missing").map(i => i.id), ["a.one", "a.two"]);
});

check("normalizeItems drops blanks and duplicates, accepts bare strings", () => {
  equal(Model.serializeItems(Model.normalizeItems(["a.one", { id: "a.one" }, {}, null, "a.two"])),
    [{ id: "a.one", settings: {} }, { id: "a.two", settings: {} }]);
});

check("mergeItemSettings folds updateEntryInline into one resident only", () => {
  const items = Model.normalizeItems([
    { id: "tim.theme-rotate", settings: { mode: "off" } },
    { id: "com.omastorm.radar", settings: { units: "imperial" } }
  ]);
  const merged = Model.mergeItemSettings(items, "tim.theme-rotate",
    { id: "tim.theme-rotate", mode: "interval", intervalHours: 6 });
  equal(Model.serializeItems(merged), [
    { id: "tim.theme-rotate", settings: { mode: "interval", intervalHours: 6 } },
    { id: "com.omastorm.radar", settings: { units: "imperial" } }
  ]);
});

check("hostedSettings applies the compact overlay without clobbering choices", () => {
  equal(Model.hostedSettings({ defaultTab: "search" }, false), { defaultTab: "search" });
  equal(Model.hostedSettings({ defaultTab: "search" }, true), {
    defaultTab: "search", compact: true,
    showTrack: false, showNext: false, showTime: false,
    showLabel: false, showText: false, showTitle: false
  });
  // An explicit setting wins over the compact default.
  equal(Model.hostedSettings({ showTrack: true }, true).showTrack, true);
  equal(Model.hostedSettings(null, false), {});
});

console.log("\nthe Add a widget picker");

// Tim authorised a real picker on the chip, overriding the design spec's
// "deliberately not a plugin picker" rule. See DEVIATIONS.md. These are the
// exclusions that make the offered list trustworthy: the picker must never
// offer something `barback add` would then refuse.

check("the picker lists eligible widgets by name, not by id", () => {
  const offered = Model.candidates(INDEX, []);
  equal(offered.map(c => c.displayName),
    ["Omastorm", "Omostrich", "Ring Cameras", "Spotify", "Theme Rotate"]);
  equal(offered.map(c => c.id), [
    "com.omastorm.radar", "tim.omostrich", "tim.ring-cameras",
    "ninepointlabs.spotify", "tim.theme-rotate"
  ]);
});

check("the picker excludes stock widgets, hidden backups, services and self", () => {
  const offered = Model.candidates(INDEX, []).map(c => c.id);
  // io.github.dougfour.grok-usage is kinds:["service"] with no bar widget.
  assert(offered.indexOf("io.github.dougfour.grok-usage") === -1, "a service-only plugin is not offerable");
  assert(offered.indexOf("ninepointlabs.barback") === -1, "Barback cannot hold itself");
  for (const backup of ["ninepointlabs.dopewars", "ninepointlabs.zorkmachy", "ninepointlabs.hey-calendar"])
    assert(offered.indexOf(backup) === -1, backup + " lives in a hidden backup dir");
  const withStock = Model.buildIndex(REAL_RECORDS.concat([
    record("omarchy.clock", {
      schemaVersion: 1, id: "omarchy.clock", name: "Clock", version: "1.0.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "Clock.qml" }
    })
  ]));
  assert(Model.candidates(withStock, []).map(c => c.id).indexOf("omarchy.clock") === -1,
    "stock omarchy.* widgets stay on the bar");
});

check("the picker excludes widgets already in the drawer", () => {
  const items = [{ id: "ninepointlabs.spotify" }, { id: "tim.theme-rotate" }];
  equal(Model.candidates(INDEX, items).map(c => c.id),
    ["com.omastorm.radar", "tim.omostrich", "tim.ring-cameras"]);
  // …unless something asks for them, which is how a membership view would.
  equal(Model.candidates(INDEX, items, { includeMembers: true })
    .filter(c => c.inDrawer).map(c => c.id),
    ["ninepointlabs.spotify", "tim.theme-rotate"]);
});

check("the picker excludes another drawer, and a clone of this one", () => {
  const index = Model.buildIndex(REAL_RECORDS.concat([
    record("someone.shelf", {
      schemaVersion: 1, id: "someone.shelf", name: "Shelf", version: "1.0.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" },
      barWidget: { displayName: "Shelf", hostsBarWidgets: true }
    }),
    record("tim.barback", {
      schemaVersion: 1, id: "tim.barback", name: "Barback", version: "0.1.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" },
      barWidget: { displayName: "Barback (clone)" },
      omarchy: { clonedFrom: "ninepointlabs.barback" }
    })
  ]));
  assert(index["someone.shelf"].drawer === true, "hostsBarWidgets marks a drawer");
  assert(index["tim.barback"].drawer === true, "a clone of Barback is still a drawer");
  const offered = Model.candidates(index, []).map(c => c.id);
  assert(offered.indexOf("someone.shelf") === -1, "nested drawers are out of scope for v1");
  assert(offered.indexOf("tim.barback") === -1, "a Barback clone cannot go in the drawer");
  // And a hand-edited membership list naming one does not mount it either.
  const resident = Model.resolveItem("someone.shelf", index);
  equal(resident.ok, false);
  equal(resident.reason, "nested-drawer");
  equal(resident.placeholder, true);
});

check("the picker excludes a plugin the user turned off", () => {
  const offered = Model.candidates(INDEX, [], { disabled: ["tim.theme-rotate"] }).map(c => c.id);
  assert(offered.indexOf("tim.theme-rotate") === -1, "a disabled plugin is not offerable");
  assert(offered.indexOf("ninepointlabs.spotify") !== -1, "its neighbours are unaffected");
  equal(Model.disabledIds({ disabledPlugins: ["a.one", "a.one", "", "a.two"] }), ["a.one", "a.two"]);
  equal(Model.disabledIds({}), []);
  equal(Model.disabledIds(null), []);
});

check("the picker excludes a broken manifest and a missing entry-point file", () => {
  const index = Model.buildIndex([
    record("x.gone", {
      schemaVersion: 1, id: "x.gone", name: "Gone", version: "1.0.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
    }, false),
    record("x.there", {
      schemaVersion: 1, id: "x.there", name: "There", version: "1.0.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
    }, true),
    // Missing `version`, and an unparseable defaultSection: the shell's own
    // validateManifest refuses both, so the picker must not offer them.
    record("x.noversion", {
      schemaVersion: 1, id: "x.noversion", name: "No Version",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" }
    }, true),
    record("x.badsection", {
      schemaVersion: 1, id: "x.badsection", name: "Bad Section", version: "1.0.0",
      kinds: ["bar-widget"], entryPoints: { barWidget: "BarWidget.qml" },
      barWidget: { defaultSection: "middle" }
    }, true)
  ]);
  equal(Model.candidates(index, []).map(c => c.id), ["x.there"]);
  equal(index["x.noversion"].problem, "missing-version");
  equal(index["x.badsection"].problem, "bad-default-section");
  // A resident that goes this way keeps its slot and says why, rather than
  // disappearing out of the membership list.
  equal(Model.resolveItem("x.gone", index).reason, "entry-point-missing");
  equal(Model.resolveItem("x.gone", index).placeholder, true);
  equal(Model.resolveItem("x.badsection", index).reason, "invalid-manifest");
  equal(Model.prune([{ id: "x.gone" }], index).items.map(i => i.id), ["x.gone"]);
});

check("every picker row is an id barback add accepts", () => {
  // The contract between the two surfaces: anything offered resolves.
  for (const candidate of Model.candidates(INDEX, [], { disabled: [] }))
    equal(Model.resolveItem(candidate.id, INDEX).ok, true, candidate.id);
});

check("moving a widget off the bar keeps the settings it had there", () => {
  const defaults = { showTrack: true, maxLabelWidth: 180 };
  // The layout entry the widget had on the bar: its own settings, plus the
  // keys that are not settings at all.
  const layoutEntry = { id: "ninepointlabs.spotify", section: "right", showTrack: false };
  equal(Model.settingsForAdd(defaults, layoutEntry), { showTrack: false, maxLabelWidth: 180 });
  // Off the bar already: defaults only, which is what add has always done.
  equal(Model.settingsForAdd(defaults, {}), defaults);
  equal(Model.settingsForAdd(defaults, null), defaults);
  equal(Model.settingsForAdd(null, { units: "imperial" }), { units: "imperial" });
  // `items` belongs to a drawer and is never a resident's setting.
  equal(Model.settingsForAdd({}, { id: "x", items: [{ id: "y" }] }), {});
});

check("the empty chip says what it is for", () => {
  equal(Model.chipTooltip([], 0), "Barback — the drawer is empty. Click to add a widget.");
  equal(Model.chipTooltip([{ ok: true }], 0), "Barback — 1 widget in the drawer");
  equal(Model.chipTooltip([{ ok: true }, { ok: false }], 2),
    "Barback — 1 widget in the drawer, 1 unavailable · 2 signalling");
});

check("a populated collapsed chip keeps a visible count", () => {
  // Live bug: adding Upcoming took it off the bar, then the collapsed chip
  // looked empty because it painted a Nerd Font glyph with no count. The
  // count is ASCII so it stays visible even if the glyph font misses.
  equal(Model.chipLabel([], true, false), "");
  equal(Model.chipLabel([{ ok: true }], true, false), "1");
  equal(Model.chipLabel([{ ok: true }, { ok: true }, { ok: false }], true, false), "2");
  equal(Model.chipLabel([{ ok: true }], true, true), "");
  equal(Model.chipLabel([{ ok: true }], false, false), "");
});

console.log("\nshell.json reading");

const CONFIG = {
  version: 1,
  bar: {
    layout: {
      left: [{ id: "omarchy.menu" }],
      center: [{ id: "omarchy.weather" }],
      right: [
        { id: "omarchy.tray" },
        {
          id: "ninepointlabs.barback",
          section: "right",
          items: [
            { id: "io.github.dougfour.grok-usage", settings: {}, compact: true },
            { id: "com.omastorm.radar", settings: { units: "imperial" } }
          ]
        },
        { id: "tim.theme-rotate", mode: "off" }
      ]
    }
  },
  plugins: []
};

check("finds Barback's entry wherever it sits", () => {
  const location = Model.findDrawerEntry(CONFIG);
  equal(location.found, true);
  equal(location.section, "right");
  equal(location.index, 1);
});

check("reads the spec's State example verbatim", () => {
  equal(Model.serializeItems(Model.drawerItems(CONFIG)), [
    { id: "io.github.dougfour.grok-usage", settings: {}, compact: true },
    { id: "com.omastorm.radar", settings: { units: "imperial" } }
  ]);
});

check("layoutLocations finds every entry a resident still owns", () => {
  equal(Model.layoutLocations(CONFIG, "tim.theme-rotate"), [
    { section: "right", index: 2, entry: { id: "tim.theme-rotate", mode: "off" } }
  ]);
  equal(Model.layoutLocations(CONFIG, "com.omastorm.radar"), []);
});

check("tolerates a missing or malformed config without throwing", () => {
  for (const config of [null, {}, { bar: {} }, { bar: { layout: { right: "nope" } } }]) {
    equal(Model.findDrawerEntry(config).found, false);
    equal(Model.drawerItems(config), []);
    equal(Model.layoutLocations(config, "x"), []);
  }
});

console.log("\nbadges");

check("reads the optional barbackBadge convention off a live item", () => {
  equal(Model.badgeValue({ barbackBadge: 3 }), 3);
  equal(Model.badgeValue({ barbackAttention: true }), 1);
  equal(Model.badgeValue({}), 0);
  equal(Model.badgeValue(null), 0);
  equal(Model.badgeValue({ barbackBadge: "lots" }), 0);
  equal(Model.badgeTotal([2, 0, 1, "x", -4]), 3);
});

check("auto-expand stays off unless a resident opts in and is signalling", () => {
  const residents = [{ settings: { autoExpandOnAttention: true } }, { settings: {} }];
  equal(Model.wantsAutoExpand(residents, [0, 5]), false);
  equal(Model.wantsAutoExpand(residents, [1, 0]), true);
});

// ----------------------------------------------------------------- report

console.log("\n" + passed + " passed, " + failures.length + " failed");
process.exit(failures.length === 0 ? 0 : 1);
