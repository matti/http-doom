#!/usr/bin/env bash
set -euo pipefail

# E2E tests for http-doom (multi-slot architecture)
# Tests the full lifecycle: lobby → join → play → leave → re-join
# Includes image validation: JPEG format, dimensions, frames updating, config effects

BASE_URL="${BASE_URL:-http://localhost:8080}"
TMPDIR="${TMPDIR:-/tmp}/doom-e2e"
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

# Download a snapshot to a file and return the path
fetch_snapshot() {
  local slot="$1" dest="$2"
  curl -s --max-time 5 -o "$dest" "$BASE_URL/player/$slot/screen/snapshot.jpg"
}

# Assert file is a valid JPEG using ImageMagick identify
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

# Assert image dimensions are WxH
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

# Assert image colorspace
assert_image_colorspace() {
  local desc="$1" file="$2" expected="$3"
  local cs
  cs=$(identify -format "%[colorspace]" "$file" 2>/dev/null) || true
  if echo "$cs" | grep -qi "$expected"; then
    pass "$desc — colorspace $cs"
  else
    fail "$desc — expected colorspace $expected, got $cs"
  fi
}

# Get JPEG quality from identify
get_image_quality() {
  identify -format "%Q" "$1" 2>/dev/null || echo "0"
}

# Get MD5 checksum of a file
file_checksum() {
  md5sum "$1" 2>/dev/null | cut -d' ' -f1
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

# --- Frame capture: basic ---
echo ""
echo "=== Frame Capture ==="
assert_http_ok_with_content_type "snapshot.jpg" "$BASE_URL/player/$slot1/screen/snapshot.jpg" "image/jpeg"

# --- Image validation: valid JPEG ---
echo ""
echo "=== Image Validation ==="
fetch_snapshot "$slot1" "$TMPDIR/frame1.jpg"
assert_valid_jpeg "snapshot is valid JPEG" "$TMPDIR/frame1.jpg"
assert_image_dimensions "snapshot dimensions" "$TMPDIR/frame1.jpg" 320 240

size1=$(wc -c < "$TMPDIR/frame1.jpg")
if [ "$size1" -gt 1000 ]; then
  pass "snapshot has substantial content (${size1}B)"
else
  fail "snapshot too small (${size1}B) — likely blank or corrupt"
fi

# --- Frames are updating (different checksums over time) ---
echo ""
echo "=== Frames Updating ==="
hash1=$(file_checksum "$TMPDIR/frame1.jpg")

# Send some key input to cause screen changes, then grab another frame
curl -s "$BASE_URL/player/$slot1/key/down/Return" > /dev/null
sleep 0.3
curl -s "$BASE_URL/player/$slot1/key/up/Return" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/frame2.jpg"
hash2=$(file_checksum "$TMPDIR/frame2.jpg")
assert_valid_jpeg "second frame is valid JPEG" "$TMPDIR/frame2.jpg"

# Try a third frame with more input
curl -s "$BASE_URL/player/$slot1/key/down/Up" > /dev/null
sleep 0.3
curl -s "$BASE_URL/player/$slot1/key/up/Up" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/frame3.jpg"
hash3=$(file_checksum "$TMPDIR/frame3.jpg")

# At least 2 of the 3 frames should differ (doom title screen may be static initially)
unique_hashes=$(printf "%s\n%s\n%s\n" "$hash1" "$hash2" "$hash3" | sort -u | wc -l)
if [ "$unique_hashes" -ge 2 ]; then
  pass "frames are updating ($unique_hashes unique frames out of 3)"
else
  fail "all 3 frames identical (hash=$hash1) — capture may be stuck"
fi

# --- Key input ---
echo ""
echo "=== Key Input ==="
assert_http_ok "keydown" "$BASE_URL/player/$slot1/key/down/Up"
assert_http_ok "keyup" "$BASE_URL/player/$slot1/key/up/Up"
assert_http_ok "keydown space" "$BASE_URL/player/$slot1/key/down/space"
assert_http_ok "keyup space" "$BASE_URL/player/$slot1/key/up/space"

# --- Config: colorspace changes image ---
echo ""
echo "=== Config: Colorspace ==="
# Set to RGB first, capture
curl -s "$BASE_URL/player/$slot1/config/colorspace?RGB" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/rgb.jpg"
assert_valid_jpeg "RGB frame" "$TMPDIR/rgb.jpg"
assert_image_colorspace "RGB frame" "$TMPDIR/rgb.jpg" "sRGB"

# Switch to grayscale, capture
curl -s "$BASE_URL/player/$slot1/config/colorspace?Gray" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/gray.jpg"
assert_valid_jpeg "Gray frame" "$TMPDIR/gray.jpg"
assert_image_colorspace "Gray frame" "$TMPDIR/gray.jpg" "Gray"

# Verify they're actually different
rgb_hash=$(file_checksum "$TMPDIR/rgb.jpg")
gray_hash=$(file_checksum "$TMPDIR/gray.jpg")
if [ "$rgb_hash" != "$gray_hash" ]; then
  pass "colorspace change produces different image"
else
  fail "RGB and Gray frames are identical"
fi

# Reset back to RGB
curl -s "$BASE_URL/player/$slot1/config/colorspace?RGB" > /dev/null

# --- Config: quality changes file size ---
echo ""
echo "=== Config: Quality ==="
curl -s "$BASE_URL/player/$slot1/config/quality?15" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/q15.jpg"
assert_valid_jpeg "quality 15 frame" "$TMPDIR/q15.jpg"
q15_size=$(wc -c < "$TMPDIR/q15.jpg")
q15_quality=$(get_image_quality "$TMPDIR/q15.jpg")

curl -s "$BASE_URL/player/$slot1/config/quality?100" > /dev/null
sleep 1
fetch_snapshot "$slot1" "$TMPDIR/q100.jpg"
assert_valid_jpeg "quality 100 frame" "$TMPDIR/q100.jpg"
q100_size=$(wc -c < "$TMPDIR/q100.jpg")
q100_quality=$(get_image_quality "$TMPDIR/q100.jpg")

echo "  quality 15: ${q15_size}B (Q=${q15_quality}), quality 100: ${q100_size}B (Q=${q100_quality})"
if [ "$q100_size" -gt "$q15_size" ]; then
  pass "higher quality produces larger file (${q15_size}B < ${q100_size}B)"
else
  fail "quality 100 (${q100_size}B) should be larger than quality 15 (${q15_size}B)"
fi

# Reset quality
curl -s "$BASE_URL/player/$slot1/config/quality?50" > /dev/null

# --- Heartbeat ---
echo ""
echo "=== Heartbeat ==="
assert_http_ok "heartbeat" "$BASE_URL/player/$slot1/heartbeat"

# --- Reset: game restarts, frames still valid ---
echo ""
echo "=== Reset ==="
assert_http_ok "reset game" "$BASE_URL/player/$slot1/reset"
sleep 4
fetch_snapshot "$slot1" "$TMPDIR/after_reset.jpg"
assert_valid_jpeg "frame after reset" "$TMPDIR/after_reset.jpg"
assert_image_dimensions "frame after reset dimensions" "$TMPDIR/after_reset.jpg" 320 240
post_reset_size=$(wc -c < "$TMPDIR/after_reset.jpg")
if [ "$post_reset_size" -gt 1000 ]; then
  pass "frame after reset has content (${post_reset_size}B)"
else
  fail "frame after reset too small (${post_reset_size}B)"
fi

# --- Multi-Slot: join second slot, verify isolation ---
echo ""
echo "=== Multi-Slot ==="
join2_response=$(curl -s --max-time 10 "$BASE_URL/join")
slot2=$(echo "$join2_response" | sed -n 's/.*"slot":\([0-9]*\).*/\1/p')

if [ -n "$slot2" ] && [ "$slot2" -ge 1 ] && [ "$slot2" != "$slot1" ]; then
  pass "joined second slot $slot2 (different from $slot1)"
else
  fail "second join failed or same slot (response: $join2_response)"
fi

sleep 5

if [ -n "$slot2" ] && [ "$slot2" -ge 1 ]; then
  # Both slots serve valid frames
  fetch_snapshot "$slot1" "$TMPDIR/slot1.jpg"
  fetch_snapshot "$slot2" "$TMPDIR/slot2.jpg"

  assert_valid_jpeg "slot $slot1 frame" "$TMPDIR/slot1.jpg"
  assert_valid_jpeg "slot $slot2 frame" "$TMPDIR/slot2.jpg"
  assert_image_dimensions "slot $slot1 dimensions" "$TMPDIR/slot1.jpg" 320 240
  assert_image_dimensions "slot $slot2 dimensions" "$TMPDIR/slot2.jpg" 320 240

  s1_size=$(wc -c < "$TMPDIR/slot1.jpg")
  s2_size=$(wc -c < "$TMPDIR/slot2.jpg")
  if [ "$s1_size" -gt 1000 ] && [ "$s2_size" -gt 1000 ]; then
    pass "both slots have substantial frames (${s1_size}B, ${s2_size}B)"
  else
    fail "one or both slots have tiny frames (${s1_size}B, ${s2_size}B)"
  fi

  # Slot isolation: set one slot to grayscale, the other stays RGB
  curl -s "$BASE_URL/player/$slot1/config/colorspace?Gray" > /dev/null
  curl -s "$BASE_URL/player/$slot2/config/colorspace?RGB" > /dev/null
  sleep 1
  fetch_snapshot "$slot1" "$TMPDIR/iso_slot1.jpg"
  fetch_snapshot "$slot2" "$TMPDIR/iso_slot2.jpg"

  s1_cs=$(identify -format "%[colorspace]" "$TMPDIR/iso_slot1.jpg" 2>/dev/null) || true
  s2_cs=$(identify -format "%[colorspace]" "$TMPDIR/iso_slot2.jpg" 2>/dev/null) || true
  if echo "$s1_cs" | grep -qi "Gray" && echo "$s2_cs" | grep -qi "sRGB"; then
    pass "slot isolation: slot $slot1 is Gray, slot $slot2 is sRGB"
  else
    fail "slot isolation: expected Gray/sRGB, got $s1_cs/$s2_cs"
  fi
  # Reset
  curl -s "$BASE_URL/player/$slot1/config/colorspace?RGB" > /dev/null

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

  # Verify the re-joined slot serves valid frames
  sleep 4
  fetch_snapshot "$rejoin_slot" "$TMPDIR/rejoin.jpg"
  assert_valid_jpeg "re-joined slot frame" "$TMPDIR/rejoin.jpg"
  assert_image_dimensions "re-joined slot dimensions" "$TMPDIR/rejoin.jpg" 320 240

  curl -s "$BASE_URL/leave/$rejoin_slot" > /dev/null
else
  fail "re-join failed"
fi

# --- Cleanup ---
rm -rf "$TMPDIR"

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
