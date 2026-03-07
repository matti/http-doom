#!/usr/bin/env bash
set -euo pipefail

# Multiplayer autodiscovery for http-doom
# Uses UDP broadcast to find peers on the local network.
#
# Protocol:
#   - Each instance broadcasts "HTTPDOOM:<hostname>:<doom_port>" on UDP 2399
#   - Instances listen for peer announcements
#   - The lexicographically lowest hostname becomes the server
#   - Other instances connect as clients
#
# Environment variables:
#   DOOM_PORT      - UDP port for doom multiplayer traffic (default: 2342)
#   DISCOVER_PORT  - UDP port for discovery broadcasts (default: 2399)
#   DOOM_HOSTNAME  - Hostname to announce (default: $(hostname))
#   DOOM_MODE      - Force mode: "server", "client:<address>", or "auto" (default: auto)
#   DOOM_PLAYERS   - Number of players to wait for (default: 2)
#   DOOM_SKILL     - Difficulty 1-5 (default: 3)
#   DOOM_DEATHMATCH - Set to "1" for deathmatch, empty for coop (default: empty)

DOOM_PORT="${DOOM_PORT:-2342}"
DISCOVER_PORT="${DISCOVER_PORT:-2399}"
DOOM_HOSTNAME="${DOOM_HOSTNAME:-$(hostname)}"
DOOM_MODE="${DOOM_MODE:-auto}"
DOOM_PLAYERS="${DOOM_PLAYERS:-2}"
PEERS_FILE="/app/tmp/peers.txt"
ROLE_FILE="/app/tmp/role.txt"

cleanup() {
  rm -f "$PEERS_FILE" "$ROLE_FILE"
}
trap cleanup EXIT

: > "$PEERS_FILE"
echo "waiting" > "$ROLE_FILE"

# Broadcast our presence every 2 seconds
broadcast_presence() {
  while true; do
    echo "HTTPDOOM:${DOOM_HOSTNAME}:${DOOM_PORT}" | \
      socat - UDP-DATAGRAM:255.255.255.255:${DISCOVER_PORT},broadcast,so-broadcast 2>/dev/null || true
    sleep 2
  done
}

# Listen for peer announcements
listen_for_peers() {
  socat -u UDP-RECVFROM:${DISCOVER_PORT},reuseaddr,fork STDOUT 2>/dev/null | \
  while IFS= read -r line; do
    if [[ "$line" == HTTPDOOM:* ]]; then
      local peer_host peer_port
      peer_host=$(echo "$line" | cut -d: -f2)
      peer_port=$(echo "$line" | cut -d: -f3)

      # Don't add ourselves
      if [ "$peer_host" != "$DOOM_HOSTNAME" ]; then
        # Add peer if not already known
        if ! grep -q "^${peer_host}:" "$PEERS_FILE" 2>/dev/null; then
          echo "${peer_host}:${peer_port}" >> "$PEERS_FILE"
          echo "Discovered peer: ${peer_host}:${peer_port}"
        fi
      fi
    fi
  done
}

# Determine our role based on discovered peers
determine_role() {
  local peer_count
  peer_count=$(wc -l < "$PEERS_FILE" 2>/dev/null || echo "0")
  peer_count=$((peer_count + 0)) # ensure numeric

  if [ "$peer_count" -lt 1 ]; then
    echo "waiting"
    return
  fi

  # Collect all hostnames (ours + peers) and sort
  {
    echo "$DOOM_HOSTNAME"
    cut -d: -f1 "$PEERS_FILE"
  } | sort | head -1 | {
    read -r first
    if [ "$first" = "$DOOM_HOSTNAME" ]; then
      echo "server"
    else
      echo "client"
    fi
  }
}

get_server_address() {
  # The server is the lexicographically first hostname
  {
    echo "${DOOM_HOSTNAME}:${DOOM_PORT}"
    cat "$PEERS_FILE"
  } | sort | head -1 | cut -d: -f1
}

# Main autodiscovery loop
# Returns: "server" or "client:<address>"
run_discovery() {
  echo "Starting autodiscovery as ${DOOM_HOSTNAME} on port ${DISCOVER_PORT}..."

  broadcast_presence &
  local broadcast_pid=$!

  listen_for_peers &
  local listen_pid=$!

  # Wait until we have enough peers
  local role="waiting"
  while [ "$role" = "waiting" ]; do
    sleep 1
    local peer_count
    peer_count=$(wc -l < "$PEERS_FILE" 2>/dev/null || echo "0")
    peer_count=$((peer_count + 0))

    local needed=$((DOOM_PLAYERS - 1))
    if [ "$peer_count" -ge "$needed" ]; then
      role=$(determine_role)
    else
      echo "Waiting for players... (${peer_count}/${needed} peers found)"
    fi
  done

  # Stop discovery
  kill "$broadcast_pid" "$listen_pid" 2>/dev/null || true
  wait "$broadcast_pid" "$listen_pid" 2>/dev/null || true

  echo "$role" > "$ROLE_FILE"

  if [ "$role" = "server" ]; then
    echo "server"
  else
    local addr
    addr=$(get_server_address)
    echo "client:${addr}"
  fi
}

# If sourced, export functions. If executed directly, run discovery.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-discover}" in
    discover)
      run_discovery
      ;;
    role)
      cat "$ROLE_FILE" 2>/dev/null || echo "unknown"
      ;;
    peers)
      cat "$PEERS_FILE" 2>/dev/null || echo "none"
      ;;
    *)
      echo "Usage: $0 {discover|role|peers}"
      exit 1
      ;;
  esac
fi
