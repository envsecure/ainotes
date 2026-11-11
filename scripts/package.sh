#!/usr/bin/env bash
# =============================================================================
# Package the Obsidian Clone AppDir into Linux installables.
#
#   scripts/package.sh --root <project-root> --outdir <dist-dir>
#
# Produces
#   obsidian-clone_1.15.0_amd64.deb     native package
#   ObsidianClone-1.15.0.AppImage        portable single file
#   obsidian-clone-1.15.0-linux-amd64.tar.gz
# =============================================================================
set -euo pipefail

ROOT=""
OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ROOT" && -n "$OUTDIR" ]] || { echo "--root and --outdir are required" >&2; exit 2; }

APPDIR="$ROOT/clone"
BUILD="$ROOT/build"
ORIG_APPIMAGE="$ROOT/original/Obsidian-1.15.0.AppImage"
VERSION="1.15.0"

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
[[ -d "$APPDIR" ]] || { echo "AppDir missing: $APPDIR (run scripts/build.sh first)" >&2; exit 1; }
mkdir -p "$OUTDIR"

# --- .deb -------------------------------------------------------------------
log "building .deb"
DEBROOT="$BUILD/deb"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN" \
         "$DEBROOT/usr/lib/obsidian-clone" \
         "$DEBROOT/usr/bin" \
         "$DEBROOT/usr/share/applications" \
         "$DEBROOT/usr/share/icons/hicolor/512x512/apps"

cp -a "$APPDIR/." "$DEBROOT/usr/lib/obsidian-clone/"
chmod 0755 "$DEBROOT/usr/lib/obsidian-clone/obsidian"
chmod 4755 "$DEBROOT/usr/lib/obsidian-clone/chrome-sandbox" 2>/dev/null || true

cat > "$DEBROOT/usr/bin/obsidian-clone" <<'EOF'
#!/bin/sh
APPDIR=/usr/lib/obsidian-clone
export PATH="$APPDIR:$PATH"
export LD_LIBRARY_PATH="$APPDIR:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$APPDIR/obsidian" --no-sandbox "$@"
EOF
chmod 0755 "$DEBROOT/usr/bin/obsidian-clone"

cat > "$DEBROOT/usr/share/applications/obsidian-clone.desktop" <<'EOF'
[Desktop Entry]
Name=Obsidian Clone
Exec=obsidian-clone --no-sandbox %U
Terminal=false
Type=Application
Icon=obsidian-clone
StartupWMClass=md.obsidian.Obsidian
X-AppImage-Version=1.15.0
Comment=Obsidian Clone - minimal monochrome rebuild
MimeType=application/pdf;text/markdown;application/x-obsidian-canvas;application/x-obsidian-base;x-scheme-handler/obsidian;
Categories=Office;
EOF

if [[ -f "$APPDIR/usr/share/icons/hicolor/512x512/apps/obsidian.png" ]]; then
  cp "$APPDIR/usr/share/icons/hicolor/512x512/apps/obsidian.png" \
     "$DEBROOT/usr/share/icons/hicolor/512x512/apps/obsidian-clone.png"
elif [[ -f "$APPDIR/obsidian.png" ]]; then
  cp "$APPDIR/obsidian.png" \
     "$DEBROOT/usr/share/icons/hicolor/512x512/apps/obsidian-clone.png"
fi

INSTALLED=$(du -sb "$DEBROOT/usr" | cut -f1)
cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: obsidian-clone
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: obsidian-clone builder <noreply@example.com>
Installed-Size: $((INSTALLED / 1024))
Depends: libgtk-3-0, libnss3, libasound2t64 | libasound2, libatk1.0-0, libatk-bridge2.0-0, libatspi2.0-0, libcups2t64 | libcups2, libdrm2, libgbm1, libxkbcommon0, libxcomposite1, libxdamage1, libxrandr2, libxshmfence1, libcairo2, libpango-1.0-0, libxss1
Recommends: libnotify4, libsecret-1-0, libxtst6, xdg-utils, fonts-inter
Description: Obsidian Clone (monochrome)
 A from-source rebuild of the Obsidian 1.15.0 desktop application with a
 minimal white/black theme. All application features are preserved.
EOF

dpkg-deb --build --root-owner-group -Zgzip "$DEBROOT" "$OUTDIR/obsidian-clone_${VERSION}_amd64.deb" >/dev/null
log "deb: $OUTDIR/obsidian-clone_${VERSION}_amd64.deb"

# --- AppImage ---------------------------------------------------------------
if [[ -f "$ORIG_APPIMAGE" ]]; then
  log "building AppImage"
  # Extract the AppImage runtime (the ELF prefix in front of the squashfs).
  # "hsqs" also occurs inside the runtime, so the real superblock offset is
  # resolved by validating the squashfs superblock fields.
  OFFSET=$(python3 "$ROOT/scripts/find_squashfs_offset.py" "$ORIG_APPIMAGE" 2>/dev/null)
  [[ -n "$OFFSET" ]] || { echo "could not locate squashfs payload" >&2; exit 1; }
  head -c "$OFFSET" "$ORIG_APPIMAGE" > "$BUILD/appimage-runtime"
  chmod +x "$BUILD/appimage-runtime"
  if ! head -c 4 "$BUILD/appimage-runtime" | grep -q ELF; then
    echo "extracted AppImage runtime is not an ELF binary" >&2
    exit 1
  fi

  rm -f "$BUILD/appfs.squashfs"
  mksquashfs "$APPDIR" "$BUILD/appfs.squashfs" -comp xz -noappend -quiet \
             -root-owned -no-progress >/dev/null

  APPIMAGE_OUT="$OUTDIR/ObsidianClone-${VERSION}.AppImage"
  cat "$BUILD/appimage-runtime" "$BUILD/appfs.squashfs" > "$APPIMAGE_OUT"
  chmod +x "$APPIMAGE_OUT"

  # verify the produced image really is a valid AppImage
  NEW_OFF=$(python3 "$ROOT/scripts/find_squashfs_offset.py" "$APPIMAGE_OUT" 2>/dev/null)
  if [[ -n "$NEW_OFF" ]] && unsquashfs -s -o "$NEW_OFF" "$APPIMAGE_OUT" >/dev/null 2>&1; then
    log "AppImage: $APPIMAGE_OUT (verified, squashfs at $NEW_OFF)"
  else
    echo "AppImage verification failed" >&2
    exit 1
  fi
else
  log "original AppImage not found, skipping AppImage build"
fi

# --- tar.gz -----------------------------------------------------------------
log "building tar.gz"
tar -czf "$OUTDIR/obsidian-clone-${VERSION}-linux-amd64.tar.gz" -C "$ROOT" clone
log "tar.gz: $OUTDIR/obsidian-clone-${VERSION}-linux-amd64.tar.gz"

ls -la "$OUTDIR"
