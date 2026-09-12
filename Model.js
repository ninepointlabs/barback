.pragma library

// Pure model code for Barback, the Omarchy bar drawer. No QML imports, so
// every function here is plain JavaScript that runs unchanged under node —
// see tests/model_test.js. BarWidget.qml owns the scene graph and the process
// that scans the plugins directory; this file owns every decision made about
// what it found.
//
// Vocabulary:
//   record    one installed plugin as the scanner reports it: { dir, path, manifest }
//   index     records keyed by manifest id, the same picture PluginRegistry builds
//   item      one drawer membership entry: { id, settings, compact }
//   resident  an item resolved against the index: what Barback actually mounts

var PLUGIN_ID = "ninepointlabs.barback"
var SECTIONS = ["left", "center", "right"]

// Same id rule the shell's CLI enforces before an id reaches any command.
var ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

// Resolution outcomes. "missing" and friends mean the plugin is gone or was
// never ours to host, so the item is pruned. "no-entry-point" and
// "not-a-bar-widget" mean the plugin is still installed but cannot be drawn,
// so it renders an inert placeholder instead — the user can see something is
// wrong without the drawer losing the membership record.
var PRUNE_REASONS = ["missing", "invalid-id", "reserved", "self"]

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function isValidPluginId(id) {
  var key = String(id || "")
  return ID_PATTERN.test(key) && key.indexOf("..") === -1
}

// A directory that the shell itself never treats as a plugin. Its scanner
// globs "$dir"/*/ , which skips dot-directories outright, and
// PluginRegistry.localPluginIdForPath rejects any relative path starting with
// a dot. Clone staging dirs and `omarchy plugin remove` backups live there —
// this box has .ninepointlabs.dopewars.bak.20260909154215 and two siblings —
// and resolving a resident through one would mount a plugin the user removed.
function isHiddenDir(name) {
  var value = String(name || "")
  return value === "" || value.charAt(0) === "."
}

// Mirrors PluginRegistry.isSafeEntryPoint: relative, inside the plugin dir.
function isSafeEntryPoint(value) {
  if (typeof value !== "string" || value.length === 0) return false
  if (value.charAt(0) === "/") return false
  if (value.indexOf("..") !== -1) return false
  return true
}

// Mirrors Commons/Util.fileUrl so hosted entry points get the same URL the
// shell would have built for them.
function fileUrl(path) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

function kindsOf(manifest) {
  return isPlainObject(manifest) && Array.isArray(manifest.kinds) ? manifest.kinds : []
}

function isBarWidget(manifest) {
  return kindsOf(manifest).indexOf("bar-widget") !== -1
}

function barWidgetMeta(manifest) {
  return isPlainObject(manifest) && isPlainObject(manifest.barWidget) ? manifest.barWidget : {}
}

function defaultsFor(manifest) {
  var defaults = barWidgetMeta(manifest).defaults
  return isPlainObject(defaults) ? cloneJson(defaults) : {}
}

function displayNameFor(manifest, fallbackId) {
  var meta = barWidgetMeta(manifest)
  var name = String(meta.displayName || (isPlainObject(manifest) ? manifest.name : "") || "")
  return name || String(fallbackId || "")
}

function cloneJson(value) {
  try {
    return JSON.parse(JSON.stringify(value))
  } catch (e) {
    return null
  }
}

// ------------------------------------------------------------------- index

// records: [{ dir: "<folder name>", path: "<absolute folder>", manifest: {...} }]
//
// Keyed by manifest id, not by folder name. Two of the ten plugins installed
// on this box do not agree on those: `omostrich/` declares tim.omostrich and
// `ring-cameras/` declares tim.ring-cameras. Resolving a resident by joining
// the plugins dir to the id would miss both.
function buildIndex(records) {
  var index = {}
  var list = Array.isArray(records) ? records : []
  for (var i = 0; i < list.length; i++) {
    var record = list[i]
    if (!isPlainObject(record)) continue
    if (isHiddenDir(record.dir)) continue

    var manifest = record.manifest
    if (!isPlainObject(manifest)) continue
    if (manifest.schemaVersion !== 1) continue

    var id = String(manifest.id || "")
    if (!isValidPluginId(id)) continue
    // Reserved for the shell's own widgets, and out of scope by design: stock
    // omarchy.* widgets stay on the bar.
    if (id.indexOf("omarchy.") === 0) continue
    // First folder wins, matching the shell's scan order (sorted dirs).
    if (index[id]) continue

    index[id] = {
      id: id,
      dir: String(record.dir || ""),
      path: String(record.path || ""),
      kinds: kindsOf(manifest).slice(),
      entryPoint: String((isPlainObject(manifest.entryPoints) ? manifest.entryPoints.barWidget : "") || ""),
      defaults: defaultsFor(manifest),
      displayName: displayNameFor(manifest, id)
    }
  }
  return index
}

// Mirrors PluginRegistry.entryPointUrl, including the defense-in-depth check
// that the resolved path has not escaped the plugin's own directory.
function entryPointUrl(record) {
  if (!isPlainObject(record)) return ""
  if (!isSafeEntryPoint(record.entryPoint)) return ""
  var dir = String(record.path || "").replace(/\/$/, "")
  if (!dir) return ""
  var resolved = dir + "/" + record.entryPoint
  if (resolved.indexOf(dir + "/") !== 0) return ""
  return fileUrl(resolved)
}

// ------------------------------------------------------------------- items

function normalizeItem(value) {
  var id = ""
  var settings = {}
  var compact = false
  if (typeof value === "string") {
    id = value
  } else if (isPlainObject(value)) {
    id = String(value.id || "")
    if (isPlainObject(value.settings)) settings = cloneJson(value.settings) || {}
    compact = value.compact === true
  }
  return { id: String(id || ""), settings: settings, compact: compact }
}

function normalizeItems(value) {
  var out = []
  var seen = {}
  var list = Array.isArray(value) ? value : []
  for (var i = 0; i < list.length; i++) {
    var item = normalizeItem(list[i])
    if (!item.id || seen[item.id]) continue
    seen[item.id] = true
    out.push(item)
  }
  return out
}

// Serialize back to the shape the spec's "State" section describes: `compact`
// only appears when it is on, `settings` always appears.
function serializeItem(item) {
  var out = { id: item.id, settings: isPlainObject(item.settings) ? item.settings : {} }
  if (item.compact === true) out.compact = true
  return out
}

function serializeItems(items) {
  var out = []
  for (var i = 0; i < items.length; i++) out.push(serializeItem(items[i]))
  return out
}

function indexOfItem(items, id) {
  var key = String(id || "")
  for (var i = 0; i < items.length; i++) if (items[i].id === key) return i
  return -1
}

function addItem(items, id, settings, compact) {
  var list = normalizeItems(items)
  var key = String(id || "")
  if (!key || indexOfItem(list, key) !== -1) return list
  list.push(normalizeItem({
    id: key,
    settings: isPlainObject(settings) ? settings : {},
    compact: compact === true
  }))
  return list
}

function removeItem(items, id) {
  var key = String(id || "")
  return normalizeItems(items).filter(function (item) { return item.id !== key })
}

// updateEntryInline(id, entry) from a hosted widget lands here: merge the
// widget's own settings into its slot of Barback's entry, leaving every other
// resident untouched.
function mergeItemSettings(items, id, patch) {
  var list = normalizeItems(items)
  var at = indexOfItem(list, id)
  if (at === -1) return list
  var merged = {}
  var key
  for (key in list[at].settings) merged[key] = list[at].settings[key]
  if (isPlainObject(patch)) {
    for (key in patch) {
      // The widget echoes its own id back in the entry it hands us; that is
      // the layout entry's key, not a setting, and storing it would shadow
      // the item's own id on the next round trip.
      if (key === "id") continue
      merged[key] = patch[key]
    }
  }
  list[at] = { id: list[at].id, settings: merged, compact: list[at].compact }
  return list
}

// --------------------------------------------------------------- residents

function resolveItem(item, index) {
  var normalized = normalizeItem(item)
  var resident = {
    id: normalized.id,
    settings: normalized.settings,
    compact: normalized.compact,
    ok: false,
    reason: "",
    dir: "",
    path: "",
    url: "",
    defaults: {},
    displayName: normalized.id,
    prunable: false,
    placeholder: false
  }

  if (!isValidPluginId(resident.id)) resident.reason = "invalid-id"
  else if (resident.id === PLUGIN_ID) resident.reason = "self"
  else if (resident.id.indexOf("omarchy.") === 0) resident.reason = "reserved"
  else {
    var record = isPlainObject(index) ? index[resident.id] : null
    if (!record) resident.reason = "missing"
    else {
      resident.dir = record.dir
      resident.path = record.path
      resident.defaults = record.defaults
      resident.displayName = record.displayName
      if (!isBarWidget(record)) resident.reason = "not-a-bar-widget"
      else {
        var url = entryPointUrl(record)
        if (!url) resident.reason = "no-entry-point"
        else {
          resident.url = url
          resident.ok = true
          resident.reason = "ok"
        }
      }
    }
  }

  resident.prunable = !resident.ok && PRUNE_REASONS.indexOf(resident.reason) !== -1
  resident.placeholder = !resident.ok && !resident.prunable
  return resident
}

function resolveAll(items, index) {
  var out = []
  var list = normalizeItems(items)
  for (var i = 0; i < list.length; i++) out.push(resolveItem(list[i], index))
  return out
}

// Split the membership list into what stays and what leaves. A plugin that is
// gone (uninstalled behind our back, or never installed) is dropped from
// items[]; a plugin that is still installed but cannot be drawn keeps its slot
// and draws an inert placeholder. A drawer that goes quiet beats a bar
// that dies, and neither case throws.
function prune(items, index) {
  var kept = []
  var pruned = []
  var residents = resolveAll(items, index)
  for (var i = 0; i < residents.length; i++) {
    var resident = residents[i]
    if (resident.prunable) pruned.push({ id: resident.id, reason: resident.reason })
    else kept.push({ id: resident.id, settings: resident.settings, compact: resident.compact })
  }
  return { items: kept, pruned: pruned, changed: pruned.length > 0 }
}

// One line, once, per pruned resident. Never an exception, never a dialog.
function pruneLog(pruned) {
  var out = []
  for (var i = 0; i < pruned.length; i++)
    out.push("barback: dropped " + pruned[i].id + " from the drawer (" + reasonText(pruned[i].reason) + ")")
  return out
}

function reasonText(reason) {
  switch (String(reason || "")) {
    case "ok": return "resolved"
    case "missing": return "not installed"
    case "invalid-id": return "invalid plugin id"
    case "reserved": return "reserved omarchy.* id"
    case "self": return "cannot hold itself"
    case "not-a-bar-widget": return "not a bar widget"
    case "no-entry-point": return "no barWidget entry point"
    case "load-failed": return "entry point did not load"
    default: return String(reason || "unknown")
  }
}

// What Barkeep (or a human running `barback list`) may usefully park. Stock
// omarchy.* widgets are out of scope for v1, and Barback cannot hold itself.
function candidates(index, items) {
  var resident = {}
  var list = normalizeItems(items)
  for (var i = 0; i < list.length; i++) resident[list[i].id] = true

  var out = []
  for (var id in index) {
    var record = index[id]
    if (id === PLUGIN_ID) continue
    if (id.indexOf("omarchy.") === 0) continue
    if (!isBarWidget(record)) continue
    if (!entryPointUrl(record)) continue
    out.push({ id: id, displayName: record.displayName, inDrawer: resident[id] === true })
  }
  out.sort(function (a, b) { return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0) })
  return out
}

// ------------------------------------------------------------------- chip

// The optional, soft attention convention: a hosted widget may expose
// `barbackBadge` (an int) or `barbackAttention` (a bool). Widgets that
// implement neither simply never signal.
function badgeValue(item) {
  if (!item) return 0
  var badge = item.barbackBadge
  if (typeof badge === "number" && isFinite(badge) && badge > 0) return Math.floor(badge)
  if (item.barbackAttention === true) return 1
  return 0
}

function badgeTotal(values) {
  var total = 0
  var list = Array.isArray(values) ? values : []
  for (var i = 0; i < list.length; i++) {
    var value = Number(list[i])
    if (isFinite(value) && value > 0) total += Math.floor(value)
  }
  return total
}

function wantsAutoExpand(residents, badges) {
  var list = Array.isArray(residents) ? residents : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].settings && list[i].settings.autoExpandOnAttention === true
        && badgeTotal([badges ? badges[i] : 0]) > 0) return true
  }
  return false
}

function chipTooltip(residents, badge) {
  var live = 0
  var broken = 0
  for (var i = 0; i < residents.length; i++) {
    if (residents[i].ok) live++
    else broken++
  }
  var text = "Barback — " + live + (live === 1 ? " widget" : " widgets") + " in the drawer"
  if (broken > 0) text += ", " + broken + " unavailable"
  if (badge > 0) text += " · " + badge + " signalling"
  return text
}

// ------------------------------------------------------- shell.json reading

// Barback's own layout entry, wherever it sits. Used by the model's tests and
// by anything that needs to read the drawer without the CLI.
function findDrawerEntry(config, pluginId) {
  var key = String(pluginId || PLUGIN_ID)
  if (!isPlainObject(config) || !isPlainObject(config.bar) || !isPlainObject(config.bar.layout))
    return { found: false }
  for (var s = 0; s < SECTIONS.length; s++) {
    var entries = config.bar.layout[SECTIONS[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var id = isPlainObject(entry) ? String(entry.id || "") : String(entry || "")
      if (id === key) return { found: true, section: SECTIONS[s], index: i, entry: entry }
    }
  }
  return { found: false }
}

function drawerItems(config, pluginId) {
  var location = findDrawerEntry(config, pluginId)
  if (!location.found || !isPlainObject(location.entry)) return []
  return normalizeItems(location.entry.items)
}

// Every layout entry for `id`, across all three sections. `barback add` has to
// clear these: a resident with its own layout entry would be drawn twice, once
// on the bar and once in the drawer.
function layoutLocations(config, id) {
  var key = String(id || "")
  var out = []
  if (!isPlainObject(config) || !isPlainObject(config.bar) || !isPlainObject(config.bar.layout)) return out
  for (var s = 0; s < SECTIONS.length; s++) {
    var entries = config.bar.layout[SECTIONS[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var entryId = isPlainObject(entry) ? String(entry.id || "") : String(entry || "")
      if (entryId === key) out.push({ section: SECTIONS[s], index: i, entry: entry })
    }
  }
  return out
}
