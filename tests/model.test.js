const assert = require("assert")
const M = require("../Model.js")

// `ip -o link show type wireguard` output, verbatim shape.
const IP_OUT = [
  '5: wg-office: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\\    link/none ',
  '6: wg-home: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000\\    link/none '
].join("\n")

assert.deepStrictEqual(M.parseInterfaces(IP_OUT), ["wg-office", "wg-home"])
assert.deepStrictEqual(M.parseInterfaces(""), [])
assert.deepStrictEqual(M.parseConfigs("wg-home\nwg-office\n"), ["wg-home", "wg-office"])

// Tunnels merge configs with live state, sorted, and keep a live tunnel whose
// config we could not enumerate.
assert.deepStrictEqual(
  M.buildTunnels(["wg-office", "wg-home"], ["wg-office"]),
  [{ name: "wg-home", up: false }, { name: "wg-office", up: true }]
)
assert.deepStrictEqual(
  M.buildTunnels([], ["wg-secret"]),
  [{ name: "wg-secret", up: true }]
)

assert.strictEqual(M.statusSummary(M.buildTunnels(["a", "b"], [])), "Disconnected")
assert.strictEqual(M.statusSummary(M.buildTunnels(["a", "b"], ["a"])), "a")
assert.strictEqual(M.statusSummary(M.buildTunnels(["a", "b"], ["a", "b"])), "2 tunnels up")

// Exclusive mode tears the others down first; non-exclusive does not.
assert.strictEqual(
  M.toggleScript("wg-home", true, true, ["wg-office"]),
  "sudo -n /usr/bin/wg-quick down 'wg-office' || true; sudo -n /usr/bin/wg-quick up 'wg-home'"
)
assert.strictEqual(
  M.toggleScript("wg-home", true, false, ["wg-office"]),
  "sudo -n /usr/bin/wg-quick up 'wg-home'"
)
// Never tear down the tunnel being brought up.
assert.strictEqual(
  M.toggleScript("wg-home", true, true, ["wg-home"]),
  "sudo -n /usr/bin/wg-quick up 'wg-home'"
)
assert.strictEqual(
  M.toggleScript("wg-home", false, true, ["wg-home"]),
  "sudo -n /usr/bin/wg-quick down 'wg-home'"
)
// A hostile config name cannot break out of the quoting.
assert.strictEqual(
  M.toggleScript("a'; rm -rf /; #", false, false, []),
  "sudo -n /usr/bin/wg-quick down 'a'\\''; rm -rf /; #'"
)

assert.match(M.friendlyError("sudo: a password is required", 1), /passwordless sudo/)
assert.strictEqual(M.friendlyError("", 3), "wg-quick failed (exit 3)")

// Bar glyphs are distinct and carry the Nerd Font codepoints the old module used.
assert.strictEqual(M.barGlyph(M.buildTunnels(["a"], ["a"]), true).codePointAt(0), 0xf099d)
assert.strictEqual(M.barGlyph(M.buildTunnels(["a"], []), true).codePointAt(0), 0xf099e)
assert.strictEqual(M.barGlyph([], false).codePointAt(0), 0xf0ecc)

console.log("all model tests passed")
