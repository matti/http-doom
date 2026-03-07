#!/usr/bin/env bash
set -euxo pipefail

echo "user: $(whoami)"
echo "home: $HOME"

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

# Run chocolate-doom in a restart loop
(
  while true; do
    mkdir -p "$HOME/.local/share/chocolate-doom"
    cp /app/chocolate-doom.cfg "$HOME/.local/share/chocolate-doom"
    chocolate-doom -nosound -window -geometry 320x240 || true
  done
) &

# Keep container alive
wait
