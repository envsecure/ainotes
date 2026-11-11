#!/usr/bin/env bash
# =============================================================================
# Build "Obsidian Clone" — a from-source rebuild of the Obsidian 1.15.0 Linux
# application with a minimal monochrome (white/black) theme.
#
#   scripts/build.sh [--variant=both|light|dark] [--skip-package]
#
# Pipeline
#   1. payload  : extracted app payload + monochrome theme -> obsidian.asar
#   2. launcher : patched Electron bootstrap        -> app.asar
#   3. runtime  : Electron 43.8.4 runtime           -> AppDir
#   4. package  : .deb / .AppImage / .tar.gz
#
# Everything is reproducible from the files in ./original and ./extracted.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAYLOAD_SRC="$ROOT/extracted"
LAUNCHER_SRC="$ROOT/launcher"
RUNTIME_SRC="$ROOT/appimage-extract/squashfs-root"
THEME_SRC="$ROOT/theme/clone-theme.css"
BUILD="$ROOT/build"
OUT="$ROOT/clone"
DIST="$ROOT/dist"
VARIANT="both"
SKIP_PACKAGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant=*) VARIANT="${1#*=}"; shift ;;
    --skip-package) SKIP_PACKAGE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$VARIANT" in
  both|light|dark) ;;
  *) echo "invalid --variant: $VARIANT (use both|light|dark)" >&2; exit 2 ;;
esac

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# --- toolchain --------------------------------------------------------------
ASAR=""
if [[ -x "$ROOT/node_modules/.bin/asar" ]]; then
  ASAR="$ROOT/node_modules/.bin/asar"
elif command -v asar >/dev/null 2>&1; then
  ASAR="$(command -v asar)"
else
  log "installing @electron/asar"
  (cd "$ROOT" && npm install --silent --no-save @electron/asar >/dev/null 2>&1)
  ASAR="$ROOT/node_modules/.bin/asar"
fi

# --- clean ------------------------------------------------------------------
log "cleaning build tree"
rm -rf "$BUILD" "$OUT" "$DIST"
mkdir -p "$BUILD/payload" "$BUILD/launcher" "$OUT/resources" "$DIST"

# --- 1. payload + theme -----------------------------------------------------
log "copying application payload"
cp -a "$PAYLOAD_SRC/." "$BUILD/payload/"

log "applying monochrome theme (variant=$VARIANT)"
cp "$THEME_SRC" "$BUILD/payload/clone-theme.css"

# Force one palette on both theme classes when a single variant is requested.
case "$VARIANT" in
  light)
    cat >> "$BUILD/payload/clone-theme.css" <<'CSS'

/* Forced light variant: the white palette is used for both theme classes. */
.theme-dark {
	color-scheme: light;
	--m-bg: #ffffff;
	--m-bg-alt: #fafafa;
	--m-bg-2: #f4f4f4;
	--m-bg-3: #ebebeb;
	--m-border: #e2e2e2;
	--m-border-strong: #c4c4c4;
	--m-fg: #000000;
	--m-fg-muted: #4a4a4a;
	--m-fg-faint: #8a8a8a;
	--m-hover: rgba(0, 0, 0, 0.045);
	--m-active: rgba(0, 0, 0, 0.09);
	--m-selection: rgba(0, 0, 0, 0.12);
	--m-accent: #000000;
	--m-on-accent: #ffffff;
	--m-shadow: rgba(0, 0, 0, 0.1);
	--accent-l: 0% !important;
	--color-accent: #000000 !important;
	--color-accent-1: #000000 !important;
	--color-accent-2: #000000 !important;
}
CSS
    ;;
  dark)
    cat >> "$BUILD/payload/clone-theme.css" <<'CSS'

/* Forced dark variant: the black palette is used for both theme classes. */
.theme-light {
	color-scheme: dark;
	--m-bg: #000000;
	--m-bg-alt: #0c0c0c;
	--m-bg-2: #131313;
	--m-bg-3: #1c1c1c;
	--m-border: #262626;
	--m-border-strong: #3d3d3d;
	--m-fg: #ffffff;
	--m-fg-muted: #b0b0b0;
	--m-fg-faint: #757575;
	--m-hover: rgba(255, 255, 255, 0.055);
	--m-active: rgba(255, 255, 255, 0.11);
	--m-selection: rgba(255, 255, 255, 0.16);
	--m-accent: #ffffff;
	--m-on-accent: #000000;
	--m-shadow: rgba(0, 0, 0, 0.65);
	--accent-l: 100% !important;
	--color-accent: #ffffff !important;
	--color-accent-1: #ffffff !important;
	--color-accent-2: #ffffff !important;
}
CSS
    ;;
esac

# Link the theme after Obsidian's own stylesheet in every HTML entry point.
python3 - "$BUILD/payload" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
link = '<link href="clone-theme.css" type="text/css" rel="stylesheet"/>'
patched = []
for html in sorted(root.glob("*.html")):
    text = html.read_text(encoding="utf-8")
    if "clone-theme.css" in text:
        continue
    if "app.css" not in text:
        continue
    new = re.sub(
        r'(<link href="app\.css"[^>]*/>)',
        r'\1\n\t' + link,
        text,
        count=1,
    )
    if new != text:
        html.write_text(new, encoding="utf-8")
        patched.append(html.name)
print("theme linked into:", ", ".join(patched) or "(none)")
PY

# --- 2. launcher ------------------------------------------------------------
log "copying and patching launcher"
cp -a "$LAUNCHER_SRC/." "$BUILD/launcher/"
python3 "$ROOT/scripts/patch_launcher.py" "$BUILD/launcher/main.js"

log "packing launcher -> resources/app.asar"
"$ASAR" pack "$BUILD/launcher" "$OUT/resources/app.asar" --unpack "*.node"

# --- 3. runtime -------------------------------------------------------------
log "copying Electron 43.8.4 runtime"
cp -a "$RUNTIME_SRC/." "$OUT/"
rm -rf "$OUT/resources"
mkdir -p "$OUT/resources"
cp "$RUNTIME_SRC/resources/icon.png" "$OUT/resources/" 2>/dev/null || true

# re-create the two archives (the runtime copy above restores the originals)
"$ASAR" pack "$BUILD/payload" "$OUT/resources/obsidian.asar"
"$ASAR" pack "$BUILD/launcher" "$OUT/resources/app.asar" --unpack "*.node"

chmod +x "$OUT/obsidian" "$OUT/AppRun" "$OUT/chrome-sandbox" 2>/dev/null || true
chmod 4755 "$OUT/chrome-sandbox" 2>/dev/null || true

cat > "$OUT/.obsidian-clone" <<EOF
obsidian-clone
version=1.15.0
variant=$VARIANT
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "clone AppDir ready at $OUT"
du -sh "$OUT"
ls -la "$OUT/resources"

if [[ "$SKIP_PACKAGE" == "1" ]]; then
  log "skipping packaging (--skip-package)"
  exit 0
fi

# --- 4. packaging -----------------------------------------------------------
"$ROOT/scripts/package.sh" --root "$ROOT" --outdir "$DIST"

log "build complete"
ls -la "$DIST"
