#!/usr/bin/env node
"use strict";

// Node tests for About.js, the facts on the About page.
//
// Checks them against the repo itself — manifest.json, LICENSE and the first
// commit — plus the prefilled support email, and that the privacy statement
// names every way the shipped code could reach the network: adding a host or a
// network command without naming it there fails this test. Reads the repo
// only; touches nothing else. About.js is loaded the way model_test.js loads
// Model.js: pragma stripped, evaluated in a fresh context.

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const { execFileSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const read = (name) => fs.readFileSync(path.join(ROOT, name), "utf8");

function loadAbout() {
  const body = read("About.js").replace(/^\s*\.pragma\s+library\s*$/m, "");
  const context = vm.createContext({ JSON, Math, String, encodeURIComponent });
  vm.runInContext(body, context, { filename: "About.js" });
  return context;
}

const About = loadAbout();

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

// ------------------------------------------------------------------ facts

const manifest = JSON.parse(read("manifest.json"));
const license = read("LICENSE");

check("version comes from manifest.json", () => {
  equal(About.manifestVersion(read("manifest.json")), manifest.version);
  equal(About.manifestVersion("not json"), "");
  equal(About.manifestVersion(""), "");
  equal(About.manifestVersion('{"version":"1.0 <b>"}'), "");
});

check("name and maker match manifest.json", () => {
  equal(About.NAME, manifest.name);
  equal(About.ORGANIZATION, "Nine Point Labs");
  equal(manifest.author, "Nine Point Labs");
});

check("support address is the one every Nine Point Labs app uses", () => {
  equal(About.SUPPORT_EMAIL, "help@ninepointlabs.com");
});

check("created date is the first commit's month", () => {
  let first = "";
  try {
    first = execFileSync("git", ["log", "--reverse", "--format=%ad", "--date=format:%B %Y"],
      { cwd: ROOT, encoding: "utf8" }).split("\n")[0];
  } catch (error) {
    throw new Error("no git history to check against");
  }
  equal(About.CREATED, first);
});

check("license summary comes from LICENSE", () => {
  equal(About.licenseSummary(license), "MIT License, © 2026 Nine Point Labs");
  equal(manifest.license, "MIT");
});

check("license text is LICENSE, one line per paragraph", () => {
  const body = About.licenseBody(license);
  assert(body.startsWith("MIT License\n\nCopyright (c) 2026 Nine Point Labs\n\nPermission is hereby granted"),
    body.substring(0, 80));
  assert(body.includes('THE SOFTWARE IS PROVIDED "AS IS"'), "keeps the warranty disclaimer");
  assert(!body.includes("a copy\nof"), "paragraphs are reflowed");
});

// ------------------------------------------------- versions and support mail

check("probes Quickshell and Qt versions", () => {
  equal(About.probedVersion((a, b) => a === 6 && b <= 11, 6), "6.11");
  equal(About.probedVersion((a, b) => a === 0 && b <= 3, 0), "0.3");
  equal(About.probedVersion(() => false, 6), "");
  equal(About.probedVersion(null, 6), "");
  equal(About.builtWith("", ""), "Quickshell and Qt");
});

check("version details and the prefilled email", () => {
  const details = About.details("0.1.0", "0.3", "6.11", "Hyprland, wayland");
  equal(details, "Barback 0.1.0\nQuickshell 0.3, Qt 6.11\nHyprland, wayland");
  const url = About.mailto("0.1.0", details);
  assert(url.startsWith("mailto:help@ninepointlabs.com?subject=Barback%200.1.0&body="), url);
  equal(decodeURIComponent(url.split("&body=")[1]), "\n\n--\n" + details);
});

// ---------------------------------------------------------------- privacy

check("privacy statement says what Barback reads, writes and hosts", () => {
  for (const phrase of ["no telemetry", "never connects to the network", "~/.config/omarchy/plugins",
    "~/.config/omarchy/shell.json", "manifest.json", "keeps no other files", "other plugins' code",
    "does not sandbox them"])
    assert(About.PRIVACY.includes(phrase), "missing: " + phrase);
});

// Every file that ships, scanned for hosts and anything that reaches the
// network. Each must be named in the privacy statement, which today says
// Barback makes no connections at all — so any hit fails until it is named.
const SHIPPED = ["BarWidget.qml", "Model.js", "About.js", "AboutView.qml", "install.sh"]
  .concat(fs.readdirSync(path.join(ROOT, "bin")).map((f) => "bin/" + f));
const code = SHIPPED.map(read).join("\n");

check("every network host in the shipped code is named in the privacy statement", () => {
  const hosts = new Set();
  for (const m of code.matchAll(/\b(?:https?|wss?|ftp):\/\/([^\/"'\s$)]+)/g)) hosts.add(m[1]);
  for (const m of code.matchAll(/\bgit@([^:\s"']+):/g)) hosts.add(m[1]);
  const unnamed = [...hosts].filter((h) => !About.PRIVACY.includes(h));
  equal(unnamed, [], "hosts not named in About.PRIVACY");
});

check("no network command or API in the shipped code goes unnamed", () => {
  const reaches = [
    [/(?<![-\w])(curl|wget|nc|ncat|ssh|scp|rsync)\b/, "curl/wget/nc/ssh/rsync"],
    [/\bgit\s+(clone|fetch|pull|push|ls-remote)\b/, "git"],
    [/\bomarchy[- ]plugin[- ](add|update|install)\b/, "omarchy plugin add/update"],
    [/\bXMLHttpRequest\b|\bNetworkAccessManager\b|\bWebSocket\b|\bfetch\(/, "a network API"],
  ];
  const found = reaches.filter(([pattern, name]) => pattern.test(code) && !About.PRIVACY.includes(name))
    .map(([, name]) => name);
  equal(found, [], "network use not named in About.PRIVACY");
});

// ----------------------------------------------------------------- wiring

check("About is wired into the menu and the picker", () => {
  const qml = read("BarWidget.qml");
  assert(/component AboutButton: PanelActionButton/.test(qml), "AboutButton component");
  equal((qml.match(/AboutButton \{/g) || []).length, 2, "an About button in the menu and in the picker");
  assert(/onMenuOpenChanged: if \(!root\.menuOpen\) root\.aboutOpen = false/.test(qml), "closing the menu leaves About");
  assert(/onBackRequested: root\.aboutOpen = false/.test(qml), "Back returns to the menu");
});

check("install.sh ships the About files and LICENSE", () => {
  const assets = /^ASSETS=\(([^)]*)\)/m.exec(read("install.sh"));
  assert(assets, "ASSETS line");
  for (const f of ["About.js", "AboutView.qml", "LICENSE", "manifest.json"])
    assert(assets[1].split(/\s+/).includes(f), "install.sh does not copy " + f);
});

check("README says how to open About", () => {
  assert(/## About/.test(read("README.md")) && read("README.md").includes("󰋽"));
});

check("spelled Nine Point Labs everywhere", () => {
  const files = fs.readdirSync(ROOT).filter((f) => /\.(qml|js|md|json|sh)$|^LICENSE$/.test(f));
  const text = files.map(read).join("\n") + code;
  // Built from pieces so this file never matches itself.
  const misspelt = new RegExp(["Nine" + "point Labs", "NINE" + "POINT LABS", "Nine" + "Point Labs"].join("|"));
  assert(!misspelt.test(text));
});

// ----------------------------------------------------------------- report

console.log("\n" + passed + " passed, " + failures.length + " failed");
process.exit(failures.length === 0 ? 0 : 1);
