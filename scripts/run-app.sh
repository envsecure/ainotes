#!/usr/bin/env bash
# =============================================================================
# Run an Ainotes AppDir under Xvfb and capture a screenshot.
#
#   scripts/run-app.sh <appdir> <label> [--vault <path>] [--seconds N] [--args ...]
#
# Every run is fully isolated: HOME, XDG_* and the user-data directory are
# redirected into a scratch directory so two runs never share state.
# =============================================================================
set -euo pipefail

APPDIR="$(cd "${1:?usage: run-app.sh <appdir> <label> [options]}" && pwd)"
LABEL="${2:?usage: run-app.sh <appdir> <label> [options]}"
shift 2

VAULT=""
SECONDS_WAIT=18
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2 ;;
    --seconds) SECONDS_WAIT="$2"; shift 2 ;;
    --args) shift; EXTRA_ARGS=("$@"); break ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

if [[ -n "$VAULT" ]]; then
  VAULT="$(cd "$VAULT" && pwd)"
fi
RUNROOT="/tmp/opencode/run-$LABEL"
rm -rf "$RUNROOT"
mkdir -p "$RUNROOT/home" "$RUNROOT/shots"

export HOME="$RUNROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_RUNTIME_DIR="$RUNROOT/run"
mkdir -p "$XDG_RUNTIME_DIR"
export AINOTES_USER_DATA="$RUNROOT/userdata"
export AINOTES_DISABLE_UPDATE=1

DISP="${DISPLAY:-:99}"
if ! xdpyinfo -display "$DISP" >/dev/null 2>&1; then
  Xvfb "$DISP" -screen 0 1600x1000x24 -nolisten tcp >"$RUNROOT/xvfb.log" 2>&1 &
  XVFB_PID=$!
  export DISPLAY="$DISP"
  sleep 2
fi

echo "[run-app] label=$LABEL appdir=$APPDIR display=$DISPLAY"

# Seed a vault registry so the app opens a real vault instead of the picker.
if [[ -n "$VAULT" ]]; then
  seed_registry() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/ainotes.json" <<EOF
{"vaults":{"vault":{"path":"$VAULT","ts":$(date +%s000),"open":true}}}
EOF
  }
  seed_registry "$AINOTES_USER_DATA"
  seed_registry "$HOME/.config/ainotes"
  echo "[run-app] seeded vault registry -> $VAULT"
fi

cd "$APPDIR"
# APP_EXEC / APP_ASAR allow running the same payload on a stock Electron
# runtime instead of the runtime that ships inside the AppImage.
EXEC="${APP_EXEC:-$APPDIR/ainotes}"
APP_ARG=()
[[ -n "${APP_ASAR:-}" ]] && APP_ARG=("$APP_ASAR")
"$EXEC" "${APP_ARG[@]}" --no-sandbox "${EXTRA_ARGS[@]}" >"$RUNROOT/app.log" 2>&1 &
APP_PID=$!

sleep "$SECONDS_WAIT"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "[run-app] WARNING: app exited early"
fi

# Screenshot the whole virtual screen.
if command -v import >/dev/null 2>&1; then
  import -display "$DISPLAY" -window root "$RUNROOT/shots/$LABEL.png" 2>/dev/null \
    && echo "[run-app] screenshot: $RUNROOT/shots/$LABEL.png"
fi
if command -v xwd >/dev/null 2>&1; then
  xwd -display "$DISPLAY" -root -silent > "$RUNROOT/shots/$LABEL.xwd" 2>/dev/null || true
fi

# Report what the app wrote and what it logged.
echo "[run-app] user data:"
find "$AINOTES_USER_DATA" -maxdepth 2 2>/dev/null | head -25
echo "[run-app] app log tail:"
tail -20 "$RUNROOT/app.log" 2>/dev/null

kill "$APP_PID" 2>/dev/null || true
sleep 1
pkill -f "$APPDIR/ainotes" 2>/dev/null || true
exit 0
