# Ainotes — minimal monochrome notes for Linux and Windows

Ainotes is a desktop notes application with a **minimal white/black monochrome
theme**. It is assembled from a vendor application payload that is downloaded
at build time, then rebranded and themed by this repository.

Every application feature is preserved. The build changes three things:

1. **Identity** — the payload, launcher, runtime, packages, profile paths,
   URL scheme, MIME types, icons and sample vault are rebranded to Ainotes.
2. **Colour** — a monochrome palette replaces the stock light/dark themes.
3. **Update channel** — the self-updater is disabled by default, because an
   update would replace the themed payload with the stock one.

```
vendor AppImage ──┐
                  ├──► runtime + payload ──► rebrand ──► + monochrome theme ──► AppDir
vendor payload ───┘                                      ▲
                                                          │
                             launcher (app.asar) ─────────┘
                             patched: updater off, optional isolated data
```

| Light | Dark |
| --- | --- |
| ![Ainotes light](docs/screenshots/ainotes-light.png) | ![Ainotes dark](docs/screenshots/ainotes-dark.png) |

---

## 1. Install

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/envsecure/ainotes/main/scripts/install.sh | sh
```

The script installs per user (no root rights needed): the application is
unpacked into `~/.local/share/ainotes`, a launcher is written to
`~/.local/bin/ainotes` and a menu entry is created. Options:

```bash
... | sh -- --system     # install system-wide into /usr/local
... | sh -- --appimage   # install the AppImage instead of the tarball
... | sh -- --deb        # install the Debian/Ubuntu package instead
... | sh -- --uninstall  # remove a previous installation
```

### Windows

```powershell
irm https://raw.githubusercontent.com/envsecure/ainotes/main/scripts/install.ps1 | iex
```

The script downloads the per-user installer, runs it silently and starts
Ainotes. No administrator rights are required — everything is installed below
`%LOCALAPPDATA%\Programs\Ainotes`, with a Start-menu entry, a desktop
shortcut and the `ainotes://` protocol registered. Use `-NoLaunch` to skip
starting the application and `-Uninstall` to remove it again.

### Manual downloads

| File | Platform | Notes |
| --- | --- | --- |
| `ainotes-linux-x86_64.tar.gz` | Linux x86-64 | portable, unpack and run |
| `ainotes-linux-x86_64.AppImage` | Linux x86-64 | portable single file |
| `ainotes-linux-x86_64.deb` | Debian / Ubuntu | native package |
| `ainotes-windows-x86_64.zip` | Windows x86-64 | portable, no installation |
| `Ainotes-Setup.exe` | Windows x86-64 | per-user installer |

```bash
# Debian / Ubuntu
sudo apt install ./ainotes-linux-x86_64.deb && ainotes

# Linux, portable
chmod +x ainotes-linux-x86_64.AppImage && ./ainotes-linux-x86_64.AppImage
```

`SHA256SUMS` in the release lists the checksum of every file.

---

## 2. Build

### Linux

```bash
# 1. fetch the vendor release (nothing proprietary is stored in this repo)
GITHUB_TOKEN=... scripts/fetch-sources.sh --version 1.15.0

# 2. build Ainotes
scripts/build.sh                      # -> ainotes/ (AppDir) + dist/
scripts/build.sh --variant=dark       # pin the black palette
scripts/build.sh --skip-package       # AppDir only (fast)
```

`GITHUB_TOKEN` is optional but recommended: the fetch script resolves the
release through GitHub's API, and an authenticated request avoids the
anonymous rate limit.

| Artefact | Path |
| --- | --- |
| Portable AppDir | `ainotes/` |
| Debian package | `dist/ainotes_1.15.0_amd64.deb` |
| AppImage | `dist/Ainotes-1.15.0.AppImage` |
| Tarball | `dist/ainotes-1.15.0-linux-amd64.tar.gz` |

The AppImage is assembled the same way `appimagetool` does it: the ELF runtime
prefix of the official AppImage plus a freshly built squashfs. On systems
without FUSE, run it with
`APPIMAGE_EXTRACT_AND_RUN=1 ./Ainotes-1.15.0.AppImage`.

### Windows

The Windows build reuses the rebranded, cross-platform payload from the Linux
build and replaces the vendor's Windows launcher, executables, icon, version
resources and shell integration.

```bash
# 1. fetch the vendor's Windows runtime
GITHUB_TOKEN=... scripts/fetch-windows.sh --version 1.15.0

# 2. build the Windows distribution
scripts/build-windows.sh
```

| Artefact | Path |
| --- | --- |
| Portable archive | `dist/Ainotes-1.15.0-windows-x64.zip` |
| Per-user installer | `dist/Ainotes-Setup-1.15.0.exe` |

Requirements: `python3` with `pefile`, `zip`, `7z`, NSIS (`makensis`) and Wine
(rcedit is a Windows program). On a Windows host `rcedit` runs natively and
`makensis` ships with NSIS.

### Run from the source tree

```bash
ainotes/ainotes --no-sandbox
```

---

## 3. Rebrand pipeline

The build keeps the fetched sources pristine and applies deterministic
patchers to the build copy.

### Payload — `scripts/patch_payload.py`

Rewrites every text asset in the application payload (main process, renderer,
stylesheets, locales, HTML entry points, bundled libraries and the sample
vault) and renames any file or directory whose name carries the old brand.
The rewrite is mechanical, so every internal reference stays consistent:

* window and document titles, menus, About panel, settings text and locale
  strings;
* the `app://` renderer origin, the custom URL scheme, MIME types and the
  desktop-entry integration;
* the profile directory, vault registry, vault config directory and CLI
  socket/log paths;
* theme ids, editor CSS classes and the self-referential links in the sample
  vault.

### Launcher — `scripts/patch_launcher.py`

Patches the thin Electron bootstrap that loads the payload:

* disables the update path by default (`AINOTES_DISABLE_UPDATE=0` re-enables
  it);
* supports an isolated profile (`AINOTES_USER_DATA=/path`);
* disables LCD subpixel antialiasing, which would otherwise paint coloured
  fringes on glyph edges;
* rebrands the launcher package metadata and every remaining reference.

### Runtime — `scripts/patch_runtime.py`

Renames the Electron executable and CLI helper, rebuilds the desktop entry and
MIME database entry, replaces every icon size with the Ainotes icon, updates
the AppImage `AppRun` wrapper, and rewrites the CLI socket/message literals so
the helper and the payload agree.

### Windows — `scripts/patch_windows.py`

The Windows runtime is a separate Electron build, so it needs its own pass:

* the GUI executable and the console shim become `Ainotes.exe` and
  `Ainotes.com`;
* the version resources are rewritten (company, product, description,
  copyright, internal and original file name) and the icon is replaced with
  `assets/ainotes.ico`;
* the brand strings compiled into the two PE files (the CLI message, the CLI
  pipe name, one Chromium device label, two native-module debug paths) are
  patched in place, length-checked and NUL-padded;
* Electron's embedded asar integrity manifest is refreshed with the new file
  names and SHA-256 hashes, so the payload stays verifiable;
* the now invalid vendor signature is removed.

### Theme — `theme/ainotes-theme.css`

The theme is linked after the application stylesheet in `index.html`,
`starter.html` and `help.html`. It works on the application's design tokens
rather than overriding individual components:

* the whole `--color-base-00 … --color-base-100` ramp is replaced by a pure
  greyscale ramp, so every semantic token follows automatically;
* the accent colour is forced to pure black or pure white;
* shadows are removed, radii are reduced to 2–4 px, and icons, tags, code,
  tables, callouts, menus, tooltips, graphs and canvas chrome are recoloured;
* syntax highlighting is greyscale instead of multi-coloured.

Two palettes are shipped and both are strictly monochrome:

| Variant | Background | Text |
| --- | --- | --- |
| `light` | `#ffffff` | `#000000` |
| `dark` | `#000000` | `#ffffff` |

`--variant=both` (default) keeps the application's own light/dark setting and
makes both themes monochrome. `--variant=light` or `--variant=dark` pins one
palette for both theme classes.

---

## 4. Verification

| Check | Result |
| --- | --- |
| Feature audit | **51/51** checks return a result on the running build (vault, file tree, core plugins, commands, settings, metadata cache, links, search, graph, canvas, bases, outline, switcher, properties, templates, daily notes, bookmarks, file explorer, page preview, word count, outgoing links, tags, note composer, command palette, file CRUD, link resolution, theme switching, editor, ribbon, monochrome DOM). |
| Monochrome tokens | `scripts/verify-theme.mjs` passes the light and dark palettes: pure `#ffffff`/`#000000` backgrounds and text, 0 % accent saturation, no shadows. |
| Brand scan | The extracted payload, launcher and the complete Windows tree contain no case-insensitive upstream brand token (ASCII and UTF-16). |
| Runtime identity | Window class `ainotes`/`Ainotes`, origin `app://ainotes.md`, profile `~/.config/ainotes` (Linux) and `%APPDATA%\ainotes` (Windows), vault config `.ainotes`, user agent `ainotes/1.15.0`. |
| Packaging | `.deb`, AppImage, tarball, Windows zip and Windows installer build; the AppImage squashfs offset is re-validated with `unsquashfs`. |
| Windows runtime | The packaged Windows build starts, loads `resources/ainotes.asar` and creates its profile below `%APPDATA%\ainotes` under Wine. |

Run the audits against a live build:

```bash
# start Ainotes with a CDP port and a seeded vault
scripts/run-app.sh ainotes verify --vault /path/to/vault --seconds 25 \
  --args --remote-debugging-port=9222 &

node scripts/feature-audit.mjs --cdp http://127.0.0.1:9222
node scripts/verify-theme.mjs --cdp http://127.0.0.1:9222 --expect light
node scripts/verify-theme.mjs --cdp http://127.0.0.1:9222 --expect dark
```

The theme follows the application's theme setting; no code change is needed
to switch palettes.

---

## 5. Runtime switches

| Variable | Effect |
| --- | --- |
| `AINOTES_USER_DATA=/path` | Run against an isolated user-data directory. |
| `AINOTES_DISABLE_UPDATE=0` | Re-enable the update path (disabled by default). |

---

## 6. Repository layout

```
assets/ainotes.png             application icon
assets/ainotes.ico             Windows icon
theme/ainotes-theme.css        the monochrome theme
scripts/fetch-sources.sh       download + extract the vendor release
scripts/fetch-windows.sh       download + extract the vendor Windows release
scripts/patch_payload.py       rebrand every payload asset and path
scripts/patch_launcher.py      launcher patch (updater, isolated data, brand)
scripts/patch_runtime.py       rename runtime binaries, desktop entry, icons
scripts/patch_windows.py       rebrand the Windows executables and resources
scripts/build.sh               build the AppDir and packages
scripts/package.sh             .deb / .AppImage / .tar.gz
scripts/build-windows.sh       Windows zip + NSIS installer
scripts/installer.nsi          per-user Windows installer definition
scripts/install.sh             Linux one-line installer
scripts/install.ps1            Windows one-line installer
scripts/run-app.sh             run an AppDir under Xvfb and screenshot it
scripts/feature-audit.mjs      in-app feature battery over CDP
scripts/verify-theme.mjs       computed-token monochrome assertions
docs/ARCHITECTURE.md           build and runtime architecture
docs/RELEASE-NOTES.md          release notes template
docs/screenshots/              light and dark renders
```

Fetched artefacts (`original/`, `extracted/`, `launcher/`, `windows/`,
`appimage-extract/`) and build output (`ainotes/`, `build/`, `dist/`) are not
committed.

---

## 7. Releases

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds the
Linux and Windows artefacts, publishes them under stable names and writes
`SHA256SUMS`. The installers in `scripts/install.sh` and
`scripts/install.ps1` always fetch the newest release.
