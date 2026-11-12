#!/usr/bin/env node
/* ==========================================================================
 * Verify Ainotes' monochrome theme by reading the computed styles back from
 * the running application over the Chrome DevTools Protocol.
 *
 *   node scripts/verify-theme.mjs [--cdp http://127.0.0.1:9222] [--expect light|dark]
 *
 * Launches nothing itself: start Ainotes with --remote-debugging-port first
 * (scripts/run-app.sh can do that), then run this against the live endpoint.
 * Exits non-zero when a token is not monochrome.
 * ========================================================================== */
import process from "node:process";

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};

const CDP = argOf("--cdp", "http://127.0.0.1:9222");
const EXPECT = argOf("--expect", "light");

const targets = await (await fetch(`${CDP}/json/list`)).json();
const page = targets.find((t) => t.type === "page");
if (!page) {
  console.error(`no page target on ${CDP}`);
  process.exit(2);
}

const ws = new WebSocket(page.webSocketDebuggerUrl);
let nextId = 0;
const pending = new Map();

ws.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    pending.get(message.id)(message);
    pending.delete(message.id);
  }
};

const send = (method, params) =>
  new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });

const evaluate = async (expression) => {
  const reply = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  return reply.result?.result?.value;
};

await new Promise((resolve) => (ws.onopen = resolve));

const tokens = await evaluate(`JSON.stringify((() => {
  const s = getComputedStyle(document.body);
  const pick = (name) => s.getPropertyValue(name).trim();
  return {
    bodyClass: document.body.className,
    background: s.backgroundColor,
    backgroundPrimary: pick('--background-primary'),
    backgroundSecondary: pick('--background-secondary'),
    textNormal: pick('--text-normal'),
    textMuted: pick('--text-muted'),
    accent: pick('--color-accent'),
    accentH: pick('--accent-h'),
    accentS: pick('--accent-s'),
    accentL: pick('--accent-l'),
    border: pick('--background-modifier-border'),
    tagBackground: pick('--tag-background'),
    shadow: pick('--shadow-s'),
    radius: pick('--radius-s'),
    linkColor: pick('--link-color'),
    codeBackground: pick('--code-background')
  };
})())`);

const values = JSON.parse(tokens);
console.log(JSON.stringify(values, null, 2));

const hexToRgb = (hex) => {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};

const isNeutral = (hex) => {
  const rgb = hexToRgb(hex);
  if (!rgb) return false;
  return rgb[0] === rgb[1] && rgb[1] === rgb[2];
};

const checks = [];
const expectLight = EXPECT === "light";
const wantBg = expectLight ? 255 : 0;
const wantFg = expectLight ? 0 : 255;

checks.push([
  "--background-primary is the pure base colour",
  values.backgroundPrimary.toLowerCase() === (expectLight ? "#ffffff" : "#000000"),
  values.backgroundPrimary,
]);
checks.push([
  "--text-normal is the pure base colour",
  values.textNormal.toLowerCase() === (expectLight ? "#000000" : "#ffffff"),
  values.textNormal,
]);
checks.push(["--color-accent is neutral", isNeutral(values.accent), values.accent]);
checks.push([
  "accent saturation is 0%",
  values.accentS === "0%" || values.accentS === "0",
  values.accentS,
]);
checks.push(["body background is pure", values.background === `rgb(${wantBg}, ${wantBg}, ${wantBg})`, values.background]);
checks.push(["shadows removed", values.shadow === "none", values.shadow]);

let failed = 0;
for (const [name, ok, actual] of checks) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name} (${actual})`);
  if (!ok) failed++;
}

ws.close();
console.log(failed === 0 ? "\ntheme verified: monochrome" : `\n${failed} check(s) failed`);
process.exit(failed === 0 ? 0 : 1);
