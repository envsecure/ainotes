#!/bin/sh
# =============================================================================
# Ainotes installer for Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/envsecure/ainotes/main/scripts/install.sh | sh
#
# Options
#   --appimage   install the AppImage instead of the tarball
#   --deb        install the Debian/Ubuntu package instead of the tarball
#   --system     install system-wide (needs root) instead of per user
#   --uninstall  remove a previous installation
#   --help       show this text
#
# The default is a per-user installation: no root rights are required.  The
# application is unpacked into ~/.local/share/ainotes, a launcher is written to
# ~/.local/bin/ainotes and a menu entry is created for the current user.
# =============================================================================
set -eu

REPO="envsecure/ainotes"
BASE_URL="${AINOTES_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

ASSET_APPIMAGE="ainotes-linux-x86_64.AppImage"
ASSET_DEB="ainotes-linux-x86_64.deb"
ASSET_TARBALL="ainotes-linux-x86_64.tar.gz"
ASSET_ICON="ainotes-linux-icon.png"
ASSET_SUMS="SHA256SUMS"

MODE="tarball"
SYSTEM=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --appimage) MODE="appimage" ;;
    --tarball) MODE="tarball" ;;
    --deb) MODE="deb" ;;
    --system) SYSTEM=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

download() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    die "curl or wget is required to download Ainotes"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

verify() {
  file="$1"
  sums="$2"
  name="$3"
  expected="$(awk -v n="$name" '$2 == n {print $1; exit}' "$sums" || true)"
  [ -n "$expected" ] || die "no checksum for $name in $ASSET_SUMS"
  actual="$(sha256_of "$file")"
  [ -n "$actual" ] || die "no sha256 tool found (install coreutils)"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $name"
  say "checksum verified"
}

TMPDIR_AINOTES="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_AINOTES"' EXIT

# --- destinations ------------------------------------------------------------
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
if [ "$SYSTEM" = "1" ]; then
  BIN_DIR="/usr/local/bin"
  SHARE_DIR="/usr/local/share"
  APP_DIR="/usr/local/share/applications"
  ICON_DIR="/usr/share/icons/hicolor/512x512/apps"
  NEED_ROOT=1
else
  BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
  SHARE_DIR="$XDG_DATA"
  APP_DIR="$XDG_DATA/applications"
  ICON_DIR="$XDG_DATA/icons/hicolor/512x512/apps"
  NEED_ROOT=0
fi
APPDIR="$SHARE_DIR/ainotes"

as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "this step needs root rights (install sudo or run as root)"
  fi
}

run() {
  # Run a command as root when the installation needs it.
  if [ "$NEED_ROOT" = "1" ]; then
    as_root "$@"
  else
    "$@"
  fi
}

# --- uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  say "removing Ainotes"
  if [ "$MODE" = "deb" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      as_root apt-get remove -y ainotes || true
    else
      as_root dpkg --remove ainotes || true
    fi
  fi
  rm -f "$BIN_DIR/ainotes"
  rm -f "$APP_DIR/ainotes.desktop"
  rm -f "$ICON_DIR/ainotes.png"
  rm -rf "$APPDIR"
  say "Ainotes removed (your vaults and settings are kept)"
  exit 0
fi

# --- download ----------------------------------------------------------------
say "downloading Ainotes"
SUMS="$TMPDIR_AINOTES/$ASSET_SUMS"
if ! download "$BASE_URL/$ASSET_SUMS" "$SUMS" 2>/dev/null; then
  rm -f "$SUMS"
  say "checksum file not available, continuing without verification"
fi

ICON="$TMPDIR_AINOTES/$ASSET_ICON"
if ! download "$BASE_URL/$ASSET_ICON" "$ICON" 2>/dev/null; then
  rm -f "$ICON"
fi

# --- Debian package ----------------------------------------------------------
if [ "$MODE" = "deb" ]; then
  DEB="$TMPDIR_AINOTES/$ASSET_DEB"
  download "$BASE_URL/$ASSET_DEB" "$DEB"
  if [ -f "$SUMS" ]; then verify "$DEB" "$SUMS" "$ASSET_DEB"; fi
  say "installing the Debian package"
  if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" != "0" ]; then
    as_root apt-get install -y "$DEB"
  else
    as_root dpkg -i "$DEB"
  fi
  say "Ainotes installed - start it with: ainotes"
  exit 0
fi

# --- AppImage ----------------------------------------------------------------
if [ "$MODE" = "appimage" ]; then
  APPIMAGE="$TMPDIR_AINOTES/$ASSET_APPIMAGE"
  download "$BASE_URL/$ASSET_APPIMAGE" "$APPIMAGE"
  if [ -f "$SUMS" ]; then verify "$APPIMAGE" "$SUMS" "$ASSET_APPIMAGE"; fi
  say "installing the AppImage"
  run mkdir -p "$BIN_DIR"
  run install -m 0755 "$APPIMAGE" "$BIN_DIR/ainotes"
  LAUNCHER="$BIN_DIR/ainotes"
else
  TARBALL="$TMPDIR_AINOTES/$ASSET_TARBALL"
  download "$BASE_URL/$ASSET_TARBALL" "$TARBALL"
  if [ -f "$SUMS" ]; then verify "$TARBALL" "$SUMS" "$ASSET_TARBALL"; fi
  say "unpacking Ainotes"
  run mkdir -p "$SHARE_DIR"
  run rm -rf "$APPDIR"
  run tar xzf "$TARBALL" -C "$SHARE_DIR"
  if [ "$NEED_ROOT" = "1" ]; then
    # A system-wide installation can use the setuid sandbox helper.
    run chown -R root:root "$APPDIR"
    run chmod 4755 "$APPDIR/chrome-sandbox"
  else
    # A user installation cannot own the setuid helper; the launcher falls
    # back to the user namespace sandbox instead.
    run rm -f "$APPDIR/chrome-sandbox"
  fi
  say "writing the launcher"
  run mkdir -p "$BIN_DIR"
  LAUNCHER="$BIN_DIR/ainotes"
  run cat > "$LAUNCHER" <<EOF
#!/bin/sh
# Ainotes launcher (generated by the Ainotes installer)
APPDIR="$APPDIR"
export PATH="\$APPDIR:\$APPDIR/usr/sbin:\$PATH"
export XDG_DATA_DIRS="\$APPDIR/usr/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export LD_LIBRARY_PATH="\$APPDIR/usr/lib:\${LD_LIBRARY_PATH:-}"
if [ -u "\$APPDIR/chrome-sandbox" ]; then
  exec "\$APPDIR/ainotes" "\$@"
fi
if ! unshare -Ur true >/dev/null 2>&1; then
  exec "\$APPDIR/ainotes" --no-sandbox "\$@"
fi
exec "\$APPDIR/ainotes" "\$@"
EOF
  run chmod 0755 "$LAUNCHER"
fi

# --- desktop integration -----------------------------------------------------
say "installing the menu entry"
run mkdir -p "$APP_DIR" "$ICON_DIR"
if [ -f "$ICON" ]; then
  run install -m 0644 "$ICON" "$ICON_DIR/ainotes.png"
fi

cat > "$TMPDIR_AINOTES/ainotes.desktop" <<EOF
[Desktop Entry]
Name=Ainotes
Exec="$LAUNCHER" %U
Terminal=false
Type=Application
Icon=ainotes
StartupWMClass=Ainotes
Comment=Ainotes - minimal monochrome notes
MimeType=text/markdown;x-scheme-handler/ainotes;
Categories=Office;
EOF
run cp "$TMPDIR_AINOTES/ainotes.desktop" "$APP_DIR/ainotes.desktop"
run chmod 0644 "$APP_DIR/ainotes.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true
fi
if command -v update-mime-database >/dev/null 2>&1; then
  update-mime-database "$XDG_DATA/mime" >/dev/null 2>&1 || true
fi

say "Ainotes installed"
printf '    start it with: %s\n' "$LAUNCHER"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '    %s is not in your PATH - add it to your shell profile\n' "$BIN_DIR" ;;
esac
