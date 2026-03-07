#!/usr/bin/env bash
set -euxo pipefail

echo "user: $(whoami)"
echo "home: $HOME"

# Multiplayer config (set DOOM_MULTIPLAYER=1 to enable)
DOOM_MULTIPLAYER="${DOOM_MULTIPLAYER:-0}"
DOOM_MODE="${DOOM_MODE:-auto}"
DOOM_PORT="${DOOM_PORT:-2342}"
DOOM_PLAYERS="${DOOM_PLAYERS:-2}"
DOOM_SKILL="${DOOM_SKILL:-3}"
DOOM_DEATHMATCH="${DOOM_DEATHMATCH:-}"

# Write initial game mode for status endpoint
if [ "$DOOM_MULTIPLAYER" = "1" ]; then
  echo "multiplayer" > /app/settings/mode
else
  echo "singleplayer" > /app/settings/mode
fi

# Start headless X server
Xvfb :0 -nocursor -screen 0 320x240x24 -fbdir /app/tmp &

# Wait for X to be ready
while ! xdpyinfo -display :0 >/dev/null 2>&1; do
  echo "Waiting for X..."
  sleep 0.1
done
echo "X started"

# Frame capture loop: grab framebuffer -> convert to JPEG -> serve
(
  while true; do
    cp /app/tmp/Xvfb_screen0 /app/tmp/snapshot.xwd 2>/dev/null || true
    nice -n 19 convert \
      -colorspace "$(cat /app/settings/colorspace)" \
      -quality "$(cat /app/settings/quality)" \
      /app/tmp/snapshot.xwd /app/tmp/snapshot.jpg 2>/dev/null || true
    mv /app/tmp/snapshot.jpg /app/www/screen/snapshot.jpg 2>/dev/null || true
    sleep 0.028
  done
) &

# Start Caddy web server
caddy run --config /app/Caddyfile --adapter caddyfile &

sleep 1

# Build doom command-line arguments for multiplayer
build_doom_args() {
  local args="-nosound -window -geometry 320x240"

  case "$DOOM_MODE" in
    server)
      args="$args -privateserver -server -port $DOOM_PORT -nodes $DOOM_PLAYERS"
      if [ -n "$DOOM_DEATHMATCH" ]; then
        args="$args -deathmatch"
      fi
      args="$args -skill $DOOM_SKILL -warp 1 1"
      echo "server" > /app/settings/mode
      echo "Starting as SERVER on port $DOOM_PORT, waiting for $DOOM_PLAYERS players" >&2
      ;;
    client:*)
      local server_addr="${DOOM_MODE#client:}"
      args="$args -connect $server_addr -port $DOOM_PORT"
      echo "client" > /app/settings/mode
      echo "Connecting to server at $server_addr:$DOOM_PORT" >&2
      ;;
    auto)
      echo "autodiscovery" > /app/settings/mode
      echo "Running autodiscovery..." >&2
      local result
      result=$(/app/discover.sh discover)
      echo "Discovery result: $result" >&2
      case "$result" in
        server)
          args="$args -privateserver -server -port $DOOM_PORT -nodes $DOOM_PLAYERS"
          if [ -n "$DOOM_DEATHMATCH" ]; then
            args="$args -deathmatch"
          fi
          args="$args -skill $DOOM_SKILL -warp 1 1"
          echo "server" > /app/settings/mode
          ;;
        client:*)
          local server_addr="${result#client:}"
          args="$args -connect $server_addr -port $DOOM_PORT"
          echo "client" > /app/settings/mode
          ;;
      esac
      ;;
  esac

  echo "$args"
}

# Run chocolate-doom in a restart loop
(
  while true; do
    mkdir -p "$HOME/.local/share/chocolate-doom"
    cp /app/chocolate-doom.cfg "$HOME/.local/share/chocolate-doom"

    if [ "$DOOM_MULTIPLAYER" = "1" ]; then
      doom_args=$(build_doom_args)
      # shellcheck disable=SC2086
      chocolate-doom $doom_args || true
    else
      chocolate-doom -nosound -window -geometry 320x240 || true
    fi
  done
) &

# Keep container alive
wait
