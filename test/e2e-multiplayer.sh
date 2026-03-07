#!/usr/bin/env bash
set -euo pipefail

# E2E tests for http-doom multi-slot capacity
# Fills all slots, verifies isolation with image assertions, tests exhaustion and reuse.

BASE_URL="${BASE_URL:-http://localhost:8080}"
TMPDIR="${TMPDIR:-/tmp}/doom-e2e-multi"
FAILURES=0
TESTS=0

mkdir -p "$TMPDIR"

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

fetch_snapshot() {
  local slot="$1" dest="$2"
  curl -s --max-time 5 -o "$dest" "$BASE_URL/player/$slot/screen/snapshot.jpg"
}

assert_valid_jpeg() {
  local desc="$1" file="$2"
  local info
  if ! info=$(identify "$file" 2>&1); then
    fail "$desc — not a valid image (identify failed: $info)"
    return
  fi
  if echo "$info" | grep -qi "jpeg"; then
    pass "$desc — valid JPEG"
  else
    fail "$desc — not JPEG format (got: $info)"
  fi
}

assert_image_dimensions() {
  local desc="$1" file="$2" expected_w="$3" expected_h="$4"
  local dimensions
  dimensions=$(identify -format "%wx%h" "$file" 2>/dev/null) || true
  if [ "$dimensions" = "${expected_w}x${expected_h}" ]; then
    pass "$desc — dimensions ${dimensions}"
  else
    fail "$desc — expected ${expected_w}x${expected_h}, got ${dimensions}"
  fi
}

file_checksum() {
  md5sum "$1" 2>/dev/null | cut -d' ' -f1
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

# Wait for all doom processes to start and produce frames
sleep 8

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

# --- All slots serve valid JPEG frames at 320x240 ---
echo ""
echo "=== All Slots: Image Validation ==="
for slot in $joined_slots; do
  fetch_snapshot "$slot" "$TMPDIR/slot${slot}.jpg"
  assert_valid_jpeg "slot $slot" "$TMPDIR/slot${slot}.jpg"
  assert_image_dimensions "slot $slot" "$TMPDIR/slot${slot}.jpg" 320 240
  size=$(wc -c < "$TMPDIR/slot${slot}.jpg")
  if [ "$size" -gt 1000 ]; then
    pass "slot $slot has substantial frame (${size}B)"
  else
    fail "slot $slot frame too small (${size}B)"
  fi
done

# --- Slot isolation: per-slot colorspace ---
echo ""
echo "=== Slot Isolation: Colorspace ==="
# Set odd slots to Gray, even to RGB
for slot in $joined_slots; do
  if [ $((slot % 2)) -eq 1 ]; then
    curl -s "$BASE_URL/player/$slot/config/colorspace?Gray" > /dev/null
  else
    curl -s "$BASE_URL/player/$slot/config/colorspace?RGB" > /dev/null
  fi
done
sleep 1

for slot in $joined_slots; do
  fetch_snapshot "$slot" "$TMPDIR/cs_slot${slot}.jpg"
  cs=$(identify -format "%[colorspace]" "$TMPDIR/cs_slot${slot}.jpg" 2>/dev/null) || true
  if [ $((slot % 2)) -eq 1 ]; then
    if echo "$cs" | grep -qi "Gray"; then
      pass "slot $slot colorspace is Gray (as configured)"
    else
      fail "slot $slot expected Gray, got $cs"
    fi
  else
    if echo "$cs" | grep -qi "sRGB"; then
      pass "slot $slot colorspace is sRGB (as configured)"
    else
      fail "slot $slot expected sRGB, got $cs"
    fi
  fi
done

# Reset all colorspaces
for slot in $joined_slots; do
  curl -s "$BASE_URL/player/$slot/config/colorspace?RGB" > /dev/null
done

# --- Slot isolation: per-slot quality ---
echo ""
echo "=== Slot Isolation: Quality ==="
# Set first slot to quality 15, last slot to quality 100
slot_list=($joined_slots)
first_slot="${slot_list[0]}"
last_slot="${slot_list[${#slot_list[@]}-1]}"

curl -s "$BASE_URL/player/$first_slot/config/quality?15" > /dev/null
curl -s "$BASE_URL/player/$last_slot/config/quality?100" > /dev/null
sleep 1

fetch_snapshot "$first_slot" "$TMPDIR/q_low.jpg"
fetch_snapshot "$last_slot" "$TMPDIR/q_high.jpg"
low_size=$(wc -c < "$TMPDIR/q_low.jpg")
high_size=$(wc -c < "$TMPDIR/q_high.jpg")
echo "  slot $first_slot (q=15): ${low_size}B, slot $last_slot (q=100): ${high_size}B"
if [ "$high_size" -gt "$low_size" ]; then
  pass "quality isolation: high quality (${high_size}B) > low quality (${low_size}B)"
else
  fail "quality isolation: expected high > low, got ${high_size}B vs ${low_size}B"
fi

# Reset quality
curl -s "$BASE_URL/player/$first_slot/config/quality?50" > /dev/null
curl -s "$BASE_URL/player/$last_slot/config/quality?50" > /dev/null

# --- All slots accept input independently ---
echo ""
echo "=== Slot Isolation (Input) ==="
for slot in $joined_slots; do
  assert_http_ok "slot $slot key input" "$BASE_URL/player/$slot/key/down/Up"
  curl -s "$BASE_URL/player/$slot/key/up/Up" > /dev/null
done

# --- Frames update after input ---
echo ""
echo "=== Frames Update After Input ==="
# Pick the first slot for this test
test_slot="${slot_list[0]}"
fetch_snapshot "$test_slot" "$TMPDIR/before_input.jpg"
before_hash=$(file_checksum "$TMPDIR/before_input.jpg")

# Send a sequence of inputs to cause visual change
curl -s "$BASE_URL/player/$test_slot/key/down/Return" > /dev/null
sleep 0.3
curl -s "$BASE_URL/player/$test_slot/key/up/Return" > /dev/null
sleep 1
curl -s "$BASE_URL/player/$test_slot/key/down/Up" > /dev/null
sleep 0.3
curl -s "$BASE_URL/player/$test_slot/key/up/Up" > /dev/null
sleep 1

fetch_snapshot "$test_slot" "$TMPDIR/after_input.jpg"
after_hash=$(file_checksum "$TMPDIR/after_input.jpg")
assert_valid_jpeg "frame after input" "$TMPDIR/after_input.jpg"

if [ "$before_hash" != "$after_hash" ]; then
  pass "frame changed after input"
else
  # Try once more with different input
  curl -s "$BASE_URL/player/$test_slot/key/down/space" > /dev/null
  sleep 0.3
  curl -s "$BASE_URL/player/$test_slot/key/up/space" > /dev/null
  sleep 1
  fetch_snapshot "$test_slot" "$TMPDIR/after_input2.jpg"
  after_hash2=$(file_checksum "$TMPDIR/after_input2.jpg")
  if [ "$before_hash" != "$after_hash2" ]; then
    pass "frame changed after second input attempt"
  else
    fail "frame unchanged after input (hash=$before_hash)"
  fi
fi

# --- Slot exhaustion: next join should fail ---
echo ""
echo "=== Slot Exhaustion ==="
exhaust_response=$(curl -s --max-time 5 "$BASE_URL/join")
if echo "$exhaust_response" | grep -q '"error"'; then
  pass "join correctly rejected when all slots full"
else
  fail "join should fail when full (response: $exhaust_response)"
  extra_slot=$(echo "$exhaust_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
  if [ -n "$extra_slot" ]; then
    joined_slots="$joined_slots $extra_slot"
  fi
fi

# --- Leave one slot, verify frames stop, rejoin and verify frames restart ---
echo ""
echo "=== Leave, Verify, Rejoin ==="
leave_slot="${slot_list[0]}"
leave_response=$(curl -s --max-time 5 "$BASE_URL/leave/$leave_slot")
if echo "$leave_response" | grep -q '"ok":true'; then
  pass "left slot $leave_slot"
else
  fail "leave slot $leave_slot failed"
fi

sleep 2

# Slot should be free
status_body=$(curl -s --max-time 5 "$BASE_URL/status")
slot_active=$(echo "$status_body" | sed -n "s/.*\"$leave_slot\":{\"active\":\([a-z]*\).*/\1/p")
if [ "$slot_active" = "false" ]; then
  pass "slot $leave_slot freed"
else
  fail "slot $leave_slot not freed (active=$slot_active)"
fi

# Other slots should still be active and serving frames
remaining_slot="${slot_list[1]}"
fetch_snapshot "$remaining_slot" "$TMPDIR/remaining.jpg"
assert_valid_jpeg "remaining slot $remaining_slot still serves frames" "$TMPDIR/remaining.jpg"

# Rejoin — should get a slot
rejoin_response=$(curl -s --max-time 10 "$BASE_URL/join")
rejoin_slot=$(echo "$rejoin_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')
if [ -n "$rejoin_slot" ] && [ "$rejoin_slot" -ge 1 ]; then
  pass "re-joined slot $rejoin_slot after freeing $leave_slot"
  joined_slots="$rejoin_slot $(echo "$joined_slots" | sed "s/$leave_slot//")"
else
  fail "re-join failed after freeing slot"
fi

sleep 5

# Verify re-joined slot serves valid frames
if [ -n "$rejoin_slot" ] && [ "$rejoin_slot" -ge 1 ]; then
  fetch_snapshot "$rejoin_slot" "$TMPDIR/rejoin.jpg"
  assert_valid_jpeg "re-joined slot $rejoin_slot frame" "$TMPDIR/rejoin.jpg"
  assert_image_dimensions "re-joined slot dimensions" "$TMPDIR/rejoin.jpg" 320 240
  rejoin_size=$(wc -c < "$TMPDIR/rejoin.jpg")
  if [ "$rejoin_size" -gt 1000 ]; then
    pass "re-joined slot has substantial frame (${rejoin_size}B)"
  else
    fail "re-joined slot frame too small (${rejoin_size}B)"
  fi
fi

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

rm -rf "$TMPDIR"

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
