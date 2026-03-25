#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUS_SCRIPT="$SCRIPT_DIR/../scripts/status.sh"

TESTS_RUN=0
TESTS_PASSED=0

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
  fi
}

# Reset defaults
tmux set -g -u @claude_icon_active 2>/dev/null || true
tmux set -g -u @claude_icon_waiting 2>/dev/null || true
tmux set -g -u @claude_color_active 2>/dev/null || true
tmux set -g -u @claude_color_waiting 2>/dev/null || true
tmux set -g -u @claude_show_session_name 2>/dev/null || true
tmux set -g -u @claude_separator 2>/dev/null || true

echo "=== status.sh rendering tests ==="

# Test: Current pane set to "active" → blue icon with session name
tmux set -p @claude_state "active"
result=$(bash "$STATUS_SCRIPT")
assert_eq "active state contains default color" "true" "$(echo "$result" | grep -q 'fg=colour39' && echo true || echo false)"
assert_eq "active state contains dot icon" "true" "$(echo "$result" | grep -q '●' && echo true || echo false)"

# Test: Current pane set to "waiting" → red icon
tmux set -p @claude_state "waiting"
result=$(bash "$STATUS_SCRIPT")
assert_eq "waiting state contains default color" "true" "$(echo "$result" | grep -q 'fg=colour196' && echo true || echo false)"

# Test: Custom icons via tmux options
tmux set -g @claude_icon_active '▶'
tmux set -g @claude_color_active 'blue'
tmux set -p @claude_state "active"
result=$(bash "$STATUS_SCRIPT")
assert_eq "custom icon used" "true" "$(echo "$result" | grep -q '▶' && echo true || echo false)"
assert_eq "custom color used" "true" "$(echo "$result" | grep -q 'fg=blue' && echo true || echo false)"

# Reset custom options
tmux set -g -u @claude_icon_active 2>/dev/null || true
tmux set -g -u @claude_color_active 2>/dev/null || true

# Clean up
tmux set -p -u @claude_state 2>/dev/null || true

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] || exit 1
