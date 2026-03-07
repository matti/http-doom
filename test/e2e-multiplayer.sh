#!/usr/bin/env bash
set -euo pipefail

# E2E tests for http-doom multiplayer
# Validates that two instances can discover each other, negotiate roles,
# and both serve playable game sessions.
#
# Expects two player URLs:
#   PLAYER1_URL  (default: http://player1:8080)
#   PLAYER2_URL  (default: http://player2:8080)

PLAYER1_URL="${PLAYER1_URL:-http://player1:8080}"
PLAYER2_URL="${PLAYER2_URL:-http://player2:8080}"
FAILURES=0
TESTS=0

pass() {
  TESTS=$((TESTS + 1))
  echo "  PASS: $1"
}

fail() {
  TESTS=$((TESTS + 1))
  FAILURES=$((FAILURES + 1))
  echo "  FAIL: $1"
}

assert_http_ok() {
  local desc="$1" url="$2"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url") || true
  if [ "$status" = "200" ]; then
    pass "$desc (HTTP $status)"
  else
    fail "$desc — expected 200, got $status"
  fi
}

assert_response_contains() {
  local desc="$1" url="$2" expected="$3"
  local body
  body=$(curl -s --max-time 5 "$url") || true
  if echo "$body" | grep -q "$expected"; then
    pass "$desc — contains '$expected'"
  else
    fail "$desc — missing '$expected' (got: $body)"
  fi
}

get_json_field() {
  local url="$1" field="$2"
  curl -s --max-time 5 "$url" | sed -n "s/.*\"${field}\":\"\{0,1\}\([^,\"}\{]*\)\"\{0,1\}.*/\1/p"
}

wait_for_server() {
  local name="$1" url="$2" max_wait="${3:-60}"
  echo "Waiting for $name at $url ..."
  for i in $(seq 1 "$max_wait"); do
    if curl -s -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      echo "$name ready after ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: $name not ready after ${max_wait}s"
  return 1
}

# ============================================================
# Wait for both players to be reachable
# ============================================================
echo "===================================="
echo "  http-doom Multiplayer E2E Tests"
echo "===================================="
echo ""

wait_for_server "Player 1" "$PLAYER1_URL" 60
wait_for_server "Player 2" "$PLAYER2_URL" 60

# Give the game processes time to start up and produce frames
sleep 5

# ============================================================
# Both players serve HTTP
# ============================================================
echo ""
echo "=== Both Players Serve HTTP ==="
assert_http_ok "player1 index" "$PLAYER1_URL/"
assert_http_ok "player2 index" "$PLAYER2_URL/"

# ============================================================
# Both players have the status endpoint
# ============================================================
echo ""
echo "=== Status Endpoints ==="
assert_http_ok "player1 /status" "$PLAYER1_URL/status"
assert_http_ok "player2 /status" "$PLAYER2_URL/status"

# ============================================================
# Status reports multiplayer mode (not singleplayer)
# ============================================================
echo ""
echo "=== Multiplayer Mode Active ==="
p1_mode=$(get_json_field "$PLAYER1_URL/status" "mode")
p2_mode=$(get_json_field "$PLAYER2_URL/status" "mode")
echo "  Player 1 mode: $p1_mode"
echo "  Player 2 mode: $p2_mode"

# In explicit server/client mode, modes should be set immediately.
# In auto mode, they start as "multiplayer" or "autodiscovery" and
# transition to "server"/"client" after discovery completes.
# Either way, mode should NOT be "singleplayer".
if [ "$p1_mode" != "singleplayer" ] && [ -n "$p1_mode" ]; then
  pass "player1 is not singleplayer (mode=$p1_mode)"
else
  fail "player1 mode is '$p1_mode', expected non-singleplayer"
fi

if [ "$p2_mode" != "singleplayer" ] && [ -n "$p2_mode" ]; then
  pass "player2 is not singleplayer (mode=$p2_mode)"
else
  fail "player2 mode is '$p2_mode', expected non-singleplayer"
fi

# ============================================================
# Wait for autodiscovery to complete (roles settle)
# Poll until at least one player reports "server" or "client",
# which indicates discovery has completed.
# ============================================================
echo ""
echo "=== Autodiscovery Completes ==="
discovery_done=false
for i in $(seq 1 60); do
  p1_mode=$(get_json_field "$PLAYER1_URL/status" "mode")
  p2_mode=$(get_json_field "$PLAYER2_URL/status" "mode")

  if [ "$p1_mode" = "server" ] || [ "$p1_mode" = "client" ]; then
    if [ "$p2_mode" = "server" ] || [ "$p2_mode" = "client" ]; then
      discovery_done=true
      break
    fi
  fi

  if [ $((i % 10)) -eq 0 ]; then
    echo "  Still waiting for discovery... (${i}s, p1=$p1_mode, p2=$p2_mode)"
  fi
  sleep 1
done

if [ "$discovery_done" = "true" ]; then
  pass "autodiscovery completed (p1=$p1_mode, p2=$p2_mode)"
else
  fail "autodiscovery did not complete after 60s (p1=$p1_mode, p2=$p2_mode)"
fi

# ============================================================
# Exactly one server and one client
# ============================================================
echo ""
echo "=== Role Assignment ==="
p1_mode=$(get_json_field "$PLAYER1_URL/status" "mode")
p2_mode=$(get_json_field "$PLAYER2_URL/status" "mode")

server_count=0
client_count=0
[ "$p1_mode" = "server" ] && server_count=$((server_count + 1))
[ "$p2_mode" = "server" ] && server_count=$((server_count + 1))
[ "$p1_mode" = "client" ] && client_count=$((client_count + 1))
[ "$p2_mode" = "client" ] && client_count=$((client_count + 1))

if [ "$server_count" -eq 1 ]; then
  pass "exactly one server"
else
  fail "expected 1 server, got $server_count (p1=$p1_mode, p2=$p2_mode)"
fi

if [ "$client_count" -eq 1 ]; then
  pass "exactly one client"
else
  fail "expected 1 client, got $client_count (p1=$p1_mode, p2=$p2_mode)"
fi

# ============================================================
# Lexicographic rule: lower hostname is server
# ============================================================
echo ""
echo "=== Lexicographic Server Election ==="
# player1 < player2 alphabetically, so player1 should be server
if [ "$p1_mode" = "server" ]; then
  pass "player1 (lower hostname) elected as server"
else
  fail "expected player1 as server (lexicographic rule), got p1=$p1_mode p2=$p2_mode"
fi

# ============================================================
# Both players serve frames
# ============================================================
echo ""
echo "=== Frame Capture (Both Players) ==="

# Wait for frames to be produced (doom needs a moment after multiplayer connect)
sleep 3

for player_name in "player1" "player2"; do
  if [ "$player_name" = "player1" ]; then
    url="$PLAYER1_URL"
  else
    url="$PLAYER2_URL"
  fi

  status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url/screen/snapshot.jpg") || true
  if [ "$status" = "200" ]; then
    size=$(curl -s --max-time 5 "$url/screen/snapshot.jpg" | wc -c)
    if [ "$size" -gt 0 ]; then
      pass "$player_name serves frames (${size}B)"
    else
      fail "$player_name snapshot.jpg is empty"
    fi
  else
    fail "$player_name snapshot.jpg — HTTP $status"
  fi
done

# ============================================================
# Both players accept key input
# ============================================================
echo ""
echo "=== Key Input (Both Players) ==="
assert_http_ok "player1 keydown" "$PLAYER1_URL/key/down/Up"
assert_http_ok "player1 keyup" "$PLAYER1_URL/key/up/Up"
assert_http_ok "player2 keydown" "$PLAYER2_URL/key/down/Up"
assert_http_ok "player2 keyup" "$PLAYER2_URL/key/up/Up"

# ============================================================
# Doom process is running on both
# ============================================================
echo ""
echo "=== Doom Process Running ==="
p1_running=$(get_json_field "$PLAYER1_URL/status" "doom_running")
p2_running=$(get_json_field "$PLAYER2_URL/status" "doom_running")

if [ "$p1_running" = "true" ]; then
  pass "player1 doom is running"
else
  fail "player1 doom is not running (doom_running=$p1_running)"
fi

if [ "$p2_running" = "true" ]; then
  pass "player2 doom is running"
else
  fail "player2 doom is not running (doom_running=$p2_running)"
fi

# ============================================================
# Peer discovery: each player knows about the other
# ============================================================
echo ""
echo "=== Peer Visibility ==="
p1_peers=$(get_json_field "$PLAYER1_URL/status" "peers")
p2_peers=$(get_json_field "$PLAYER2_URL/status" "peers")
echo "  Player 1 peers: $p1_peers"
echo "  Player 2 peers: $p2_peers"

if [ -n "$p1_peers" ]; then
  pass "player1 has discovered peers"
else
  fail "player1 has no peers"
fi

if [ -n "$p2_peers" ]; then
  pass "player2 has discovered peers"
else
  fail "player2 has no peers"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "===================================="
PASSED=$((TESTS - FAILURES))
echo "Results: $PASSED/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) FAILED"
  exit 1
else
  echo "All multiplayer tests passed!"
fi
