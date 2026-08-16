// Pure helpers for the WireGuard widget. Kept free of QML types so the
// parsing and command-building can be reasoned about (and tested) on their own.

// `sudo -n find /etc/wireguard ... -exec basename {} .conf \;` prints one
// tunnel name per line. /etc/wireguard is root-only, which is why listing goes
// through the sudoers rule rather than a plain readdir.
function parseConfigs(raw) {
  var out = []
  var lines = String(raw || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var name = lines[i].trim()
    if (name !== "") out.push(name)
  }
  return out
}

// `ip -o link show type wireguard` prints one line per live tunnel:
//   5: wg-office: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue ...
// This needs no privileges, so the poll that runs every few seconds stays
// entirely out of sudo.
function parseInterfaces(raw) {
  var out = []
  var lines = String(raw || "").split(/\r?\n/)
  for (var i = 0; i < lines.length; i++) {
    var match = /^\d+:\s*([^:@\s]+)/.exec(lines[i])
    if (match) out.push(match[1])
  }
  return out
}

function buildTunnels(configs, upNames) {
  var active = {}
  var up = Array.isArray(upNames) ? upNames : []
  for (var i = 0; i < up.length; i++) active[up[i]] = true

  var names = Array.isArray(configs) ? configs.slice() : []
  // A tunnel can be up from a config this user cannot enumerate (brought up by
  // systemd, say). Showing it is strictly better than pretending it is absent.
  for (var j = 0; j < up.length; j++) {
    if (names.indexOf(up[j]) === -1) names.push(up[j])
  }
  names.sort(function(a, b) { return String(a).localeCompare(String(b)) })

  var out = []
  for (var k = 0; k < names.length; k++) {
    out.push({ name: names[k], up: active[names[k]] === true })
  }
  return out
}

function upNames(tunnels) {
  var out = []
  var list = Array.isArray(tunnels) ? tunnels : []
  for (var i = 0; i < list.length; i++) if (list[i] && list[i].up) out.push(list[i].name)
  return out
}

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

// The sudoers rule grants exactly `/usr/bin/wg-quick`, so a privileged shell is
// never available. The sequence therefore runs as an unprivileged `sh -c` that
// elevates one wg-quick call at a time — each of which matches the rule.
//
// `down` on an already-down tunnel exits non-zero, so the exclusive teardown
// tolerates failure; only the final call decides the exit code the panel reports.
function toggleScript(name, turnOn, exclusive, currentlyUp) {
  var parts = []
  if (turnOn && exclusive) {
    var others = Array.isArray(currentlyUp) ? currentlyUp : []
    for (var i = 0; i < others.length; i++) {
      if (others[i] === name) continue
      parts.push("sudo -n /usr/bin/wg-quick down " + shellQuote(others[i]) + " || true")
    }
  }
  parts.push("sudo -n /usr/bin/wg-quick " + (turnOn ? "up " : "down ") + shellQuote(name))
  return parts.join("; ")
}

function statusSummary(tunnels) {
  var up = upNames(tunnels)
  if (up.length === 0) return "Disconnected"
  if (up.length === 1) return up[0]
  return up.length + " tunnels up"
}

function tooltipText(tunnels, configsReadable) {
  if (!configsReadable && tunnels.length === 0) return "WireGuard: cannot read /etc/wireguard"
  if (tunnels.length === 0) return "WireGuard: no tunnels configured"
  var up = upNames(tunnels)
  if (up.length === 0) return "WireGuard: disconnected"
  return "WireGuard: " + up.join(", ")
}

// Matches the glyphs the old Waybar module used, so the bar reads the same.
function barGlyph(tunnels, configsReadable) {
  if (!configsReadable && tunnels.length === 0) return "󰻌" // unavailable
  if (upNames(tunnels).length > 0) return "󰦝"              // connected
  return "󰦞"                                               // disconnected
}

// A friendly one-liner for the common sudo failure, which otherwise surfaces as
// raw "sudo: a password is required" noise inside the panel.
function friendlyError(stderr, exitCode) {
  var text = String(stderr || "").trim()
  if (/a password is required|no tty present|may not run/i.test(text)) {
    return "Needs a passwordless sudo rule for /usr/bin/wg-quick"
  }
  if (text !== "") return text.split(/\r?\n/)[0]
  return "wg-quick failed (exit " + exitCode + ")"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseConfigs: parseConfigs,
    parseInterfaces: parseInterfaces,
    buildTunnels: buildTunnels,
    upNames: upNames,
    shellQuote: shellQuote,
    toggleScript: toggleScript,
    statusSummary: statusSummary,
    tooltipText: tooltipText,
    barGlyph: barGlyph,
    friendlyError: friendlyError
  }
}
