#!/usr/bin/env bash
set -euo pipefail

# e2e tests for http-doom
# Runs against a live container and validates HTTP endpoints

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
  status=$(curl -s -o /dev/null -w "%{http_code}" "$url") || true
  if [ "$status" = "200" ]; then
    pass "$desc (HTTP $status)"
  else
    fail "$desc — expected 200, got $status"
  fi
}

assert_http_ok_with_content_type() {
  local desc="$1" url="$2" expected_type="$3"
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}|%{content_type}" "$url") || true
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
  body=$(curl -s "$url") || true
  if echo "$body" | grep -q "$expected"; then
    pass "$desc — response contains '$expected'"
  else
    fail "$desc — response missing '$expected'"
  fi
}

# --- Wait for container to be ready ---
echo "Waiting for server at $BASE_URL ..."
for i in $(seq 1 30); do
  if curl -s -o /dev/null "$BASE_URL" 2>/dev/null; then
    echo "Server ready after ${i}s"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "ERROR: Server not ready after 30s"
    exit 1
  fi
  sleep 1
done

# Give Doom a moment to start rendering frames
sleep 3

# --- Static file serving ---
echo ""
echo "=== Static Files ==="
assert_http_ok_with_content_type "index.html" "$BASE_URL/" "text/html"
assert_http_ok "logo image" "$BASE_URL/http-doom.png"
assert_http_ok "settings.js" "$BASE_URL/javascript/settings.js"
assert_http_ok "load.js" "$BASE_URL/javascript/load.js"
assert_http_ok "keys.js" "$BASE_URL/javascript/keys.js"
assert_response_contains "index has game elements" "$BASE_URL/" "snapshot"

# --- Frame capture ---
echo ""
echo "=== Frame Capture ==="
assert_http_ok_with_content_type "snapshot.jpg" "$BASE_URL/screen/snapshot.jpg" "image/jpeg"

# Verify frames are updating (two fetches should have different sizes or at least both succeed)
size1=$(curl -s "$BASE_URL/screen/snapshot.jpg" | wc -c)
sleep 0.5
size2=$(curl -s "$BASE_URL/screen/snapshot.jpg" | wc -c)
if [ "$size1" -gt 0 ] && [ "$size2" -gt 0 ]; then
  pass "snapshot.jpg has content (${size1}B, ${size2}B)"
else
  fail "snapshot.jpg is empty"
fi

# --- CGI: Key input ---
echo ""
echo "=== Key Input CGI ==="
assert_http_ok "keydown" "$BASE_URL/key/down/Up"
assert_http_ok "keyup" "$BASE_URL/key/up/Up"
assert_http_ok "keydown space" "$BASE_URL/key/down/space"
assert_http_ok "keyup space" "$BASE_URL/key/up/space"

# --- CGI: Config ---
echo ""
echo "=== Config CGI ==="
assert_http_ok "set quality" "$BASE_URL/config/quality?50"
assert_http_ok "set colorspace RGB" "$BASE_URL/config/colorspace?RGB"
assert_http_ok "set colorspace Gray" "$BASE_URL/config/colorspace?Gray"
# Reset back to defaults
curl -s "$BASE_URL/config/colorspace?RGB" > /dev/null
curl -s "$BASE_URL/config/quality?50" > /dev/null

# --- CGI: Reset ---
echo ""
echo "=== Reset CGI ==="
assert_http_ok "reset game" "$BASE_URL/reset"

# Verify game comes back after reset
sleep 3
assert_http_ok "snapshot after reset" "$BASE_URL/screen/snapshot.jpg"

# --- CGI: Status (multiplayer) ---
echo ""
echo "=== Status CGI ==="
assert_http_ok "status endpoint" "$BASE_URL/status"
assert_response_contains "status has mode" "$BASE_URL/status" "mode"

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
