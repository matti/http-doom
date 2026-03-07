#!/usr/bin/env bash
set -euo pipefail

# E2E tests for http-doom multi-slot capacity
# Fills all slots, verifies isolation, tests slot exhaustion and reuse.

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

echo "======================================="
echo "  http-doom Multi-Slot Capacity Tests"
echo "======================================="

# --- Wait for server ---
echo ""
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

# Get max_slots
status_body=$(curl -s --max-time 5 "$BASE_URL/status")
max_slots=$(echo "$status_body" | sed -n 's/.*"max_slots":\([0-9]*\).*/\1/p')
echo "  max_slots: $max_slots"

# --- Fill all slots ---
echo ""
echo "=== Fill All Slots ==="
joined_slots=""
for i in $(seq 1 "$max_slots"); do
  response=$(curl -s --max-time 10 "$BASE_URL/join")
  slot=$(echo "$response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
  if [ -n "$slot" ] && [ "$slot" -ge 1 ]; then
    pass "joined slot $slot ($i/$max_slots)"
    joined_slots="$joined_slots $slot"
  else
    fail "failed to join slot $i (response: $response)"
  fi
  sleep 1
done

# Wait for all doom processes to start
sleep 5

# --- Verify all slots active ---
echo ""
echo "=== All Slots Active ==="
status_body=$(curl -s --max-time 5 "$BASE_URL/status")
active_count=$(echo "$status_body" | grep -o '"active":true' | wc -l)
if [ "$active_count" -eq "$max_slots" ]; then
  pass "all $max_slots slots active"
else
  fail "expected $max_slots active, got $active_count"
fi

# --- All slots serve independent frames ---
echo ""
echo "=== Slot Isolation (Frames) ==="
for slot in $joined_slots; do
  assert_http_ok "slot $slot serves frames" "$BASE_URL/player/$slot/screen/snapshot.jpg"
done

# --- All slots accept input ---
echo ""
echo "=== Slot Isolation (Input) ==="
for slot in $joined_slots; do
  assert_http_ok "slot $slot key input" "$BASE_URL/player/$slot/key/down/Up"
  curl -s "$BASE_URL/player/$slot/key/up/Up" > /dev/null
done

# --- Slot exhaustion: next join should fail ---
echo ""
echo "=== Slot Exhaustion ==="
exhaust_response=$(curl -s --max-time 5 "$BASE_URL/join")
if echo "$exhaust_response" | grep -q '"error"'; then
  pass "join correctly rejected when all slots full"
else
  fail "join should fail when full (response: $exhaust_response)"
  # If it somehow got a slot, track it for cleanup
  extra_slot=$(echo "$exhaust_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
  if [ -n "$extra_slot" ]; then
    joined_slots="$joined_slots $extra_slot"
  fi
fi

# --- Leave one slot ---
echo ""
echo "=== Leave and Reuse ==="
first_slot=$(echo "$joined_slots" | awk '{print $1}')
leave_response=$(curl -s --max-time 5 "$BASE_URL/leave/$first_slot")
if echo "$leave_response" | grep -q '"ok":true'; then
  pass "left slot $first_slot"
else
  fail "leave slot $first_slot failed"
fi

sleep 2

# Slot should be free now
status_body=$(curl -s --max-time 5 "$BASE_URL/status")
slot_active=$(echo "$status_body" | sed -n "s/.*\"$first_slot\":{\"active\":\([a-z]*\).*/\1/p")
if [ "$slot_active" = "false" ]; then
  pass "slot $first_slot freed"
else
  fail "slot $first_slot not freed (active=$slot_active)"
fi

# Should be able to join again
rejoin_response=$(curl -s --max-time 10 "$BASE_URL/join")
rejoin_slot=$(echo "$rejoin_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
if [ -n "$rejoin_slot" ] && [ "$rejoin_slot" -ge 1 ]; then
  pass "re-joined slot $rejoin_slot after freeing $first_slot"
  joined_slots="$rejoin_slot $(echo "$joined_slots" | sed "s/$first_slot//")"
else
  fail "re-join failed after freeing slot"
fi

sleep 3

# --- Cleanup: leave all slots ---
echo ""
echo "=== Cleanup ==="
for slot in $joined_slots; do
  slot=$(echo "$slot" | tr -d ' ')
  if [ -n "$slot" ]; then
    curl -s "$BASE_URL/leave/$slot" > /dev/null 2>&1 || true
  fi
done

sleep 2

status_body=$(curl -s --max-time 5 "$BASE_URL/status")
active_count=$(echo "$status_body" | grep -o '"active":true' | wc -l)
if [ "$active_count" -eq 0 ]; then
  pass "all slots freed after cleanup"
else
  fail "expected 0 active after cleanup, got $active_count"
fi

# --- Summary ---
echo ""
echo "======================================="
PASSED=$((TESTS - FAILURES))
echo "Results: $PASSED/$TESTS passed"
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES test(s) FAILED"
  exit 1
else
  echo "All multi-slot tests passed!"
fi
