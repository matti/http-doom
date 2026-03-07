#!/usr/bin/env bash
set -euo pipefail

# E2E tests for http-doom (multi-slot architecture)
# Tests the full lifecycle: lobby → join → play → leave → re-join

BASE_URL="${BASE_URL:-http://localhost:8080}"
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

assert_http_ok_with_content_type() {
  local desc="$1" url="$2" expected_type="$3"
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}|%{content_type}" --max-time 5 "$url") || true
  local status="${response%%|*}"
  local content_type="${response##*|}"
  if [ "$status" = "200" ]; then
    pass "$desc (HTTP $status)"
  else
    fail "$desc — expected 200, got $status"
    return
  fi
  if echo "$content_type" | grep -qi "$expected_type"; then
    pass "$desc content-type contains '$expected_type'"
  else
    fail "$desc content-type — expected '$expected_type', got '$content_type'"
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

# --- Wait for server ---
echo "Waiting for server at $BASE_URL ..."
for i in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "$BASE_URL" 2>/dev/null; then
    echo "Server ready after ${i}s"
    break
  fi
  if [ "$i" = "60" ]; then
    echo "ERROR: Server not ready after 60s"
    exit 1
  fi
  sleep 1
done

sleep 2

# --- Static file serving ---
echo ""
echo "=== Static Files ==="
assert_http_ok_with_content_type "index.html" "$BASE_URL/" "text/html"
assert_http_ok "logo image" "$BASE_URL/http-doom.png"
assert_http_ok "lobby.js" "$BASE_URL/javascript/lobby.js"
assert_http_ok "load.js" "$BASE_URL/javascript/load.js"
assert_http_ok "keys.js" "$BASE_URL/javascript/keys.js"
assert_http_ok "settings.js" "$BASE_URL/javascript/settings.js"
assert_response_contains "index has lobby" "$BASE_URL/" "joinBtn"
assert_response_contains "index has game view" "$BASE_URL/" "snapshot"

# --- Status endpoint (before any joins) ---
echo ""
echo "=== Status (Pre-Join) ==="
assert_http_ok "status endpoint" "$BASE_URL/status"
assert_response_contains "status has max_slots" "$BASE_URL/status" "max_slots"

status_body=$(curl -s --max-time 5 "$BASE_URL/status")
active_count=$(echo "$status_body" | grep -o '"active":true' | wc -l)
if [ "$active_count" -eq 0 ]; then
  pass "all slots free initially"
else
  fail "expected 0 active slots, got $active_count"
fi

# --- Join slot 1 ---
echo ""
echo "=== Join ==="
join_response=$(curl -s --max-time 10 "$BASE_URL/join")
echo "  join response: $join_response"
slot1=$(echo "$join_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')

if [ -n "$slot1" ] && [ "$slot1" -ge 1 ]; then
  pass "joined slot $slot1"
else
  fail "join failed (response: $join_response)"
  echo ""
  echo "========================"
  PASSED=$((TESTS - FAILURES))
  echo "Results: $PASSED/$TESTS passed"
  echo "$FAILURES test(s) FAILED"
  exit 1
fi

# Wait for doom to start and produce frames
sleep 5

# --- Status shows slot active ---
echo ""
echo "=== Status (Post-Join) ==="
status_body=$(curl -s --max-time 5 "$BASE_URL/status")
active_count=$(echo "$status_body" | grep -o '"active":true' | wc -l)
if [ "$active_count" -ge 1 ]; then
  pass "slot active after join"
else
  fail "no active slots after join"
fi

# --- Frame capture ---
echo ""
echo "=== Frame Capture ==="
assert_http_ok_with_content_type "snapshot.jpg" "$BASE_URL/player/$slot1/screen/snapshot.jpg" "image/jpeg"

size1=$(curl -s --max-time 5 "$BASE_URL/player/$slot1/screen/snapshot.jpg" | wc -c)
sleep 0.5
size2=$(curl -s --max-time 5 "$BASE_URL/player/$slot1/screen/snapshot.jpg" | wc -c)
if [ "$size1" -gt 0 ] && [ "$size2" -gt 0 ]; then
  pass "snapshot.jpg has content (${size1}B, ${size2}B)"
else
  fail "snapshot.jpg is empty"
fi

# --- Key input ---
echo ""
echo "=== Key Input ==="
assert_http_ok "keydown" "$BASE_URL/player/$slot1/key/down/Up"
assert_http_ok "keyup" "$BASE_URL/player/$slot1/key/up/Up"
assert_http_ok "keydown space" "$BASE_URL/player/$slot1/key/down/space"
assert_http_ok "keyup space" "$BASE_URL/player/$slot1/key/up/space"

# --- Config ---
echo ""
echo "=== Config ==="
assert_http_ok "set quality" "$BASE_URL/player/$slot1/config/quality?50"
assert_http_ok "set colorspace RGB" "$BASE_URL/player/$slot1/config/colorspace?RGB"
assert_http_ok "set colorspace Gray" "$BASE_URL/player/$slot1/config/colorspace?Gray"
curl -s "$BASE_URL/player/$slot1/config/colorspace?RGB" > /dev/null
curl -s "$BASE_URL/player/$slot1/config/quality?50" > /dev/null

# --- Heartbeat ---
echo ""
echo "=== Heartbeat ==="
assert_http_ok "heartbeat" "$BASE_URL/player/$slot1/heartbeat"

# --- Reset (game restarts) ---
echo ""
echo "=== Reset ==="
assert_http_ok "reset game" "$BASE_URL/player/$slot1/reset"
sleep 3
assert_http_ok "snapshot after reset" "$BASE_URL/player/$slot1/screen/snapshot.jpg"

# --- Multi-Slot: join a second slot ---
echo ""
echo "=== Multi-Slot ==="
join2_response=$(curl -s --max-time 10 "$BASE_URL/join")
slot2=$(echo "$join2_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')

if [ -n "$slot2" ] && [ "$slot2" -ge 1 ] && [ "$slot2" != "$slot1" ]; then
  pass "joined second slot $slot2 (different from $slot1)"
else
  fail "second join failed or same slot (response: $join2_response)"
fi

sleep 3

if [ -n "$slot2" ] && [ "$slot2" -ge 1 ]; then
  assert_http_ok "slot1 still serves frames" "$BASE_URL/player/$slot1/screen/snapshot.jpg"
  assert_http_ok "slot2 serves frames" "$BASE_URL/player/$slot2/screen/snapshot.jpg"

  status_body=$(curl -s --max-time 5 "$BASE_URL/status")
  active_count=$(echo "$status_body" | grep -o '"active":true' | wc -l)
  if [ "$active_count" -ge 2 ]; then
    pass "2+ slots active simultaneously"
  else
    fail "expected 2+ active slots, got $active_count"
  fi
fi

# --- Leave ---
echo ""
echo "=== Leave ==="
leave_response=$(curl -s --max-time 5 "$BASE_URL/leave/$slot1")
if echo "$leave_response" | grep -q '"ok":true'; then
  pass "left slot $slot1"
else
  fail "leave failed (response: $leave_response)"
fi

sleep 2

status_body=$(curl -s --max-time 5 "$BASE_URL/status")
slot1_active=$(echo "$status_body" | sed -n "s/.*\"$slot1\":{\"active\":\([a-z]*\).*/\1/p")
if [ "$slot1_active" = "false" ]; then
  pass "slot $slot1 freed after leave"
else
  fail "slot $slot1 still active after leave"
fi

# Leave slot 2
if [ -n "$slot2" ] && [ "$slot2" -ge 1 ]; then
  curl -s "$BASE_URL/leave/$slot2" > /dev/null
  sleep 1
fi

# --- Re-join after leave ---
echo ""
echo "=== Re-Join ==="
rejoin_response=$(curl -s --max-time 10 "$BASE_URL/join")
rejoin_slot=$(echo "$rejoin_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
if [ -n "$rejoin_slot" ] && [ "$rejoin_slot" -ge 1 ]; then
  pass "re-joined slot $rejoin_slot after leaving"
  curl -s "$BASE_URL/leave/$rejoin_slot" > /dev/null
else
  fail "re-join failed"
fi

# --- Summary ---
echo ""
echo "========================"
PASSED=$((TESTS - FAILURES))
echo "Results: $PASSED/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) FAILED"
  exit 1
else
  echo "All tests passed!"
fi
