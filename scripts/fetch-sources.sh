#!/usr/bin/env bash
# =============================================================================
# Fetch the vendor's Linux release and extract everything the Ainotes build
# needs.  Nothing proprietary is stored in this repository - the release
# artefacts are downloaded on demand from the vendor's public release
# endpoint.
#
# The endpoint is addressed through the vendor repository's stable numeric
# GitHub id and the release tag, so the script does not depend on the
# vendor's display name.  Asset names are discovered from the release
# metadata; only the platform suffix is used to select them.
#
#   GITHUB_TOKEN=... scripts/fetch-sources.sh [--version 1.15.0]
#
# Produces
#   original/Ainotes-<v>.AppImage          Electron runtime source
#   original/ainotes-<v>.asar.gz           application payload (gzip)
#   extracted/                             payload extracted to a directory
#   launcher/                              Electron bootstrap (app.asar)
#   appimage-extract/squashfs-root/        unpacked AppImage runtime
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.15.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

# Stable numeric id of the vendor repository on GitHub.
REPO_ID=262342594
API_ROOT="https://api.github.com/repositories/${REPO_ID}"
AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

mkdir -p "$ROOT/original" "$ROOT/appimage-extract"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

log "resolving release ${VERSION}"
if ! curl -fsSL "${AUTH[@]}" -o "$TMP" "${API_ROOT}/releases/tags/v${VERSION}"; then
  echo "could not resolve release ${VERSION}; set GITHUB_TOKEN to avoid anonymous rate limits" >&2
  exit 1
fi

read -r APPIMAGE_ID ASAR_ID < <(python3 - "$TMP" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assets = data.get("assets", [])

def pick(suffix: str, exclude: str = "") -> int:
    for asset in assets:
        name = asset.get("name", "")
        if name.endswith(suffix) and (not exclude or exclude not in name):
            return int(asset["id"])
    raise SystemExit(f"no asset ending in {suffix!r} in release")

print(pick(".AppImage", "arm64"), pick(".asar.gz"))
PY
)

[[ -n "${APPIMAGE_ID:-}" && -n "${ASAR_ID:-}" ]] || {
  echo "release metadata did not contain the expected assets" >&2
  exit 1
}

download_asset() {
  local asset_id="$1" target="$2"
  if [[ ! -f "$target" ]]; then
    curl -L --fail "${AUTH[@]}" \
      -H "Accept: application/octet-stream" \
      -o "$target" "${API_ROOT}/releases/assets/${asset_id}"
  fi
}

download_asset "$APPIMAGE_ID" "$ROOT/original/Ainotes-${VERSION}.AppImage"
download_asset "$ASAR_ID" "$ROOT/original/ainotes-${VERSION}.asar.gz"

log "extracting application payload"
gunzip -kf "$ROOT/original/ainotes-${VERSION}.asar.gz"

ASAR="$ROOT/node_modules/.bin/asar"
if [[ ! -x "$ASAR" ]]; then
  log "installing @electron/asar"
  (cd "$ROOT" && npm install --silent --no-save @electron/asar >/dev/null 2>&1)
  ASAR="$ROOT/node_modules/.bin/asar"
fi

rm -rf "$ROOT/extracted"
mkdir -p "$ROOT/extracted"
"$ASAR" extract "$ROOT/original/ainotes-${VERSION}.asar" "$ROOT/extracted"

log "unpacking AppImage runtime"
chmod +x "$ROOT/original/Ainotes-${VERSION}.AppImage"
if [[ ! -d "$ROOT/appimage-extract/squashfs-root" ]]; then
  (cd "$ROOT/appimage-extract" && "$ROOT/original/Ainotes-${VERSION}.AppImage" --appimage-extract >/dev/null)
fi

log "extracting Electron bootstrap"
rm -rf "$ROOT/launcher"
mkdir -p "$ROOT/launcher"
"$ASAR" extract "$ROOT/appimage-extract/squashfs-root/resources/app.asar" "$ROOT/launcher"

log "sources ready"
du -sh "$ROOT/original" "$ROOT/extracted" "$ROOT/launcher" "$ROOT/appimage-extract"
