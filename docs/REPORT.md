# Reverse-engineering report — Obsidian 1.15.0 → Obsidian Clone (Linux, monochrome)

**Target:** Obsidian 1.15.0 desktop application for Linux (official AppImage)
**Date:** 2026-11-11
**Tooling:** [REA](https://github.com/morluto/rea) (`rea-agents` 6.8.0), Node 22.23.4, Electron 43.8.4
**Outcome:** a from-source rebuild that keeps every application feature and changes only the colour system.

---

## 1. Objective

Clone Obsidian for Linux, keep the feature set intact (target: ≥ 99 % parity) and replace the
colour system with a minimal white/black monochrome theme. The clone had to be produced from the
application's own artefacts (there is no public source), so the work was:

1. acquire and unpack the release,
2. understand the packaging, the process architecture and the design-token system,
3. rebuild the application from its extracted sources with a new theme,
4. re-package it as native Linux installables,
5. verify parity and behaviour.

---

## 2. Tooling decision

REA was installed from npm (`npm install -g rea-agents`, v6.8.0) and drove the whole analysis:

```bash
rea doctor                     # environment audit
rea analyze-javascript-application <path> --detail summary --evidence_output <file>
rea capture-electron-scenario <scenario.json>
rea inspect-electron-fuses <binary>
```

**Ghidra was deliberately not required.** The target is an Electron application: the interesting
logic is JavaScript, and REA's static JavaScript/Electron analyser handles it without a native
analysis engine. A native engine would only have been needed to study Chromium itself, which is
not part of the clone. `rea doctor` reported Ghidra as a missing *optional* provider
(`GHIDRA_INSTALL_DIR is not set`) and the JavaScript lane was fully healthy, so no Ghidra
installation was performed. For completeness REA's own `inspect-electron-fuses` was used on the
runtime binary, which reads Electron's fuse table directly.

---

## 3. Target acquisition

Obsidian publishes its application payload separately from the AppImage, which made the
acquisition clean:

| Artefact | URL fragment | Size | SHA-256 / note |
| --- | --- | --- | --- |
| `Obsidian-1.15.0.AppImage` | `releases/download/v1.15.0/` | 138 122 125 B | Electron 43.8.4 + runtime assets |
| `obsidian-1.15.0.asar.gz` | `releases/download/v1.15.0/` | 8 528 283 B | the application payload (gzip) |
| `obsidian_1.15.0_amd64.deb` | `releases/download/v1.15.0/` | 107 879 792 B | alternative packaging |

Unpacked:

```
Obsidian-1.15.0.AppImage
└── squashfs-root/
    ├── obsidian                 224 689 400 B   Electron 43.8.4 (Chrome 150.0.7871.250)
    ├── resources/
    │   ├── app.asar                  73 443 B   Electron bootstrap (launcher)
    │   ├── app.asar.unpacked/                    native modules (btime, get-fonts)
    │   └── obsidian.asar         24 553 884 B   the application payload
    ├── locales/, *.pak, *.so, icudtl.dat, AppRun, md.obsidian.Obsidian.desktop
```

The payload was extracted with `@electron/asar` into `extracted/` (25 MB, 38 analysable sources).

---

## 4. Architecture recovered

```
┌─ obsidian (Electron 43.8.4) ────────────────────────────────────────┐
│ resources/app.asar/main.js            ← thin bootstrap (launcher)   │
│   • registerSchemesAsPrivileged('app://', standard+secure+stream)   │
│   • app.setPath('userData') → ~/.config/obsidian                    │
│   • auto-updater: GitHub release feed → RSA-SHA256 verify            │
│     (embedded dynaList.io certificate) → gunzip → obsidian-<v>.asar   │
│   • loadApp(asarPath) → require('<asar>/main.js')(asarPath, events)   │
│                                                                   │
│ resources/obsidian.asar/main.js       ← real Electron main process │
│   • app://obsidian.md/ scheme handler serves the renderer assets    │
│   • index.html → app.js (renderer), starter.html, quicklook, help   │
│   • IPC to the renderer, vault handling, plugins, sync, CLI socket  │
└─────────────────────────────────────────────────────────────────────┘
```

Key recovered facts:

* **Origin scheme** — the renderer is not loaded from `file://`; everything is served from
  `app://obsidian.md/` (`index.html`, `starter.html`, `help.html`, `app.css`, `app.js`, `lib/…`).
  This is why a theme can be injected by adding one `<link>` to the HTML entry points.
* **Two-stage bootstrap** — the launcher never contains application logic; it only resolves,
  verifies and hands over the payload. Upstream updates are *signature-verified*, so the payload
  is meant to be replaced as a whole.
* **Single instance lock** — `app.requestSingleInstanceLock()` plus a `.obsidian-cli.sock` unix
  socket for the CLI.
* **User data** — `app.getPath('userData')` → `~/.config/obsidian` (vault registry `obsidian.json`,
  per-vault state `<vaultid>.json`, `obsidian.log`, Chromium profile data).
* **Renderer assets** — `app.js` 3.37 MB, `app.css` 598 KB, `enhance.js` 12.8 KB, `i18n.js`
  134 KB (50 locales), `worker.js` 250 KB, `starter.js` 439 KB, `quicklook.js` 675 KB,
  `sim.js`, `help.js`, plus `lib/` (CodeMirror 6, MathJax, PDF.js, PixiJS, reveal.js, Prism,
  Turndown, Defuddle, Readability, i18next, moment, scrypt) and `public/` (Inter + Source Code Pro).
* **Runtime hardening** — the shipped binary disables Electron's
  `EnableNodeCliInspectArguments` fuse (confirmed by `rea inspect-electron-fuses`), which is why
  REA's *active* Electron provider refuses to attach to it and why the stock Electron runtime was
  used for the scenario capture instead.

### Electron fuse table of the shipped runtime

`rea inspect-electron-fuses ./clone/obsidian` (evidence in
`docs/evidence/electron-fuses.json`, ELF slice 0, sentinel at file offset 36 162 864):

| Fuse | State |
| --- | --- |
| `RunAsNode` | disabled |
| `EnableCookieEncryption` | enabled |
| `EnableNodeOptionsEnvironmentVariable` | disabled |
| `EnableNodeCliInspectArguments` | disabled |
| **`EnableEmbeddedAsarIntegrityValidation`** | **disabled** |
| `OnlyLoadAppFromAsar` | disabled |
| `LoadBrowserProcessSpecificV8Snapshot` | disabled |
| `GrantFileProtocolExtraPrivileges` | enabled |
| `WasmTrapHandlers` | enabled |

Two of these decide the whole approach:

* **`EnableEmbeddedAsarIntegrityValidation` is disabled** — Electron does not verify a hash of
  `resources/app.asar`. A rebuilt payload is therefore accepted by the runtime as-is; had the
  fuse been enabled, the clone would have needed the original archive's integrity header (or a
  rebuilt Electron with the fuse off).
* **`EnableNodeCliInspectArguments` is disabled** — the Node inspector cannot be attached from
  the command line, which is exactly the `unsupported_target` reason REA reported for the active
  Electron provider. The passive CDP lane still works because it uses the browser-level
  DevTools protocol rather than the Node inspector.

The `RunAsNode` and `EnableNodeOptionsEnvironmentVariable` fuses are disabled as well, so the
runtime is hardened against `ELECTRON_RUN_AS_NODE` and `NODE_OPTIONS` injection.

---

## 5. REA static analysis

```bash
rea analyze-javascript-application ./extracted --detail summary \
    --evidence_output ./rea-evidence/obsidian-js-app.evidence.json
```

The full-application run exceeded REA's default 300 000 ms per-source budget on the bundled
CodeMirror mode table (`lib/codemirror/modes.min.js`) and returned a *partial observation*:

| Metric | Value |
| --- | --- |
| Evidence id | `ev_7a83c5f52eba7598a7a875db852102356f3702b7ebbabf149328621a685c799d` |
| Predicate | `rea.javascript-application-analysis` |
| Authority | `shipped-artifact` |
| Relevant files | 38 |
| Text bytes read | 13 715 893 |
| Parsed JavaScript files | 8 |
| Skipped JavaScript files | 24 (third-party bundles) |
| Visited AST nodes | 1 093 843 |
| Findings | 458 |
| Parse failures | 0 |
| Root artefact SHA-256 | `f88b4e915423cf4b90c1aed8cb7bb9cdf30c699c412977a945cccf26977baf9a` |
| Inventory manifest | `agm_5a5caa5a6f58a16a1e1ae0accbb56e336f7c991cbd208e3a495bd26fdac166b2` |
| Coverage | `partial` (worker timeout limit) |

The curated extract is committed as `docs/evidence/application-analysis-summary.json`.

The analysis was re-run scoped to the first-party sources only
(`--source-paths-json`, `--analysis-timeout-ms 1200000`, `--max-heap-mb 4096`), which is the
correct lane for this target: third-party bundles carry no application behaviour. That run
completed successfully (exit 0, evidence `ev_068aa2bce0bd58afe240c64aae17c7f7aff3812a738c3a639792c516a67db984`):

| Metric | First-party lane |
| --- | --- |
| Relevant files | 42 (13 selected, 29 unselected) |
| Parsed JavaScript files | 13 / 0 skipped |
| Visited AST nodes | 1 532 573 |
| Findings | 947 |
| JavaScript modules | 64 |
| Parse failures | 0 |
| Application-graph nodes | 835 (615 modules, 48 IPC channels, 48 IPC handlers, 32 endpoints, 32 assets, 10 artefacts, 7 workers, 7 storage, 29 unknowns) |
| IPC | 48 literal channels, 48 main handlers, 0 dynamic channels, 1 sender-validation observation |
| Coverage | `complete-within-view` (647/647 items examined) |

### Recovered IPC surface (48 literal channels)

`vault`, `vault-list`, `vault-open`, `vault-remove`, `vault-move`, `vault-message`,
`get-default-vault-path`, `get-sandbox-vault-path`, `open-file`, `open-url`, `request-url`,
`file-url`, `create-browser-session`, `context-menu`, `render-menu`, `set-menu`,
`update-menu-items`, `help`, `starter`, `terms`, `policy`, `resources`, `sandbox`, `frame`,
`register-cli`, `cli`, `version`, `insider-build`, `latest-public-version`, `check-update`,
`update`, `disable-update`, `disable-gpu`, `relaunch`, `is-quitting`, `is-closing`,
`documents-dir`, `desktop-dir`, `get-documents-path`, `get-icon`, `set-icon`, `print-to-pdf`,
`trash`, `copy-asar`, `plugin-script-root`, `set-language`, `adblock-lists`,
`adblock-frequency`.

This channel set is the main-process contract of the application. It also shows why the
updater had to be handled in the *launcher* rather than in the payload: `check-update`,
`update`, `latest-public-version`, `relaunch` and `disable-update` are the renderer's view of
the same update machinery the launcher drives.

The curated extracts are committed as `docs/evidence/firstparty-ipc-channels.json` and
`docs/evidence/application-analysis-summary.json`.

### REA runtime capture

```bash
rea capture-electron-scenario scenario.json --format json
```

* Against Obsidian's hardened binary → `unsupported_target`: the `EnableNodeCliInspectArguments`
  fuse is off, so active capture cannot attach (REA's own remediation suggests a stock Electron
  runtime).
* Against a **stock Electron 43.8.4** runtime with the rebuilt `app.asar` → the provider
  launches and instruments the app (the Electron inspector and the CDP endpoint come up, the
  REA hook is loaded), but Playwright's launch handshake still exceeds its 58 s budget for this
  application, so the run ends in `execution_failure` rather than a completed scenario.
* The **passive CDP lane** works and was used instead:
  `rea list-electron-targets http://127.0.0.1:9222` (evidence
  `ev_f55aa6f9f62d0be2247df246c25fe060d18d9f494200c09b1db2410457db7d5d`) reported the live
  browser identity `Chrome/150.0.7871.250`, `Electron/43.8.4`, user agent
  `obsidian/1.15.0 …`, and listed the renderer page
  `app://obsidian.md/index.html` (title `New tab - sandbox - Obsidian 1.15.0`) plus two workers.
  REA's file-page filter deliberately excludes the `app://` page (`unsupported_url: 1`),
  which independently confirms the custom-scheme architecture.

---

## 6. Theming system

Obsidian 1.15 uses a two-level token system, and the whole design is drivable from variables:

* **base ramp** — `.theme-light` / `.theme-dark` define `--color-base-00 … --color-base-100`
  (plus `--mono-0/100` and the RGB companions) and set `color-scheme`.
* **semantic tokens** — the `body { … }` block defines ~900 variables
  (`--background-primary`, `--text-normal`, `--background-modifier-border`, `--interactive-accent`,
  `--code-*`, `--tag-*`, `--link-*`, `--bases-*`, …) that reference the base ramp.
* **accent** — `--accent-h/s/l` → `hsl()` → `--color-accent{,-1,-2}`; Obsidian writes the user's
  accent choice as an **inline style on `<body>`**, so a stylesheet override needs `!important`.
* **theme selection** — the vault configuration key `theme` carries the *internal* theme names
  `obsidian` (the **dark** theme) and `moonstone` (the **light** theme), plus `system`; the
  renderer maps them onto the body classes with `theme-dark` / `theme-light`:

  ```js
  updateTheme() {
    let t = this.vault.getConfig("theme"),   // "obsidian" | "moonstone" | "system"
        e = t === "system",
        i = t === "obsidian";
    …
    document.body.toggleClass("theme-dark", i);
    document.body.toggleClass("theme-light", !i);
  }
  ```

  (the names are inverted relative to their appearance — `obsidian` is the dark theme).
  The setting lives in `<vault>/.obsidian/appearance.json`, which is what the verification
  runs switch to exercise both palettes.

Because of that structure the monochrome theme replaces the **ramp** (one place) plus the accent,
instead of overriding hundreds of component rules. Semantic status colours (`--color-red`,
`--color-green`, …) are deliberately left intact so error/success states stay legible; everything
structural becomes greyscale.

---

## 7. Clone design

| Decision | Rationale |
| --- | --- |
| Rebuild the payload from the extracted sources instead of patching the binary | produces a readable, reproducible source tree and keeps the theme change reviewable. |
| Inject the theme as a separate stylesheet (`clone-theme.css`) linked after `app.css` | the upstream stylesheet stays byte-identical, the diff stays 1 line per HTML file, and users can still override the theme later. |
| Disable the upstream auto-updater by default | an upstream update replaces the payload with the stock one and silently removes the theme. The updater code is kept and re-enabled with `OBSIDIAN_CLONE_DISABLE_UPDATE=0`. |
| Ignore a stale `obsidian-*.asar` in the user-data directory while updates are disabled | prevents an old upstream payload from hijacking the clone. |
| Add `OBSIDIAN_CLONE_USER_DATA` | lets the clone run beside an official installation (separate profile, separate single-instance lock). |
| Keep the application id, desktop file and `obsidian://` protocol handler | `x-scheme-handler/obsidian` and the `md.obsidian.Obsidian` startup class keep working, so no feature is lost. |
| Reuse the shipped Electron 43.8.4 runtime | identical runtime, identical GPU/compositor behaviour, no re-implementation risk. |
| Disable LCD subpixel text (`--disable-lcd-text`) | Chromium's RGB subpixel antialiasing paints colour fringes on every glyph edge; it was the *only* remaining colour in the window (0.27 % of pixels). With the switch the render is 100 % greyscale. |

### Payload delta (official → clone)

```
$ diff -rq extracted verify/clone-payload
Only in verify/clone-payload: clone-theme.css
Files extracted/help.html     and verify/clone-payload/help.html     differ
Files extracted/index.html    and verify/clone-payload/index.html    differ
Files extracted/starter.html  and verify/clone-payload/starter.html  differ

$ diff -u extracted/index.html verify/clone-payload/index.html
 	<link href="app.css" type="text/css" rel="stylesheet"/>
+	<link href="clone-theme.css" type="text/css" rel="stylesheet"/>

$ diff -rq launcher verify/clone-launcher
Files launcher/main.js and verify/clone-launcher/main.js differ      # the documented patch only
```

Everything else — every JS file, every style rule, every locale, every font, every bundled
library — is **byte identical** to the official release. That is the strongest available
statement of feature parity: the clone does not re-implement Obsidian, it re-packages it with a
new skin.

---

## 8. Build pipeline

```
scripts/fetch-sources.sh   download the official release, extract payload + launcher + runtime
scripts/build.sh            payload + theme -> obsidian.asar
                            launcher + patch  -> app.asar
                            Electron runtime  -> AppDir (clone/)
scripts/package.sh          AppDir -> .deb, .AppImage (runtime prefix + squashfs), .tar.gz
```

The AppImage is assembled the same way `appimagetool` does it: the ELF runtime prefix is
extracted from the official AppImage (at the squashfs magic offset) and concatenated with a
freshly built `mksquashfs` image. The result is verified with `unsquashfs -s -o <offset>`.

The launcher patch (`scripts/patch_launcher.py`) is asserted against exact anchors, so an upstream
launcher change fails the build loudly instead of producing an unpatched clone.

---

## 9. Verification

| # | Check | Method | Result |
| --- | --- | --- | --- |
| 1 | Payload parity | `diff -rq` official vs clone payload | only the 3 HTML files + the new CSS |
| 2 | Bootstrap parity | `diff -rq` official vs clone launcher | only `main.js` (documented patch) |
| 3 | Clone boots | run under Xvfb | ✅ vault opens, ribbon/explorer/tabs/editor render |
| 4 | Feature surface | screenshot of the clone | 1.15 “New note / New base / New canvas / Go to file”, ribbon, file tree, tabs |
| 5 | Updater disabled | `obsidian.log` | “Loaded main app package …”, no update check |
| 6 | Profile isolation | file system | whole profile written into the isolated user-data dir |
| 7 | Runtime independence | stock Electron 43.8.4 + rebuilt `app.asar` | identical rendering |
| 8 | Monochrome | pixel histogram of the rendered window | **0** saturated pixels out of 1 600 000 (official build: 1.08 %) — only pure black, white and greys remain |
| 9 | Token verification | computed styles read back over CDP from the running clone | light: `--background-primary: #ffffff`, `--text-normal: #000000`, `--color-accent: #000000`; dark: `#000000` / `#ffffff` / `#ffffff` — all checks pass (`scripts/verify-theme.mjs`) |
| 10 | REA observation | `rea list-electron-targets` on the live CDP endpoint | renderer page `app://obsidian.md/index.html`, `Chrome/150.0.7871.250`, `Electron/43.8.4` |
| 11 | Packaging | `unsquashfs` verification, `dpkg-deb`, AppImage execution | `.deb` installs cleanly (`ii`) and the installed binary runs; the AppImage extracts, loads the rebuilt payload and renders (0 saturated pixels); `.tar.gz` produced |
| 12 | AppImage offset | `scripts/find_squashfs_offset.py` | the squashfs superblock is found at 188 392 — the earlier `hsqs` match at 32 609 is a false positive inside the ELF runtime and truncates it |

---

## 10. Limitations and risks

* **The analysis is structural, not a re-implementation.** The clone re-packages Obsidian's own
  code; the theme is the only authored change. A from-scratch re-implementation of Obsidian's
  feature set is not achievable in this scope.
* **The first-party REA lane covers the application's own sources.** The 24 skipped third-party
  bundles were deliberately excluded from the semantic lane (they exceeded REA's per-source
  budget and carry no application behaviour).
* **Licensing.** Obsidian is proprietary (`UNLICENSED`) and Obsidian.md's terms restrict
  redistribution and modification. This repository ships only tooling and a theme; the
  application code is downloaded from the official release at build time and is not committed.
  The clone is a local interoperability/personal-use study, not a redistributable product.
* **Update channel.** Because the updater is off by default, the clone does not receive upstream
  fixes automatically; re-enable it only if the stock (unthemed) payload is acceptable.
* **The residual coloured pixels** come from upstream artwork (the Obsidian glyph, status-bar
  artwork), not from the theme's token layer.

---

## 11. Reproduction

```bash
npm install -g rea-agents
scripts/fetch-sources.sh --version 1.15.0
scripts/build.sh
scripts/run-app.sh clone clone-demo --vault "$PWD/extracted/sandbox" --seconds 25
```
