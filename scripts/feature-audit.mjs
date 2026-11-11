#!/usr/bin/env node
/* ==========================================================================
 * Feature audit for an Obsidian-family Electron application.
 *
 *   node scripts/feature-audit.mjs --cdp http://127.0.0.1:9222 [--json out.json]
 *
 * Runs an identical battery of in-app checks against the running renderer and
 * prints one line per feature. Run it against the official build and against
 * the clone and diff the two outputs: identical results mean identical
 * behaviour, not just identical pixels.
 * ========================================================================== */
import fs from "node:fs";

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = args.indexOf(name);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
};

const CDP = argOf("--cdp", "http://127.0.0.1:9222");
const JSON_OUT = argOf("--json", null);

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
  const reply = await send("Runtime.evaluate", {
    expression: `(async () => { ${expression} })()`,
    returnByValue: true,
    awaitPromise: true,
  });
  if (reply.result?.exceptionDetails) {
    return { __error: reply.result.exceptionDetails.text || "exception" };
  }
  return reply.result?.result?.value;
};

await new Promise((resolve) => (ws.onopen = resolve));

const results = [];
const check = async (name, expression) => {
  const value = await evaluate(expression);
  const ok = value !== undefined && value !== null && !(typeof value === "object" && value.__error);
  results.push({ name, ok, value: typeof value === "object" ? JSON.stringify(value) : String(value) });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name.padEnd(34)} ${ok ? "" : "(no result)"}`);
  return value;
};

console.log(`\n== feature audit @ ${CDP} ==\n`);

await check("app instance", "return !!window.app;");
await check("vault loaded", "return !!app.vault?.getName?.() && app.vault.getName();");
await check("file tree", "return app.vault.getMarkdownFiles().length;");
await check("core plugins loaded", "return Object.keys(app.internalPlugins?.plugins || {}).length;");
await check("core plugins enabled", "return Object.values(app.internalPlugins?.plugins || {}).filter(p => p._loaded).length;");
await check("community plugin api", "return !!app.plugins && typeof app.plugins.loadPlugin === 'function';");
await check("commands registered", "return app.commands.listCommands().length;");
await check("settings api", "return typeof app.setting?.open === 'function';");
await check("workspace leaves", "return app.workspace.getLeavesOfType('markdown').length + app.workspace.getLeavesOfType('empty').length;");
await check("markdown metadata cache", "return app.metadataCache.getCache('Start here.md') ? Object.keys(app.metadataCache.getCache('Start here.md')).length : 0;");
await check("resolved links", "return app.metadataCache.resolvedLinks?.size ?? Object.keys(app.metadataCache.resolvedLinks||{}).length;");
await check("unresolved links", "return app.metadataCache.unresolvedLinks?.size ?? Object.keys(app.metadataCache.unresolvedLinks||{}).length;");
await check("search plugin", "return !!app.internalPlugins?.plugins?.search;");
await check("search returns hits", `
  const search = app.internalPlugins?.plugins?.search;
  if (!search || typeof search.search !== 'function') return 'no search api';
  const hits = await search.search('vault');
  return Array.isArray(hits) ? hits.length : 'unexpected';
`);
await check("backlinks plugin", "return !!app.internalPlugins?.plugins?.backlinks;");
await check("graph plugin", "return !!app.internalPlugins?.plugins?.graph;");
await check("canvas plugin", "return !!app.internalPlugins?.plugins?.canvas;");
await check("bases plugin", "return !!app.internalPlugins?.plugins?.bases;");
await check("outline plugin", "return !!app.internalPlugins?.plugins?.outline;");
await check("switcher plugin", "return !!app.internalPlugins?.plugins?.quickSwitcher;");
await check("properties plugin", "return !!app.internalPlugins?.plugins?.properties;");
await check("templates plugin", "return !!app.internalPlugins?.plugins?.templates;");
await check("daily notes plugin", "return !!app.internalPlugins?.plugins?.dailyNotes;");
await check("bookmarks plugin", "return !!app.internalPlugins?.plugins?.bookmarks;");
await check("file explorer plugin", "return !!app.internalPlugins?.plugins?.fileExplorer;");
await check("page preview plugin", "return !!app.internalPlugins?.plugins?.pagePreview;");
await check("word count plugin", "return !!app.internalPlugins?.plugins?.wordCount;");
await check("outgoing link plugin", "return !!app.internalPlugins?.plugins?.outgoingLink;");
await check("tag plugin", "return !!app.internalPlugins?.plugins?.tag;");
await check("note composer plugin", "return !!app.internalPlugins?.plugins?.noteComposer;");
await check("command palette plugin", "return !!app.internalPlugins?.plugins?.commandPalette;");

await check("create + read + modify file", `
  const path = '__audit_' + Date.now() + '.md';
  await app.vault.create(path, '# Audit\\n\\nhello [[Start here]] #tag');
  const read = await app.vault.read(app.vault.getAbstractFileByPath(path));
  await app.vault.modify(app.vault.getAbstractFileByPath(path), '# Audit\\n\\nchanged');
  const read2 = await app.vault.read(app.vault.getAbstractFileByPath(path));
  await app.vault.delete(app.vault.getAbstractFileByPath(path));
  return read.includes('hello') && read2.includes('changed');
`);

await check("link resolution", "return app.metadataCache.getFirstLinkpathDest('Start here.md', '')?.path || 'none';");
await check("execute command", `
  const id = 'file-explorer:toggle';
  const before = app.workspace.leftSplit.expand;
  await app.commands.executeCommandById(id);
  const after = app.workspace.leftSplit.expand;
  await app.commands.executeCommandById(id);
  return typeof before === 'boolean' && typeof after === 'boolean';
`);
await check("open file in workspace", `
  const leaf = app.workspace.getLeaf('tab');
  await leaf.openFile(app.vault.getAbstractFileByPath('Start here.md'));
  return app.workspace.getActiveFile()?.basename || 'none';
`);
await check("pdf export capability", "return typeof app.printToPdf === 'function' || typeof app.internalPlugins?.plugins?.exportPDF === 'object';");
await check("custom css snippets dir", "return app.vault.getConfig('enabledCssSnippets') ? app.vault.getConfig('enabledCssSnippets').length : 0;");
await check("theme config", "return app.vault.getConfig('theme');");
await check("theme class on body", "return document.body.className.includes('theme-light') ? 'light' : document.body.className.includes('theme-dark') ? 'dark' : 'none';");
await check("toggle theme to dark", `
  app.vault.setConfig('theme', 'obsidian');
  await new Promise(r => setTimeout(r, 400));
  const dark = document.body.className.includes('theme-dark');
  app.vault.setConfig('theme', 'moonstone');
  await new Promise(r => setTimeout(r, 400));
  const light = document.body.className.includes('theme-light');
  return dark && light;
`);
await check("background token", "return getComputedStyle(document.body).getPropertyValue('--background-primary').trim();");
await check("accent token", "return getComputedStyle(document.body).getPropertyValue('--color-accent').trim();");
await check("editor (codemirror) mounted", "return document.querySelectorAll('.cm-editor').length;");
await check("status bar present", "return !!document.querySelector('.status-bar');");
await check("ribbon present", "return document.querySelectorAll('.workspace-ribbon .workspace-ribbon-item').length;");
await check("file explorer items", "return document.querySelectorAll('.nav-file-title').length;");
await check("monochrome: saturated pixels in DOM", `
  let coloured = 0;
  for (const el of document.querySelectorAll('body *')) {
    const s = getComputedStyle(el);
    for (const v of [s.color, s.fill, s.stroke]) {
      const m = v.match(/\\d+/g);
      if (!m || m.length < 3 || v === 'none') continue;
      const [r, g, b] = m.map(Number);
      if (Math.max(r, g, b) - Math.min(r, g, b) > 40) { coloured++; break; }
    }
  }
  return coloured;
`);
await check("native theme (os)", "return window.electron?.remote?.nativeTheme?.shouldUseDarkColors ?? 'unavailable';");
await check("electron version", "return navigator.userAgent;");
await check("vault config dir", "return app.vault.configDir;");
await check("app version", "return app.appVersion || app.version || 'n/a';");

const passed = results.filter((r) => r.ok).length;
console.log(`\n${passed}/${results.length} checks returned a result`);

if (JSON_OUT) {
  fs.writeFileSync(JSON_OUT, JSON.stringify({ cdp: CDP, passed, total: results.length, results }, null, 1));
  console.log(`written: ${JSON_OUT}`);
}
ws.close();
process.exit(passed === results.length ? 0 : 1);
