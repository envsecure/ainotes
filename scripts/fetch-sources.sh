#!/usr/bin/env bash
# =============================================================================
# Fetch the official Obsidian Linux release and extract everything the clone
# build needs.  Nothing proprietary is stored in this repository - the
# upstream release artefacts are downloaded on demand.
#
#   scripts/fetch-sources.sh [--version 1.15.0]
#
# Produces
#   original/Obsidian-<v>.AppImage          official AppImage (Electron runtime)
#   original/obsidian-<v>.asar.gz           official application payload
#   extracted/                              payload extracted to a directory
#   launcher/                               Electron bootstrap (app.asar)
#   appimage-extract/squashfs-root/         unpacked AppImage runtime
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.15.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
BASE="https://github.com/obsidianmd/obsidian-releases/releases/download/v${VERSION}"

mkdir -p "$ROOT/original" "$ROOT/appimage-extract"

if [[ ! -f "$ROOT/original/Obsidian-${VERSION}.AppImage" ]]; then
  log "downloading Obsidian ${VERSION} AppImage"
  curl -L --fail -o "$ROOT/original/Obsidian-${VERSION}.AppImage" \
    "$BASE/Obsidian-${VERSION}.AppImage"
fi

if [[ ! -f "$ROOT/original/obsidian-${VERSION}.asar.gz" ]]; then
  log "downloading Obsidian ${VERSION} application payload"
  curl -L --fail -o "$ROOT/original/obsidian-${VERSION}.asar.gz" \
    "$BASE/obsidian-${VERSION}.asar.gz"
fi

log "extracting application payload"
gunzip -kf "$ROOT/original/obsidian-${VERSION}.asar.gz"

ASAR="$ROOT/node_modules/.bin/asar"
if [[ ! -x "$ASAR" ]]; then
  log "installing @electron/asar"
  (cd "$ROOT" && npm install --silent --no-save @electron/asar >/dev/null 2>&1)
  ASAR="$ROOT/node_modules/.bin/asar"
fi

rm -rf "$ROOT/extracted"
mkdir -p "$ROOT/extracted"
"$ASAR" extract "$ROOT/original/obsidian-${VERSION}.asar" "$ROOT/extracted"

log "unpacking AppImage runtime"
if [[ ! -d "$ROOT/appimage-extract/squashfs-root" ]]; then
  (cd "$ROOT/appimage-extract" && "$ROOT/original/Obsidian-${VERSION}.AppImage" --appimage-extract >/dev/null)
fi

log "extracting Electron bootstrap"
rm -rf "$ROOT/launcher"
mkdir -p "$ROOT/launcher"
"$ASAR" extract "$ROOT/appimage-extract/squashfs-root/resources/app.asar" "$ROOT/launcher"

log "sources ready"
du -sh "$ROOT/original" "$ROOT/extracted" "$ROOT/launcher" "$ROOT/appimage-extract"
