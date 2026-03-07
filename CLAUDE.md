# CLAUDE.md

## Project Overview

**http-doom** streams Doom gameplay over plain HTTP — no WebSockets or VNC needed. A headless X server runs chocolate-doom, ImageMagick captures frames as JPEGs, and a Caddy v2 web server serves them. The browser polls for new frames at ~35 FPS and sends keyboard input back via CGI endpoints.

## Architecture

```
Browser (JS polling) <--HTTP--> Caddy v2 (static + CGI) <--files/xdotool--> Xvfb + chocolate-doom
```

- **Xvfb** renders the game to a virtual framebuffer at 320x240
- **ImageMagick** (`convert`) captures the framebuffer and writes `snapshot.jpg` in a loop (~36 FPS)
- **Caddy v2** with [aksdb/caddy-cgi](https://github.com/aksdb/caddy-cgi) serves static files and routes CGI requests to shell scripts
- **Browser JS** polls `snapshot.jpg` with cache-busting timestamps and sends key events via fetch

## Project Structure

```
├── Dockerfile              # Multi-stage build: xcaddy (Caddy+CGI) then Alpine runtime
├── docker-compose.yml      # Local dev compose file
├── app/
│   ├── entrypoint.sh       # Orchestrates Xvfb, frame capture loop, Caddy, and Doom
│   ├── Caddyfile           # Caddy v2 config with CGI directive ordering
│   ├── keys                # CGI: keyboard input via xdotool (keydown/keyup)
│   ├── reset               # CGI: kills chocolate-doom (auto-restarts via entrypoint loop)
│   ├── config              # CGI: colorspace and JPEG quality settings
│   ├── chocolate-doom.cfg  # Doom engine config (320x240 windowed, no sound)
│   ├── doom1.wad           # Doom shareware game data
│   ├── settings/           # Runtime config files (colorspace, quality)
│   ├── tmp/                # Transient files (framebuffer snapshots)
│   └── www/                # Web root
│       ├── index.html      # Main UI (HTML5)
│       ├── http-doom.png   # Logo
│       └── javascript/
│           ├── load.js     # Frame polling and FPS meter
│           ├── keys.js     # Keyboard capture and key state management
│           └── settings.js # UI button handlers for config
```

## Running Locally

```bash
docker build -t http-doom .
docker run -p 8080:8080 http-doom
# or
docker compose up --build
```

Then open http://localhost:8080 and use arrow keys, space, Enter, Ctrl to play.

## Key Technical Details

- **Dockerfile**: Multi-stage build — first stage uses `caddy:2-builder` with `xcaddy` to compile Caddy with the CGI plugin, second stage is Alpine with game dependencies
- **Frame capture**: `entrypoint.sh` copies Xvfb's framebuffer (`Xvfb_screen0`) to XWD, converts to JPEG with ImageMagick, then atomically `mv`s into the web root
- **Input handling**: CGI scripts receive key names via URL path (`/key/down/Up`, `/key/up/space`) and call `xdotool` to inject X11 key events
- **Settings**: Stored as plain files in `app/settings/` — colorspace (`RGB` or `Gray`) and JPEG quality (`15`–`100`), read by the capture loop on each frame
- **Game loop**: chocolate-doom runs in a `while true` loop so it auto-restarts after crashes or resets
- **Caddyfile**: Uses Caddy v2 syntax with `order cgi before respond` global option and `script_name` directives for CGI routing

## Conventions

- CGI scripts are bash with `set -e` error handling
- Frontend is vanilla JS with no build step or dependencies
- JavaScript uses IIFEs with `"use strict"` for proper scoping
- Shell scripts use `#!/usr/bin/env bash` shebangs
- `entrypoint.sh` uses `set -euxo pipefail` for strict error handling
