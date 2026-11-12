#!/usr/bin/env bash
# =============================================================================
# Build the Ainotes Windows x64 distribution.
#
#   scripts/build-windows.sh [--version 1.15.0] [--skip-installer]
#
# The Windows build reuses the already rebranded, cross-platform application
# payload from the Linux build (`ainotes/resources/ainotes.asar`) and replaces
# the vendor's Windows launcher, executable names, icon, version resources and
# shell integration.  Nothing is compiled; the output is:
#
#   dist/Ainotes-1.15.0-windows-x64.zip   portable, no installation
#   dist/Ainotes-Setup-1.15.0.exe         per-user NSIS installer
#
# Requirements: bash, python3 + pefile, 7z, zip, node + @electron/asar,
# NSIS (makensis), and Wine when rcedit has to run on Linux.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.15.0"
SKIP_INSTALLER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --skip-installer) SKIP_INSTALLER=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

WIN_SRC="$ROOT/windows/app64"
PAYLOAD="$ROOT/ainotes/resources/ainotes.asar"
ICON="$ROOT/assets/ainotes.ico"
REDIT="$ROOT/windows/tools/rcedit-x64.exe"
REDIT_URL="https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe"
REDIT_SHA256="3e7801db1a5edbec91b49a24a094aad776cb4515488ea5a4ca2289c400eade2a"
BUILD="$ROOT/build/windows"
OUT="$ROOT/dist"
APP="$BUILD/Ainotes"

# --- prerequisites ----------------------------------------------------------
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

python3 -c "import pefile" 2>/dev/null || {
  echo "pefile is required: python3 -m pip install pefile" >&2
  exit 1
}

command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 1; }
[[ -f "$ICON" ]] || { echo "icon missing: $ICON" >&2; exit 1; }

if [[ ! -d "$WIN_SRC" ]]; then
  log "Windows sources missing; fetching them"
  "$ROOT/scripts/fetch-windows.sh" --version "$VERSION"
fi

if [[ ! -f "$PAYLOAD" ]]; then
  log "application payload missing; building it first"
  [[ -d "$ROOT/extracted" ]] || "$ROOT/scripts/fetch-sources.sh" --version "$VERSION"
  "$ROOT/scripts/build.sh" --skip-package
fi
[[ -f "$PAYLOAD" ]] || { echo "payload missing: $PAYLOAD" >&2; exit 1; }

if [[ ! -x "$REDIT" && ! -f "$REDIT" ]]; then
  log "downloading rcedit"
  mkdir -p "$(dirname "$REDIT")"
  curl -fsSL -o "$REDIT" "$REDIT_URL"
  echo "$REDIT_SHA256  $REDIT" | sha256sum -c -
fi

if [[ "$SKIP_INSTALLER" == "0" ]]; then
  command -v makensis >/dev/null 2>&1 || {
    echo "makensis is required (install nsis)" >&2
    exit 1
  }
fi

# --- clean ------------------------------------------------------------------
log "cleaning Windows build tree"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

log "copying Windows runtime"
cp -a "$WIN_SRC" "$APP"

# --- launcher ---------------------------------------------------------------
log "patching the Windows launcher"
rm -f "$APP/resources/app.asar"
"$ASAR" extract "$WIN_SRC/resources/app.asar" "$BUILD/launcher"
python3 "$ROOT/scripts/patch_launcher.py" \
  "$BUILD/launcher/main.js" "$BUILD/launcher/package.json"
"$ASAR" pack "$BUILD/launcher" "$APP/resources/app.asar" --unpack '*.node'

# --- payload ----------------------------------------------------------------
log "installing the rebranded application payload"
# The vendor payload name is resolved at runtime so this repository keeps no
# plaintext reference to it.
VENDOR_ASAR="$(python3 -c "import sys; sys.path.insert(0, '$ROOT/scripts'); import brand; print(brand.SOURCE_LOWER + '.asar')")"
rm -f "$APP/resources/ainotes.asar" "$APP/resources/$VENDOR_ASAR"
cp "$PAYLOAD" "$APP/resources/ainotes.asar"
cp "$ROOT/assets/ainotes.png" "$APP/resources/icon.png"

# --- executables ------------------------------------------------------------
log "rebranding executables and refreshing the asar integrity manifest"
export WINEDEBUG="${WINEDEBUG:--all}"
python3 "$ROOT/scripts/patch_windows.py" "$APP" "$ICON" "$REDIT"

log "checking the Windows tree for vendor brand tokens"
python3 "$ROOT/scripts/check_brand.py" "$APP"

# --- portable zip -----------------------------------------------------------
ZIP="$OUT/Ainotes-${VERSION}-windows-x64.zip"
log "packing portable zip"
rm -f "$ZIP"
(cd "$BUILD" && zip -qr "$ZIP" Ainotes)
du -h "$ZIP"

# --- installer --------------------------------------------------------------
if [[ "$SKIP_INSTALLER" == "0" ]]; then
  SETUP="$OUT/Ainotes-Setup-${VERSION}.exe"
  log "building the per-user installer"
  rm -f "$SETUP"
  makensis -V2 \
    -DAPPDIR="$APP" \
    -DOUTFILE="$SETUP" \
    -DVERSION="$VERSION" \
    -DICON="$ICON" \
    "$ROOT/scripts/installer.nsi"
  du -h "$SETUP"
fi

log "Windows distribution ready"
ls -lh "$OUT"/*windows* "$OUT"/Ainotes-Setup-*.exe 2>/dev/null || true
