#!/usr/bin/env bash
# =============================================================================
# Fetch the vendor's Windows release and extract the x64 application tree.
#
#   GITHUB_TOKEN=... scripts/fetch-windows.sh [--version 1.15.0]
#
# Produces
#   original/Ainotes-<v>.exe     vendor installer (never committed)
#   windows/app64/               x64 Electron runtime + payload + launcher
#
# The release is addressed through the vendor repository's stable numeric
# GitHub id, so this script does not depend on the vendor's display name.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.15.0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) VERSION="${1#*=}"; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }

REPO_ID=262342594
API_ROOT="https://api.github.com/repositories/${REPO_ID}"
AUTH=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

INSTALLER="$ROOT/original/Ainotes-${VERSION}.exe"
APP="$ROOT/windows/app64"

mkdir -p "$ROOT/original" "$ROOT/windows"

if [[ ! -f "$INSTALLER" ]]; then
  log "resolving Windows release ${VERSION}"
  TMP="$(mktemp)"
  trap 'rm -f "$TMP"' EXIT
  if ! curl -fsSL "${AUTH[@]}" -o "$TMP" "${API_ROOT}/releases/tags/v${VERSION}"; then
    echo "could not resolve release ${VERSION}; set GITHUB_TOKEN to avoid anonymous rate limits" >&2
    exit 1
  fi
  ASSET_ID="$(python3 - "$TMP" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.endswith(".exe") and "blockmap" not in name:
        print(int(asset["id"]))
        break
else:
    raise SystemExit("no .exe asset in release")
PY
)"
  log "downloading Windows installer ${VERSION}"
  curl -L --fail "${AUTH[@]}" \
    -H "Accept: application/octet-stream" \
    -o "$INSTALLER" "${API_ROOT}/releases/assets/${ASSET_ID}"
fi

if [[ ! -d "$APP" ]]; then
  command -v 7z >/dev/null 2>&1 || { echo "7z is required to extract the Windows installer" >&2; exit 1; }
  log "extracting x64 application tree"
  rm -rf "$ROOT/windows/app64" "$ROOT/windows/.payload"
  mkdir -p "$ROOT/windows/.payload"
  7z x -y -o"$ROOT/windows/.payload" "$INSTALLER" '$PLUGINSDIR/app-64.7z' >/dev/null
  7z x -y -o"$APP" "$ROOT/windows/.payload/\$PLUGINSDIR/app-64.7z" >/dev/null
  rm -rf "$ROOT/windows/.payload"
fi

log "Windows sources ready"
du -sh "$INSTALLER" "$APP"
