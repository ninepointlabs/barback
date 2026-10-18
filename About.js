.pragma library

// Facts and text for the About page (AboutView.qml), kept out of QML so node
// can check them against the repo (tests/about_test.js), the same way
// Model.js is checked by tests/model_test.js.
//
// The version is read from manifest.json and the license text from LICENSE at
// run time, so neither is copied here and neither can drift from the real file.

var NAME = "Barback"
var TAGLINE = "A drawer for the Omarchy bar. One chip holds several bar widgets."
var ORGANIZATION = "Nine Point Labs"
var CREATED = "September 2026" // first commit: 2026-09-12
var SUPPORT_EMAIL = "help@ninepointlabs.com"

// Must stay true to what the plugin does. Network: none of its own (no URL,
// download tool, git remote or socket anywhere in the code; tests/about_test.js
// fails if one appears without being named here). Reads: every plugin's
// manifest.json and shell.json's disabledPlugins (BarWidget.qml scanScript,
// bin/barback catalog). Writes: shell.json only, through the shell's
// updateEntryInline (eject, prune, a resident's own settings) or bin/barback
// via omarchy-shell-config (add moves the widget's layout entry into Barback's
// items[]; remove/clear). Hosted widgets are other plugins' QML, loaded the way
// the bar loads them.
var PRIVACY = "No account, no sign-in and no telemetry, and Barback itself never connects to "
  + "the network. To list widgets it reads the manifest.json of each plugin in "
  + "~/.config/omarchy/plugins and the disabled-plugins list in ~/.config/omarchy/shell.json. "
  + "What is in the drawer is saved in Barback's own bar entry in that same shell.json: adding "
  + "a widget moves its bar entry, settings and all, into it, through the barback command and "
  + "Omarchy's shell-config helper, and ejecting one is saved by the shell. It keeps no other "
  + "files. Widgets you put in the drawer are other plugins' code: they run as they normally "
  + "would on the bar, with their own behaviour, including any network access or files of "
  + "their own, and Barback does not sandbox them. Manage in Barkeep opens Barkeep, a separate "
  + "plugin with its own privacy statement."

// "0.1.0" from manifest.json's text, or "" when it can't be read.
function manifestVersion(text) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return "" }
  var version = parsed && typeof parsed.version === "string" ? parsed.version : ""
  return /^[0-9A-Za-z.+-]{1,32}$/.test(version) ? version : ""
}

// "MIT License, © 2026 Nine Point Labs" from LICENSE's text: its first line
// plus its copyright line, as written there.
function licenseSummary(text) {
  var lines = String(text || "").split("\n")
  var name = ""
  var holder = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    if (name === "") name = line
    var m = /^Copyright\s+(?:\(c\)|©)\s*(.+)$/i.exec(line)
    if (m) { holder = "© " + m[1]; break }
  }
  return holder ? name + ", " + holder : name
}

// LICENSE with one line per paragraph, so it wraps to the popup's width.
function licenseBody(text) {
  var paras = String(text || "").replace(/\r/g, "").split(/\n\s*\n/)
  var out = []
  for (var i = 0; i < paras.length; i++) {
    var p = paras[i].replace(/\s+/g, " ").trim()
    if (p !== "") out.push(p)
  }
  return out.join("\n\n")
}

// Highest minor version `has(major, minor)` accepts, as "major.minor"
// (Quickshell.hasVersion / hasQtVersion only answer yes or no), or "".
function probedVersion(has, major) {
  if (typeof has !== "function" || !has(major, 0)) return ""
  var minor = 0
  while (minor < 99 && has(major, minor + 1)) minor++
  return major + "." + minor
}

function builtWith(quickshell, qt) {
  var out = []
  if (quickshell) out.push("Quickshell " + quickshell)
  if (qt) out.push("Qt " + qt)
  return out.length ? out.join(", ") : "Quickshell and Qt"
}

// Version details to paste into a support email.
function details(version, quickshell, qt, desktop) {
  return NAME + " " + (version || "unknown version") + "\n"
    + builtWith(quickshell, qt) + "\n"
    + (desktop || "unknown desktop")
}

function mailto(version, detailText) {
  return "mailto:" + SUPPORT_EMAIL
    + "?subject=" + encodeURIComponent(NAME + " " + (version || ""))
    + "&body=" + encodeURIComponent("\n\n--\n" + detailText)
}
