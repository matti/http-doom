# CLAUDE.md

## Project Overview

**http-doom** streams Doom gameplay over plain HTTP — no WebSockets or VNC needed. A headless X server runs chocolate-doom, ImageMagick captures frames as JPEGs, and a Caddy v2 web server serves them. The browser polls for new frames at ~35 FPS and sends keyboard input back via CGI endpoints. Supports multiplayer via UDP autodiscovery.

## Architecture

```
Browser (JS polling) <--HTTP--> Caddy v2 (static + CGI) <--files/xdotool--> Xvfb + chocolate-doom
                                                                                    |
                                                                         UDP autodiscovery (socat)
                                                                                    |
                                                                           Other http-doom instances
```

- **Xvfb** renders the game to a virtual framebuffer at 320x240
- **ImageMagick** (`convert`) captures the framebuffer and writes `snapshot.jpg` in a loop (~36 FPS)
- **Caddy v2** with [aksdb/caddy-cgi](https://github.com/aksdb/caddy-cgi) serves static files and routes CGI requests to shell scripts
- **Browser JS** polls `snapshot.jpg` with cache-busting timestamps and sends key events via fetch
- **discover.sh** handles UDP broadcast-based peer discovery for multiplayer

## Project Structure

```
├── Dockerfile                    # Multi-stage build: xcaddy (Caddy+CGI) then Alpine runtime
├── docker-compose.yml            # Single-player dev compose
├── docker-compose.multiplayer.yml # 2-player multiplayer compose
├── docker-compose.test.yml       # E2E test compose
├── test/
│   └── e2e.sh                    # E2E test suite (curl-based)
├── app/
│   ├── entrypoint.sh             # Orchestrates Xvfb, frame capture, Caddy, and Doom
│   ├── discover.sh               # UDP autodiscovery for multiplayer
│   ├── Caddyfile                 # Caddy v2 config with CGI directive ordering
│   ├── keys                      # CGI: keyboard input via xdotool (keydown/keyup)
│   ├── reset                     # CGI: kills chocolate-doom (auto-restarts via entrypoint loop)
│   ├── config                    # CGI: colorspace and JPEG quality settings
│   ├── status                    # CGI: game status JSON (mode, peers, doom_running)
│   ├── chocolate-doom.cfg        # Doom engine config (320x240 windowed, no sound)
│   ├── doom1.wad                 # Doom shareware game data
│   ├── settings/                 # Runtime config files (colorspace, quality, mode)
│   ├── tmp/                      # Transient files (framebuffer snapshots, peer list)
│   └── www/                      # Web root
│       ├── index.html            # Main UI (HTML5)
│       ├── http-doom.png         # Logo
│       └── javascript/
│           ├── load.js           # Frame polling and FPS meter
│           ├── keys.js           # Keyboard capture and key state management
│           └── settings.js       # UI button handlers, status polling

```

## Running Locally

```bash
# Single player
docker compose up --build
# then open http://localhost:8080

# Multiplayer (2 players, autodiscovery)
docker compose -f docker-compose.yml -f docker-compose.multiplayer.yml up --build
# Player 1: http://localhost:8081
# Player 2: http://localhost:8082

# Multiplayer deathmatch
DOOM_DEATHMATCH=1 docker compose -f docker-compose.yml -f docker-compose.multiplayer.yml up --build
```

Use arrow keys, space, Enter, Ctrl to play.

## Running Tests

```bash
# E2E tests (builds and runs against a live container)
docker compose -f docker-compose.test.yml up --build --abort-on-container-exit

# Or run against an already-running instance
BASE_URL=http://localhost:8080 ./test/e2e.sh
```

## Multiplayer

Multiplayer uses chocolate-doom's built-in network play with a custom autodiscovery layer.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DOOM_MULTIPLAYER` | `0` | Set to `1` to enable multiplayer |
| `DOOM_MODE` | `auto` | `auto` (UDP discovery), `server`, or `client:<address>` |
| `DOOM_PORT` | `2342` | UDP port for game traffic |
| `DOOM_PLAYERS` | `2` | Number of players to wait for before starting |
| `DOOM_SKILL` | `3` | Difficulty 1-5 |
| `DOOM_DEATHMATCH` | (empty) | Set to `1` for deathmatch mode |

### Autodiscovery Protocol

When `DOOM_MODE=auto`, instances use `discover.sh` to find peers:
1. Each instance broadcasts `HTTPDOOM:<hostname>:<port>` via UDP on port 2399
2. Instances listen for peer announcements via `socat`
3. The lexicographically lowest hostname becomes the server
4. Other instances connect as clients
5. Game auto-starts when all players have joined (`-nodes` flag)

## Key Technical Details

- **Dockerfile**: Multi-stage build — first stage uses `caddy:2-builder` with `xcaddy` to compile Caddy with the CGI plugin, second stage is Alpine with game dependencies
- **Frame capture**: `entrypoint.sh` copies Xvfb's framebuffer (`Xvfb_screen0`) to XWD, converts to JPEG with ImageMagick, then atomically `mv`s into the web root
- **Input handling**: CGI scripts receive key names via URL path (`/key/down/Up`, `/key/up/space`) and call `xdotool` to inject X11 key events
- **Settings**: Stored as plain files in `app/settings/` — colorspace (`RGB` or `Gray`), JPEG quality (`15`–`100`), and game mode, read by the capture loop / status endpoint
- **Game loop**: chocolate-doom runs in a `while true` loop so it auto-restarts after crashes or resets
- **Caddyfile**: Uses Caddy v2 syntax with `order cgi before respond` global option and `script_name` directives for CGI routing
- **Status endpoint**: `/status` returns JSON with game mode, peer list, and doom process status

## Conventions

- CGI scripts are bash with `set -e` error handling
- Frontend is vanilla JS with no build step or dependencies
- JavaScript uses IIFEs with `"use strict"` for proper scoping
- Shell scripts use `#!/usr/bin/env bash` shebangs
- `entrypoint.sh` uses `set -euxo pipefail` for strict error handling
- E2E tests are curl-based bash scripts, run via Docker Compose
