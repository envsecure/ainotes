# Architecture

Ainotes is a thin, deterministic build layer around a fetched Electron
application payload. The repository owns the rebrand, the theme, the packaging
and the verification; it does not own or redistribute the application payload.

## Build stages

```
vendor AppImage ──► Electron/Chromium runtime ──┐
                                                ├──► patch_runtime.py ──┐
vendor payload  ──► extracted payload ──────────┘                       │
                        │                                              ├──► ainotes/ AppDir
                        ├──► patch_payload.py ──► + theme ──► asar ────┤
                        │                                              │
launcher app.asar ──────┴──► patch_launcher.py ──► app.asar ───────────┘
                                                                       │
                                                                       ├──► .deb
                                                                       ├──► AppImage
                                                                       └──► .tar.gz
```

### 1. Fetch

`scripts/fetch-sources.sh` resolves the vendor release through the vendor
repository's stable numeric GitHub id and the release tag. It downloads the
Linux runtime image and the compressed application payload, then extracts:

* `extracted/` — payload files;
* `launcher/` — the Electron bootstrap from the runtime's `app.asar`;
* `appimage-extract/squashfs-root/` — the runtime tree.

Nothing in this stage is committed. `GITHUB_TOKEN` is optional and only
avoids anonymous API rate limits.

### 2. Rebrand the payload

`scripts/patch_payload.py` copies nothing itself; `build.sh` gives it the
build copy. It rewrites the following text formats:

`*.js`, `*.mjs`, `*.html`, `*.css`, `*.json`, `*.md`, `*.txt`, `*.xml`,
`*.svg`

and renames any path that contains the old brand. Because the replacement is
mechanical, related identifiers move together:

| Surface | Examples |
| --- | --- |
| Renderer origin | `app://<name>.md/` |
| Custom scheme | `<name>://open?vault=…` |
| Profile | `~/.config/<name>/` |
| Vault registry | `<name>.json` |
| Vault config | `.<name>/` |
| MIME types | `application/x-<name>-canvas`, `application/x-<name>-base` |
| Theme id | `<name>` (dark) / `moonstone` (light) |
| Editor classes | `cm-s-<name>`, `<name>-search-match-highlight` |
| CLI | `<name>-cli`, `.<name>-cli.sock` |
| Sample vault | file names and wiki links |

The payload's own `package.json`, HTML titles, locale files and bundled library
strings are covered by the same pass.

### 3. Patch the launcher

The launcher is the Electron bootstrap that registers the privileged scheme,
loads the payload and contains the update path. `scripts/patch_launcher.py`:

* renames the launcher package (`name`, `description`, `author`,
  `desktopName`);
* disables the update timer/startup check unless
  `AINOTES_DISABLE_UPDATE=0`;
* adds `AINOTES_USER_DATA` for an isolated profile;
* appends `--disable-lcd-text` so Chromium does not paint RGB fringes on
  monochrome glyph edges;
* rebrands every remaining launcher string.

The launcher is packed to `resources/app.asar`. The payload is packed to
`resources/ainotes.asar`.

### 4. Patch the runtime

`scripts/patch_runtime.py` operates on the copied runtime tree:

* the Electron executable is renamed to `ainotes`;
* the CLI helper is renamed to `ainotes-cli`;
* desktop entry → `ainotes.desktop`, with the new name, icon, MIME types,
  URL scheme and window class;
* MIME database entry → `usr/share/mime/packages/ainotes.xml`;
* every icon size is regenerated from `assets/ainotes.png`;
* `AppRun` points at the renamed executable;
* `.DirIcon` and the root icon symlink point at the 512 px icon.

The Electron/Chromium runtime is reused unchanged apart from launcher identity
strings: the CLI socket/message literals, the Flatpak application id it looks
up, and one Bluetooth manufacturer label embedded in Chromium's device
database. Each replacement is length-checked and NUL-padded in place, so the
ELF layout is untouched.

### 5. Theme

`theme/ainotes-theme.css` is copied into the payload and linked after the
application stylesheet in `index.html`, `starter.html` and `help.html`. The
build appends a forced palette when `--variant=light` or `--variant=dark` is
requested.

### 6. Package

`scripts/package.sh` produces:

* a Debian package rooted at `/usr/lib/ainotes` with a `/usr/bin/ainotes`
  wrapper;
* an AppImage assembled from the vendor runtime prefix plus a fresh squashfs;
* a tarball containing the AppDir.

## Runtime layout

| Path | Purpose |
| --- | --- |
| `ainotes/ainotes` | Electron/Chromium executable |
| `ainotes/ainotes-cli` | command-line helper |
| `ainotes/AppRun` | AppImage entry point |
| `ainotes/resources/app.asar` | patched launcher |
| `ainotes/resources/ainotes.asar` | rebranded payload |
| `ainotes/ainotes.desktop` | desktop entry |
| `~/.config/ainotes/ainotes.json` | vault registry |
| `<vault>/.ainotes/` | per-vault configuration |
| `<vault>/.trash/` | trash |

## Verification

`scripts/feature-audit.mjs` drives the live renderer over the Chrome DevTools
Protocol. It covers the vault, file tree, core plugins, commands, settings,
metadata cache, resolved/unresolved links, search, graph, canvas, bases,
outline, switcher, properties, templates, daily notes, bookmarks, file
explorer, page preview, word count, outgoing links, tags, note composer,
command palette, file CRUD, link resolution, theme switching, the editor,
ribbon, status bar and monochrome rendering.

`scripts/verify-theme.mjs` reads computed CSS tokens and asserts pure
black/white surfaces, zero accent saturation and no shadows.

The build pipeline is deterministic: the fetched sources are never modified,
and the three patch scripts are the only transforms applied to the build copy.
