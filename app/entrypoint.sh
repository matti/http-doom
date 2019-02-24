#!/usr/bin/env sh

set -e

mkdir -p /app/tmp

Error() {
  echo "$1 EXITED"
  exit 1
}

(
  Xvfb :0 -nocursor -screen 0 320x240x24 -fbdir /app/tmp
) &

while true; do
  set +e
    xdpyinfo -display :0 >/dev/null 2>&1
    xdpyinfo_code=$?
  set -e
  if [ "$xdpyinfo_code" = "0" ]; then
    echo "X started"
    break
  fi
  echo "Waiting X .."
  sleep 0.1
done

(
  while true; do
    set +e
      cp /app/tmp/Xvfb_screen0 /app/tmp/snapshot.xwd
      nice -n 19 convert -colorspace $(cat /app/settings/colorspace) -quality $(cat /app/settings/quality) /app/tmp/snapshot.xwd /app/www/snapshot_new.jpg
      mv /app/www/snapshot_new.jpg /app/www/snapshot.jpg
      sleep 0.01
    set -e
  done
) &

(
  cd /app/www
  caddy --port $PORT --conf /app/Caddyfile
) &

sleep 1
(
  while true; do
    mkdir -p /root/.local/share/chocolate-doom
    cp /app/chocolate-doom.cfg /root/.local/share/chocolate-doom
    set +e
      nice -n 18 chocolate-doom -nosound -window -geometry 320x240
    set -e
  done
) &


tail -f /dev/null
