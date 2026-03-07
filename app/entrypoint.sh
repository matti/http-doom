#!/usr/bin/env bash
set -euxo pipefail

MAX_SLOTS="${DOOM_MAX_SLOTS:-4}"
IDLE_TIMEOUT="${DOOM_IDLE_TIMEOUT:-300}"

echo "http-doom starting: max_slots=$MAX_SLOTS idle_timeout=${IDLE_TIMEOUT}s"

# --- Create slot directories ---
for i in $(seq 1 "$MAX_SLOTS"); do
  mkdir -p "/app/slots/$i/doom-home"
  mkdir -p "/app/tmp/fb/$i"
  mkdir -p "/app/www/player/$i/screen"
  echo "0"   > "/app/slots/$i/active"
  echo "RGB" > "/app/slots/$i/colorspace"
  echo "50"  > "/app/slots/$i/quality"
done

# --- Start one Xvfb per slot ---
for i in $(seq 1 "$MAX_SLOTS"); do
  Xvfb ":$i" -nocursor -screen 0 320x240x24 -fbdir "/app/tmp/fb/$i" &
done

# Wait for all X displays to be ready
for i in $(seq 1 "$MAX_SLOTS"); do
  while ! xdpyinfo -display ":$i" >/dev/null 2>&1; do
    sleep 0.1
  done
  echo "X display :$i ready"
done

# --- Start Caddy ---
caddy run --config /app/Caddyfile --adapter caddyfile &

sleep 1

# --- Watchdog: free idle slots and detect dead doom processes ---
(
  while true; do
    sleep 30
    now=$(date +%s)
    for i in $(seq 1 "$MAX_SLOTS"); do
      sd="/app/slots/$i"
      if [ "$(cat "$sd/active" 2>/dev/null)" = "1" ]; then
        last=$(cat "$sd/last_activity" 2>/dev/null || echo "$now")
        idle=$((now - last))
        if [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
          echo "Slot $i idle for ${idle}s (timeout=${IDLE_TIMEOUT}s), freeing"
          /app/slot-ctl stop "$i"
        fi
        # Detect dead slot-ctl (doom crashed and didn't restart)
        if [ -f "$sd/ctl_pid" ]; then
          if ! kill -0 "$(cat "$sd/ctl_pid")" 2>/dev/null; then
            echo "Slot $i ctl process dead, cleaning up"
            echo "0" > "$sd/active"
            rm -f "$sd/ctl_pid" "$sd/doom_pid"
          fi
        fi
      fi
    done
  done
) &

echo "http-doom ready"
wait
