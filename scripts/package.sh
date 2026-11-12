#!/usr/bin/env bash
# =============================================================================
# Package the Ainotes AppDir into Linux installables.
#
#   scripts/package.sh --root <project-root> --outdir <dist-dir>
#
# Produces
#   ainotes_1.15.0_amd64.deb           native package
#   Ainotes-1.15.0.AppImage            portable single file
#   ainotes-1.15.0-linux-amd64.tar.gz  tarball
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

APPDIR="$ROOT/ainotes"
BUILD="$ROOT/build"
ORIG_APPIMAGE="$ROOT/original/Ainotes-1.15.0.AppImage"
VERSION="1.15.0"

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
[[ -d "$APPDIR" ]] || { echo "AppDir missing: $APPDIR (run scripts/build.sh first)" >&2; exit 1; }
mkdir -p "$OUTDIR"

# --- .deb -------------------------------------------------------------------
log "building .deb"
DEBROOT="$BUILD/deb"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN" \
         "$DEBROOT/usr/lib/ainotes" \
         "$DEBROOT/usr/bin" \
         "$DEBROOT/usr/share/applications" \
         "$DEBROOT/usr/share/mime/packages" \
         "$DEBROOT/usr/share/icons/hicolor/512x512/apps"

cp -a "$APPDIR/." "$DEBROOT/usr/lib/ainotes/"
chmod 0755 "$DEBROOT/usr/lib/ainotes/ainotes"
chmod 4755 "$DEBROOT/usr/lib/ainotes/chrome-sandbox" 2>/dev/null || true

cat > "$DEBROOT/usr/bin/ainotes" <<'EOF'
#!/bin/sh
APPDIR=/usr/lib/ainotes
export PATH="$APPDIR:$PATH"
export LD_LIBRARY_PATH="$APPDIR:${LD_LIBRARY_PATH:-}"
export XDG_DATA_DIRS="$APPDIR/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$APPDIR/ainotes" --no-sandbox "$@"
EOF
chmod 0755 "$DEBROOT/usr/bin/ainotes"

cat > "$DEBROOT/usr/share/applications/ainotes.desktop" <<'EOF'
[Desktop Entry]
Name=Ainotes
Exec=ainotes --no-sandbox %U
Terminal=false
Type=Application
Icon=ainotes
StartupWMClass=Ainotes
X-AppImage-Version=1.15.0
Comment=Ainotes - minimal monochrome notes
MimeType=application/pdf;text/markdown;application/x-ainotes-canvas;application/x-ainotes-base;x-scheme-handler/ainotes;
Categories=Office;
EOF

if [[ -f "$APPDIR/usr/share/icons/hicolor/512x512/apps/ainotes.png" ]]; then
  cp "$APPDIR/usr/share/icons/hicolor/512x512/apps/ainotes.png" \
     "$DEBROOT/usr/share/icons/hicolor/512x512/apps/ainotes.png"
elif [[ -f "$APPDIR/ainotes.png" ]]; then
  cp "$APPDIR/ainotes.png" \
     "$DEBROOT/usr/share/icons/hicolor/512x512/apps/ainotes.png"
fi

if [[ -f "$APPDIR/usr/share/mime/packages/ainotes.xml" ]]; then
  cp "$APPDIR/usr/share/mime/packages/ainotes.xml" \
     "$DEBROOT/usr/share/mime/packages/ainotes.xml"
fi

INSTALLED=$(du -sb "$DEBROOT/usr" | cut -f1)
cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: ainotes
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: envsecure <newu46312@gmail.com>
Installed-Size: $((INSTALLED / 1024))
Depends: libgtk-3-0, libnss3, libasound2t64 | libasound2, libatk1.0-0, libatk-bridge2.0-0, libatspi2.0-0, libcups2t64 | libcups2, libdrm2, libgbm1, libxkbcommon0, libxcomposite1, libxdamage1, libxrandr2, libxshmfence1, libcairo2, libpango-1.0-0, libxss1
Recommends: libnotify4, libsecret-1-0, libxtst6, xdg-utils, fonts-inter
Description: Ainotes (monochrome)
 Ainotes is a Linux desktop notes application with a minimal white/black
 theme. All application features are preserved.
EOF

dpkg-deb --build --root-owner-group -Zgzip "$DEBROOT" "$OUTDIR/ainotes_${VERSION}_amd64.deb" >/dev/null
log "deb: $OUTDIR/ainotes_${VERSION}_amd64.deb"

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

  APPIMAGE_OUT="$OUTDIR/Ainotes-${VERSION}.AppImage"
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
tar -czf "$OUTDIR/ainotes-${VERSION}-linux-amd64.tar.gz" -C "$ROOT" ainotes
log "tar.gz: $OUTDIR/ainotes-${VERSION}-linux-amd64.tar.gz"

ls -la "$OUTDIR"
