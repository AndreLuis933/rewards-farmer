#!/usr/bin/env bash
#
# Two modes:
#   login  — Xvfb + noVNC on :6080 so you can sign in to Edge by hand once.
#   run    — default; runs the bot headless exactly as before.
#
# The profile directory is the named Docker volume mounted at /app/data-dir,
# so a sign-in done in login mode is read back by run mode on later containers.

set -euo pipefail

DISPLAY_NUM=99
DISPLAY=":${DISPLAY_NUM}"
VNC_PORT=5900
NOVNC_PORT=6080
SCREEN_SIZE="1920x1080x24"
USER_DATA_DIR="/app/data-dir"
PROFILE_NAME="Default"
LOGIN_URL="https://rewards.bing.com"

log() { printf '[entrypoint] %s\n' "$*"; }

# Remove stale Chromium singleton files from a profile directory. Each
# container has a different hostname, so a SingletonLock left by a previous
# container (e.g. one killed without closing Edge cleanly) makes the next run
# think the profile is "in use by another computer" and refuse to start.
# Safe because only one Edge instance runs per container.
remove_stale_locks() {
  local dir="$1"
  rm -f "$dir/SingletonLock" \
        "$dir/SingletonCookie" \
        "$dir/SingletonSocket" \
        "$dir/$PROFILE_NAME/SingletonLock" \
        "$dir/$PROFILE_NAME/SingletonCookie" \
        "$dir/$PROFILE_NAME/SingletonSocket" 2>/dev/null || true
}

cleanup() {
  log "shutting down background services..."
  # Best-effort: kill every background job we started.
  local pids
  pids="$(jobs -p 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
  fi
  wait 2>/dev/null || true
}

mode="${1:-run}"
case "$mode" in

  login)
    trap cleanup EXIT INT TERM

    # Pick the profile directory for this login session. REWARDS_ACCOUNTS may
    # list several; only the first is signed in here, so the user repeats the
    # command once per account.
    accounts_raw="${REWARDS_ACCOUNTS:-}"
    if [[ -n "$accounts_raw" ]]; then
      first_name="$(printf '%s' "$accounts_raw" | cut -d, -f1 | tr -d '[:space:]')"
      profile_dir="${USER_DATA_DIR}/${first_name}"
    else
      profile_dir="$USER_DATA_DIR"
    fi
    log "login mode: profile directory = $profile_dir"
    mkdir -p "$profile_dir"
    remove_stale_locks "$profile_dir"

    # Virtual framebuffer.
    log "starting Xvfb on $DISPLAY ($SCREEN_SIZE)..."
    Xvfb "$DISPLAY" -screen 0 "$SCREEN_SIZE" -ac +extension RANDR \
      >/tmp/xvfb.log 2>&1 &
    xvfb_pid=$!
    sleep 1
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
      log "Xvfb failed to start:"; cat /tmp/xvfb.log; exit 1
    fi

    # Window manager — Edge renders and behaves better with one.
    log "starting fluxbox..."
    DISPLAY="$DISPLAY" fluxbox >/tmp/fluxbox.log 2>&1 &
    sleep 1

    # D-Bus session bus. xclip needs it to bridge the X selection clipboard
    # (CLIPBOARD + PRIMARY) so the noVNC clipboard panel can push and pull text
    # to/from Edge running inside the container.
    log "starting dbus session bus..."
    if command -v dbus-launch >/dev/null 2>&1; then
      eval "$(dbus-launch --sh-syntax 2>/dev/null || true)"
      export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
    fi

    # VNC server, bound to localhost so only websockify can reach it.
    # x11vnc polls PRIMARY and CLIPBOARD selections by default, syncing them
    # to the VNC client. xclip/xsel (installed in the Dockerfile) give X apps
    # like Edge a way to read/write those selections programmatically.
    log "starting x11vnc on 127.0.0.1:$VNC_PORT..."
    x11vnc -display "$DISPLAY" -rfbport "$VNC_PORT" -nopw -forever -shared \
      -localhost -cursor arrow \
      -o /tmp/x11vnc.log >/dev/null 2>&1 &
    sleep 1

    # noVNC over WebSocket on 6080 — this is the port the user opens in a browser.
    log "starting noVNC on 0.0.0.0:$NOVNC_PORT..."
    websockify --web /usr/share/novnc "$NOVNC_PORT" "127.0.0.1:$VNC_PORT" \
      >/tmp/websockify.log 2>&1 &
    sleep 1

    log ""
    log "noVNC ready: open http://localhost:$NOVNC_PORT/vnc.html"
    log "sign in to your Microsoft account on the Edge window shown there"
    log "close Edge normally when done — do NOT Ctrl+C this container"
    log ""

    # Edge, visible on the virtual display, pointing at the rewards page.
    export DISPLAY="$DISPLAY"
    microsoft-edge \
      --user-data-dir="$profile_dir" \
      --profile-directory="$PROFILE_NAME" \
      --no-sandbox \
      --disable-gpu \
      --disable-dev-shm-usage \
      --no-first-run \
      --no-default-browser-check \
      "$LOGIN_URL" &
    edge_pid=$!

    # Block until the user closes Edge. When Edge exits, the trap runs cleanup
    # and the container stops, leaving the signed-in profile on the volume.
    log "Edge PID=$edge_pid — waiting for it to exit..."
    wait "$edge_pid" || log "Edge exited with non-zero status (ignored)"
    log "Edge closed. Login session complete."
    ;;

  run | *)
    # Default mode: the bot, headless, exactly as the image did before.
    if [[ "$mode" != "run" ]]; then
      log "unknown mode '$mode', falling back to run"
    fi

    # Clean singleton locks for every account that will run. A login container
    # killed without closing Edge cleanly leaves SingletonLock behind; without
    # this, the run fails with "session not created" before the bot starts.
    accounts_raw="${REWARDS_ACCOUNTS:-}"
    if [[ -n "$accounts_raw" ]]; then
      IFS=',' read -ra account_names <<< "$accounts_raw"
      for name in "${account_names[@]}"; do
        name="$(echo "$name" | tr -d '[:space:]')"
        [[ -z "$name" ]] && continue
        remove_stale_locks "${USER_DATA_DIR}/${name}"
      done
    else
      remove_stale_locks "$USER_DATA_DIR"
    fi

    log "run mode: starting python src/main.py"
    exec python src/main.py
    ;;
esac