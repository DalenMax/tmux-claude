#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../scripts/setup.sh"
HOOK_SCRIPT="$SCRIPT_DIR/../scripts/hook.sh"

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

# Use a temp file instead of real settings
export CLAUDE_SETTINGS_FILE=$(mktemp)
echo '{}' > "$CLAUDE_SETTINGS_FILE"

echo "=== setup.sh tests ==="

# Test: dry run (no flags) outputs JSON to stdout, does not modify file
# Note: dry run sends informational text to stderr and JSON to stdout
output=$(bash "$SETUP_SCRIPT" 2>/dev/null)
assert_eq "dry run prints hook config" "true" "$(echo "$output" | jq -e '.hooks.Notification' >/dev/null 2>&1 && echo true || echo false)"
file_content=$(cat "$CLAUDE_SETTINGS_FILE")
assert_eq "dry run does not modify file" '{}' "$file_content"

# Test: --apply writes hooks to settings file
bash "$SETUP_SCRIPT" --apply
file_content=$(cat "$CLAUDE_SETTINGS_FILE")
assert_eq "apply creates Notification hook" "true" "$(echo "$file_content" | jq -e '.hooks.Notification' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "apply creates UserPromptSubmit hook" "true" "$(echo "$file_content" | jq -e '.hooks.UserPromptSubmit' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "apply creates SessionEnd hook" "true" "$(echo "$file_content" | jq -e '.hooks.SessionEnd' >/dev/null 2>&1 && echo true || echo false)"

# Test: --apply is idempotent (running twice doesn't duplicate)
bash "$SETUP_SCRIPT" --apply
count=$(cat "$CLAUDE_SETTINGS_FILE" | jq '.hooks.Notification | length')
assert_eq "apply is idempotent" "1" "$count"

# Test: --apply preserves existing settings
echo '{"customSetting": true}' > "$CLAUDE_SETTINGS_FILE"
bash "$SETUP_SCRIPT" --apply
has_custom=$(cat "$CLAUDE_SETTINGS_FILE" | jq -r '.customSetting')
assert_eq "apply preserves existing settings" "true" "$has_custom"

# Test: --remove strips hooks
bash "$SETUP_SCRIPT" --apply
bash "$SETUP_SCRIPT" --remove
remaining=$(cat "$CLAUDE_SETTINGS_FILE" | jq '.hooks // {} | keys | length')
assert_eq "remove strips all plugin hooks" "0" "$remaining"

# Test: --remove preserves other hooks
echo '{"hooks":{"Notification":[{"matcher":"","hooks":[{"type":"command","command":"other-script.sh"}]}]}}' > "$CLAUDE_SETTINGS_FILE"
bash "$SETUP_SCRIPT" --apply
bash "$SETUP_SCRIPT" --remove
other_count=$(cat "$CLAUDE_SETTINGS_FILE" | jq '.hooks.Notification | length')
assert_eq "remove preserves other hooks" "1" "$other_count"

# Clean up
rm -f "$CLAUDE_SETTINGS_FILE"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_PASSED" -eq "$TESTS_RUN" ] || exit 1
