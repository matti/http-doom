# CLAUDE.md

## Project Overview

**http-doom** streams Doom gameplay over plain HTTP — no WebSockets or VNC needed. A single container runs up to 4 independent Doom sessions, each on its own headless X display. Players visit the web lobby, click "Join" to get allocated a slot, and play via per-player HTTP endpoints. Idle slots are automatically freed.

## Architecture

```
Browser ─→ Lobby (/join) ─→ allocates slot N
         ─→ /player/N/screen/snapshot.jpg  (frame polling)
         ─→ /player/N/key/{down,up}/X      (keyboard input via CGI)
         ─→ /player/N/heartbeat            (keep-alive)
         ─→ /leave/N                       (free slot)

Caddy v2 (static + CGI)
  ├── slot 1: Xvfb :1 ─→ chocolate-doom ─→ frame capture ─→ /player/1/screen/snapshot.jpg
  ├── slot 2: Xvfb :2 ─→ chocolate-doom ─→ frame capture ─→ /player/2/screen/snapshot.jpg
  ├── slot 3: Xvfb :3 ─→ chocolate-doom ─→ frame capture ─→ /player/3/screen/snapshot.jpg
  └── slot 4: Xvfb :4 ─→ chocolate-doom ─→ frame capture ─→ /player/4/screen/snapshot.jpg
```

- **Xvfb** ×4 — one virtual framebuffer per slot at 320×240
- **chocolate-doom** ×4 — one per active slot, auto-restarts on crash/reset
- **ImageMagick** — per-slot frame capture loop (~36 FPS)
- **Caddy v2** with [aksdb/caddy-cgi](https://github.com/aksdb/caddy-cgi) — serves static files + CGI endpoints
- **slot-ctl** — manages doom + capture lifecycle per slot
- **Watchdog** — frees slots idle for `DOOM_IDLE_TIMEOUT` seconds

## Project Structure

```
├── Dockerfile                        # Multi-stage: xcaddy (Caddy+CGI) + Alpine runtime
├── docker-compose.yml                # Dev compose (single container, 4 slots)
├── docker-compose.test.yml           # E2E test compose
├── docker-compose.test-multiplayer.yml # Multi-slot capacity test compose
├── test/
│   ├── e2e.sh                        # E2E tests: join → play → leave lifecycle
│   └── e2e-multiplayer.sh            # Capacity tests: fill slots, exhaustion, reuse
├── app/
│   ├── entrypoint.sh                 # Starts 4× Xvfb, Caddy, watchdog
│   ├── slot-ctl                      # Manages doom + capture per slot (start/stop)
│   ├── join                          # CGI: allocate a free slot, start doom
│   ├── leave                         # CGI: free a slot, stop doom
│   ├── player                        # CGI: per-slot key input, reset, config, heartbeat
│   ├── status                        # CGI: JSON with all slot states
│   ├── Caddyfile                     # Caddy v2 config with per-player CGI routing
│   ├── chocolate-doom.cfg            # Doom engine config (320×240 windowed, no sound)
│   ├── doom1.wad                     # Doom shareware game data
│   ├── settings/                     # Global defaults (colorspace, quality)
│   ├── slots/                        # Per-slot state (created at runtime)
│   ├── tmp/                          # Framebuffer files (created at runtime)
│   └── www/                          # Web root
│       ├── index.html                # Lobby + game UI
│       ├── http-doom.png             # Logo
│       └── javascript/
│           ├── lobby.js              # Join/leave, slot status polling
│           ├── load.js               # Per-slot frame polling, FPS meter, heartbeat
│           ├── keys.js               # Per-slot keyboard capture
│           └── settings.js           # Per-slot config buttons (quality, colorspace)
```

## Running Locally

```bash
docker compose up --build
# Open http://localhost:8080
# Click JOIN to start playing — up to 4 players simultaneously
```

Use arrow keys, space, Enter, Ctrl to play.

## Running Tests

```bash
# E2E tests (join/play/leave lifecycle)
docker compose -f docker-compose.test.yml up --build --abort-on-container-exit

# Multi-slot capacity tests (fill all slots, test exhaustion + reuse)
docker compose -f docker-compose.test-multiplayer.yml up --build --abort-on-container-exit

# Run against an already-running instance
BASE_URL=http://localhost:8080 ./test/e2e.sh
BASE_URL=http://localhost:8080 ./test/e2e-multiplayer.sh
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP port for Caddy |
| `DOOM_MAX_SLOTS` | `4` | Maximum concurrent game sessions |
| `DOOM_IDLE_TIMEOUT` | `300` | Seconds of inactivity before a slot is freed |

## Slot Lifecycle

1. **Join**: `GET /join` → finds first free slot, starts doom + frame capture via `setsid slot-ctl start N`, returns `{"slot": N}`
2. **Play**: Browser polls `/player/N/screen/snapshot.jpg` for frames, sends key events to `/player/N/key/{down,up}/KEY`, heartbeats every 30s to `/player/N/heartbeat`
3. **Leave**: `GET /leave/N` or `navigator.sendBeacon` on tab close → stops doom + capture, frees slot
4. **Timeout**: Watchdog checks every 30s; if `last_activity` exceeds `DOOM_IDLE_TIMEOUT`, slot is freed automatically
5. **Crash recovery**: If doom crashes, `slot-ctl`'s loop auto-restarts it; if `slot-ctl` itself dies, the watchdog detects the dead PID and cleans up

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/` | Lobby page |
| GET | `/status` | JSON: `{"max_slots": 4, "slots": {"1": {"active": true, "idle_seconds": 30}, ...}}` |
| GET | `/join` | Allocate a slot, returns `{"slot": N}` or `{"error": "no free slots"}` |
| GET | `/leave/N` | Free slot N |
| GET | `/player/N/screen/snapshot.jpg` | Current frame (static file, cache-bust with `?timestamp`) |
| GET | `/player/N/key/down/KEY` | Keydown event via xdotool |
| GET | `/player/N/key/up/KEY` | Keyup event via xdotool |
| GET | `/player/N/reset` | Kill doom process (auto-restarts) |
| GET | `/player/N/config/colorspace?RGB` | Set colorspace (`RGB` or `Gray`) |
| GET | `/player/N/config/quality?50` | Set JPEG quality (`15`, `25`, `50`, `75`, `100`) |
| GET | `/player/N/heartbeat` | Update last_activity timestamp |

## Key Technical Details

- **Dockerfile**: Multi-stage — `caddy:2-builder` + `xcaddy` compiles Caddy with CGI plugin, Alpine runtime has doom + X11 dependencies
- **Slot isolation**: Each slot runs on a separate X display (`:1` through `:4`), separate framebuffer directory, separate doom HOME directory
- **Frame capture**: `slot-ctl` runs a capture loop per slot — copies Xvfb framebuffer to XWD, converts to JPEG with ImageMagick, atomically `mv`s to web root
- **Process management**: `join` CGI uses `setsid` to detach `slot-ctl` from the CGI process group; `slot-ctl` traps TERM/EXIT for cleanup
- **Caddyfile**: Uses Caddy v2 `order cgi before respond` with wildcard matchers (`/player/*/key/*`) and `script_name /player` to route all player actions to a single CGI handler
- **Status endpoint**: `/status` returns JSON with per-slot active state and idle time

## Conventions

- CGI scripts are bash with `set -e` error handling
- Frontend is vanilla JS with no build step or dependencies
- JavaScript uses IIFEs with `"use strict"` and `window.doom` namespace
- Shell scripts use `#!/usr/bin/env bash` shebangs
- `entrypoint.sh` uses `set -euxo pipefail` for strict error handling
- E2E tests are curl-based bash scripts, run via Docker Compose
