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

// Manifest key a bar widget sets to say "I host other bar widgets." Barback's
// own manifest sets it, so this is also what keeps a clone of Barback — an
// `omarchy plugin clone` copy carries the manifest forward under a new id —
// out of the drawer. Nested drawers are out of scope for v1, and mounting one
// inside another is the one arrangement that can recurse.
var DRAWER_MARKER = "hostsBarWidgets"

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

function omarchyMeta(manifest) {
  return isPlainObject(manifest) && isPlainObject(manifest.omarchy) ? manifest.omarchy : {}
}

// A drawer: either it declares `barWidget.hostsBarWidgets`, or it is a clone of
// Barback (`omarchy.clonedFrom`, the key `omarchy plugin clone` stamps in).
function isDrawerManifest(manifest) {
  if (barWidgetMeta(manifest)[DRAWER_MARKER] === true) return true
  return String(omarchyMeta(manifest).clonedFrom || "") === PLUGIN_ID
}

// The soft half of PluginRegistry.validateManifest: the checks that make the
// shell refuse to load a plugin at all, minus the two this file already gates
// hard in buildIndex (schemaVersion and the id syntax). A manifest that fails
// here is broken rather than absent, so it keeps its membership slot and draws
// a placeholder — but it is never offered in the picker, because the shell
// would refuse to load it.
function manifestProblem(manifest) {
  if (!isPlainObject(manifest)) return "not-an-object"
  var required = ["id", "name", "version", "kinds", "entryPoints"]
  for (var i = 0; i < required.length; i++)
    if (manifest[required[i]] === undefined) return "missing-" + required[i]
  if (!Array.isArray(manifest.kinds) || manifest.kinds.length === 0) return "empty-kinds"
  if (!isPlainObject(manifest.entryPoints)) return "bad-entry-points"
  for (var key in manifest.entryPoints)
    if (!isSafeEntryPoint(manifest.entryPoints[key])) return "unsafe-entry-point"
  var meta = barWidgetMeta(manifest)
  if (meta.defaultSection !== undefined
      && SECTIONS.indexOf(String(meta.defaultSection)) === -1) return "bad-default-section"
  return ""
}

// ------------------------------------------------------------------- index

// records: [{ dir, path, manifest, entryExists }]
//
//   dir          the folder name
//   path         the absolute folder
//   manifest     the parsed manifest.json
//   entryExists  whether entryPoints.barWidget is a file that is really there,
//                as the scanner found it. Absent means "nobody looked", which
//                is not the same answer as false.
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

    var problem = manifestProblem(manifest)
    index[id] = {
      id: id,
      dir: String(record.dir || ""),
      path: String(record.path || ""),
      kinds: kindsOf(manifest).slice(),
      entryPoint: String((isPlainObject(manifest.entryPoints) ? manifest.entryPoints.barWidget : "") || ""),
      defaults: defaultsFor(manifest),
      displayName: displayNameFor(manifest, id),
      description: String(barWidgetMeta(manifest).description || manifest.description || ""),
      // Still indexed when broken, so a resident that goes bad keeps its slot
      // and says why instead of silently vanishing from the drawer.
      valid: problem === "",
      problem: problem,
      drawer: isDrawerManifest(manifest),
      entryExists: record.entryExists === undefined ? undefined : record.entryExists === true
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

// ------------------------------------------------------- hosted settings

// Settings keys widgets in the wild use to decide whether to paint a text
// label next to their icon: spotify's showTrack, upcoming's showNext,
// fastmail-calendar's showTime. Expanded, a text-bearing resident makes the
// drawer wide, so the per-item `compact` toggle turns these off. A widget
// that has never heard of a key ignores it — settings are free-form and
// BarWidget.setting() falls back to its own default — so this costs nothing
// where it does not apply.
var COMPACT_KEYS = ["showTrack", "showNext", "showTime", "showLabel", "showText", "showTitle"]

// What Barback actually injects as the hosted widget's `settings`. Barback
// owns this object: the item's stored settings, plus the compact overlay when
// the item asks for it.
function hostedSettings(settings, compact) {
  var out = {}
  var key
  if (isPlainObject(settings)) for (key in settings) out[key] = settings[key]
  if (compact === true) {
    out.compact = true
    for (var i = 0; i < COMPACT_KEYS.length; i++) {
      if (out[COMPACT_KEYS[i]] === undefined) out[COMPACT_KEYS[i]] = false
    }
  }
  return out
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
      // Most specific reason first: "no barWidget entry point" tells the user
      // what to do about it, "its manifest is broken" only tells them there is
      // something wrong. Every branch below is a placeholder either way.
      if (record.drawer === true) resident.reason = "nested-drawer"
      else if (!isBarWidget(record)) resident.reason = "not-a-bar-widget"
      else {
        var url = entryPointUrl(record)
        if (!url) resident.reason = "no-entry-point"
        else if (record.entryExists === false) resident.reason = "entry-point-missing"
        else if (record.valid === false) resident.reason = "invalid-manifest"
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
    case "entry-point-missing": return "its barWidget file is gone"
    case "invalid-manifest": return "its manifest is broken"
    case "nested-drawer": return "a drawer cannot hold another drawer"
    case "disabled": return "turned off in shell.json"
    case "load-failed": return "entry point did not load"
    default: return String(reason || "unknown")
  }
}

// What the "Add a widget" picker offers, and what `barback add` will accept.
// One list, one rule set, so the picker can never offer something the CLI then
// refuses. Everything excluded here is excluded for a reason the user would
// agree with if asked:
//
//   hidden backup dirs     never reach buildIndex at all (dot-directory rule)
//   stock omarchy.*        out of scope for v1: they stay on the bar
//   Barback itself         a drawer cannot hold itself
//   another drawer         nested drawers are out of scope, and recurse
//   already a resident     it is in the drawer; offering it again is noise
//   not a bar widget       a service- or panel-only plugin has nothing to draw
//   no/missing entry point ditto, and the shell could not load it either
//   broken manifest        the shell itself would refuse to load it
//   disabled               the user turned it off in shell.json
//
// options.disabled  ids from shell.json's `disabledPlugins[]`
// options.includeMembers  keep existing residents in the list, flagged
function candidates(index, items, options) {
  var opts = isPlainObject(options) ? options : {}
  var includeMembers = opts.includeMembers === true

  var member = {}
  var list = normalizeItems(items)
  for (var i = 0; i < list.length; i++) member[list[i].id] = true

  var disabled = {}
  var off = Array.isArray(opts.disabled) ? opts.disabled : []
  for (var d = 0; d < off.length; d++) disabled[String(off[d] || "")] = true

  var out = []
  for (var id in index) {
    var record = index[id]
    if (id === PLUGIN_ID) continue
    if (id.indexOf("omarchy.") === 0) continue
    if (record.drawer === true) continue
    if (record.valid === false) continue
    if (disabled[id] === true) continue
    if (!isBarWidget(record)) continue
    if (!entryPointUrl(record)) continue
    if (record.entryExists === false) continue
    if (member[id] === true && !includeMembers) continue
    out.push({
      id: id,
      displayName: record.displayName || id,
      description: String(record.description || ""),
      inDrawer: member[id] === true
    })
  }
  // By name, because that is what the picker shows; by id to break ties, so
  // the order never depends on the scan's directory order.
  out.sort(function (a, b) {
    var an = String(a.displayName).toLowerCase()
    var bn = String(b.displayName).toLowerCase()
    if (an !== bn) return an < bn ? -1 : 1
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
  return out
}

// Ids from shell.json's `disabledPlugins[]`: the one place the shell records a
// plugin the user turned off (see PluginRegistry.isDisabled).
function disabledIds(config) {
  if (!isPlainObject(config) || !Array.isArray(config.disabledPlugins)) return []
  var out = []
  for (var i = 0; i < config.disabledPlugins.length; i++) {
    var id = String(config.disabledPlugins[i] || "")
    if (id && out.indexOf(id) === -1) out.push(id)
  }
  return out
}

// Keys of a bar layout entry that are not widget settings. `id` names the
// entry, `section` is derived from the array it sits in, and `items` belongs to
// a drawer.
var ENTRY_NON_SETTINGS = ["id", "section", "items"]

// What a widget's settings become when it moves from the bar into the drawer.
// The manifest defaults are the floor; anything the user had actually set on
// the bar wins, because moving a widget into the drawer must not silently
// reset it. A widget with no layout entry (it was off the bar) just gets its
// defaults, which is what `barback add` has always done.
function settingsForAdd(defaults, layoutEntry) {
  var out = {}
  var key
  if (isPlainObject(defaults)) for (key in defaults) out[key] = defaults[key]
  if (isPlainObject(layoutEntry)) {
    for (key in layoutEntry) {
      if (ENTRY_NON_SETTINGS.indexOf(key) !== -1) continue
      out[key] = layoutEntry[key]
    }
  }
  return cloneJson(out) || {}
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

// The empty drawer is discoverable on purpose (see DEVIATIONS.md): a small
// chip that says what it is for, and opens the picker when clicked.
var EMPTY_TOOLTIP = "Barback — the drawer is empty. Click to add a widget."

function chipTooltip(residents, badge) {
  var live = 0
  var broken = 0
  if (!residents || residents.length === 0) return EMPTY_TOOLTIP
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
