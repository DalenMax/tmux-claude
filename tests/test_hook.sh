#!/usr/bin/env bash
set -euo pipefail

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

HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/../scripts/hook.sh"

# Helper: get current pane's @claude_state
get_state() {
  tmux show-options -p -q -v @claude_state 2>/dev/null || echo ""
}

# Clean up before tests
tmux set -p -u @claude_state 2>/dev/null || true

echo "=== hook.sh dispatch tests ==="

# Test: UserPromptSubmit sets state to "active"
echo '{"hook_event_name": "UserPromptSubmit", "session_id": "test", "prompt": "hello"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "UserPromptSubmit sets active" "active" "$result"

# Test: Notification with permission_prompt sets state to "waiting"
echo '{"hook_event_name": "Notification", "session_id": "test", "notification_type": "permission_prompt", "message": "test"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "Notification permission_prompt sets waiting" "waiting" "$result"

# Test: Notification with idle_prompt sets state to "waiting"
echo '{"hook_event_name": "Notification", "session_id": "test", "notification_type": "idle_prompt", "message": "test"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "Notification idle_prompt sets waiting" "waiting" "$result"

# Test: Notification with elicitation_dialog sets state to "waiting"
echo '{"hook_event_name": "Notification", "session_id": "test", "notification_type": "elicitation_dialog", "message": "test"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "Notification elicitation_dialog sets waiting" "waiting" "$result"

# Test: Notification with auth_success does NOT change state
# First set to active, then send auth_success, state should remain active
echo '{"hook_event_name": "UserPromptSubmit", "session_id": "test", "prompt": "hello"}' | bash "$HOOK_SCRIPT"
echo '{"hook_event_name": "Notification", "session_id": "test", "notification_type": "auth_success", "message": "test"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "Notification auth_success is no-op" "active" "$result"

# Test: SessionEnd unsets state
echo '{"hook_event_name": "SessionEnd", "session_id": "test", "reason": "logout"}' | bash "$HOOK_SCRIPT"
result=$(get_state)
assert_eq "SessionEnd unsets state" "" "$result"

# Test: Invalid JSON exits silently (no crash)
echo 'not json' | bash "$HOOK_SCRIPT" 2>/dev/null
hook_exit=$?
assert_eq "invalid JSON exits silently" "0" "$hook_exit"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] || exit 1
