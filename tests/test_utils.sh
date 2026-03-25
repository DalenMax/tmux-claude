#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../scripts/utils.sh"

TESTS_RUN=0
TESTS_PASSED=0

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  PASS: $desc"
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
  fi
}

echo "=== get_option tests ==="

# Test: returns default when option is not set
tmux set -g -u @claude_test_option 2>/dev/null || true
result=$(get_option "@claude_test_option" "fallback_value")
assert_eq "returns default when unset" "fallback_value" "$result"

# Test: returns value when option is set
tmux set -g @claude_test_option "custom_value"
result=$(get_option "@claude_test_option" "fallback_value")
assert_eq "returns set value" "custom_value" "$result"
tmux set -g -u @claude_test_option

echo ""
echo "=== find_pane_target tests ==="

# Test: finds current pane from own PID
result=$(find_pane_target)
assert_eq "finds a pane target from own PID" "true" "$([ -n "$result" ] && echo true || echo false)"

# Test: result matches valid tmux pane format (session:window.pane)
assert_eq "pane target matches format" "true" "$(echo "$result" | grep -qE '^.+:[0-9]+\.[0-9]+$' && echo true || echo false)"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] || exit 1
