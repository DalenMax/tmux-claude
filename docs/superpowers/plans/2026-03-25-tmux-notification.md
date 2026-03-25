# tmux-notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a TPM-compatible tmux plugin that shows Claude Code session states (active/waiting) in the tmux status bar using Claude Code hooks and tmux per-pane user variables.

**Architecture:** Claude Code hooks fire on events (Notification, UserPromptSubmit, SessionEnd) and call `hook.sh`, which walks the process tree to discover its tmux pane, then sets the `@claude_state` per-pane variable. `status.sh` aggregates all pane states and renders compact colored icons for the tmux status bar.

**Tech Stack:** Bash (3.2+ compatible — no associative arrays), jq, tmux APIs (list-panes, set-option, show-option)

**Spec:** `docs/superpowers/specs/2026-03-25-tmux-claude-notification-design.md`

---

## File Structure

```
tmux-notification/
├── notification.tmux              # TPM entry point — registers option defaults
├── scripts/
│   ├── utils.sh                   # Shared helpers: pane discovery, logging, option reading
│   ├── hook.sh                    # Claude Code hook handler — parses JSON, sets @claude_state
│   ├── status.sh                  # Status bar renderer — aggregates states, outputs icons
│   └── setup.sh                   # Claude Code hook configuration (--apply / --remove / dry-run)
├── tests/
│   ├── test_utils.sh              # Tests for pane discovery and helpers
│   ├── test_hook.sh               # Tests for hook dispatch logic
│   ├── test_status.sh             # Tests for status bar rendering
│   └── test_setup.sh              # Tests for setup.sh merge/remove logic
├── docs/
│   └── superpowers/
│       ├── specs/                 # Design spec (already exists)
│       └── plans/                 # This plan (already exists)
└── README.md
```

### File Responsibilities

| File | Responsibility |
|------|----------------|
| `notification.tmux` | TPM entry point. Registers `@claude_*` option defaults. Prints setup hint if hooks not configured. |
| `scripts/utils.sh` | `find_pane_target()` — process tree walk to discover tmux pane. `log_debug()` — conditional debug logging. `get_option()` — read tmux option with fallback default. |
| `scripts/hook.sh` | Entry point for all Claude Code hooks. Reads JSON from stdin with jq. Dispatches on `hook_event_name`. Calls `find_pane_target()`, then sets/unsets `@claude_state`. |
| `scripts/status.sh` | Called by tmux status bar via `#(path/to/status.sh)`. Reads all pane states, groups by session, picks most urgent state, renders colored icons. |
| `scripts/setup.sh` | CLI tool for managing Claude Code hook configuration. `--apply` merges hooks into `~/.claude/settings.json` (idempotent). `--remove` strips them out. No flag = dry run. |

---

## Task 1: utils.sh — Shared Helpers

**Files:**
- Create: `scripts/utils.sh`
- Create: `tests/test_utils.sh`

- [ ] **Step 1: Write test for `get_option` helper**

Create `tests/test_utils.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_utils.sh`
Expected: FAIL — `scripts/utils.sh` does not exist yet.

- [ ] **Step 3: Write `scripts/utils.sh`**

Create `scripts/utils.sh`:

```bash
#!/usr/bin/env bash
# utils.sh — shared helpers for tmux-notification plugin

# Read a tmux global option with a fallback default.
# Usage: get_option "@option_name" "default_value"
get_option() {
  local option="$1"
  local default="$2"
  local value
  value=$(tmux show-option -gqv "$option" 2>/dev/null)
  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# Walk the process tree from current PID upward to find the tmux pane.
# Outputs the pane target (e.g., "session:0.1") or empty string if not found.
find_pane_target() {
  # Check if tmux is available
  if ! command -v tmux &>/dev/null; then
    return
  fi

  local pane_map
  pane_map=$(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return

  local pid=$$
  local max_depth=50
  local i=0
  local match

  while [ "$pid" -gt 1 ] && [ "$i" -lt "$max_depth" ]; do
    match=$(echo "$pane_map" | awk -v p="$pid" '$1 == p {print $2}')
    if [ -n "$match" ]; then
      echo "$match"
      return
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ]; then
      return
    fi
    i=$((i + 1))
  done
}

# Log a debug message if debug mode is enabled.
# Usage: log_debug "message"
log_debug() {
  local debug
  debug=$(get_option "@claude_debug" "off")
  if [ "$debug" = "on" ]; then
    local log_file="/tmp/tmux-notification-$(id -u).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$log_file"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_utils.sh`
Expected: All 4 tests PASS.

- [ ] **Step 5: Make scripts executable and commit**

```bash
chmod +x scripts/utils.sh tests/test_utils.sh
git add scripts/utils.sh tests/test_utils.sh
git commit -m "feat: add utils.sh with pane discovery, option reading, debug logging"
```

---

## Task 2: hook.sh — Claude Code Hook Handler

**Files:**
- Create: `scripts/hook.sh`
- Create: `tests/test_hook.sh`
- Read: `scripts/utils.sh`

- [ ] **Step 1: Write test for hook dispatch logic**

Create `tests/test_hook.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_hook.sh`
Expected: FAIL — `scripts/hook.sh` does not exist yet.

- [ ] **Step 3: Write `scripts/hook.sh`**

Create `scripts/hook.sh`:

```bash
#!/usr/bin/env bash
# hook.sh — Claude Code hook handler for tmux-notification
# Called by Claude Code hooks. Reads JSON from stdin, sets @claude_state on the tmux pane.

# Intentional: set -e causes silent exit on any error, which is the desired behavior
# for a hook script — we must never block Claude Code with error output.
set -euo pipefail

# Check for jq
if ! command -v jq &>/dev/null; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Read JSON from stdin
INPUT=$(cat)

# Parse hook event name
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
if [ -z "$EVENT" ]; then
  exit 0
fi

log_debug "hook.sh received event: $EVENT"

# Find which tmux pane we belong to
PANE_TARGET=$(find_pane_target)
if [ -z "$PANE_TARGET" ]; then
  log_debug "hook.sh: no tmux pane found, exiting"
  exit 0
fi

log_debug "hook.sh: pane target is $PANE_TARGET"

# Dispatch based on event
case "$EVENT" in
  UserPromptSubmit)
    tmux set -p -t "$PANE_TARGET" @claude_state "active"
    log_debug "hook.sh: set active on $PANE_TARGET"
    ;;
  Notification)
    NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty' 2>/dev/null) || exit 0
    case "$NOTIFICATION_TYPE" in
      permission_prompt|idle_prompt|elicitation_dialog)
        tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
        log_debug "hook.sh: set waiting on $PANE_TARGET ($NOTIFICATION_TYPE)"
        ;;
      *)
        log_debug "hook.sh: ignoring notification type: $NOTIFICATION_TYPE"
        ;;
    esac
    ;;
  SessionEnd)
    tmux set -p -t "$PANE_TARGET" -u @claude_state 2>/dev/null || true
    log_debug "hook.sh: unset state on $PANE_TARGET"
    ;;
  *)
    log_debug "hook.sh: ignoring unknown event: $EVENT"
    ;;
esac

exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_hook.sh`
Expected: All 7 tests PASS.

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x scripts/hook.sh tests/test_hook.sh
git add scripts/hook.sh tests/test_hook.sh
git commit -m "feat: add hook.sh with event dispatch for Claude Code hooks"
```

---

## Task 3: status.sh — Status Bar Renderer

**Files:**
- Create: `scripts/status.sh`
- Create: `tests/test_status.sh`
- Read: `scripts/utils.sh`

- [ ] **Step 1: Write test for status rendering**

Create `tests/test_status.sh`:

```bash
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

# Test: No state set on any pane → empty output
tmux set -p -u @claude_state 2>/dev/null || true
result=$(bash "$STATUS_SCRIPT")
assert_eq "no state produces empty output" "" "$result"

# Test: Current pane set to "active" → green icon with session name
tmux set -p @claude_state "active"
result=$(bash "$STATUS_SCRIPT")
# Should contain a green icon
assert_eq "active state contains green" "true" "$(echo "$result" | grep -q 'fg=green' && echo true || echo false)"
assert_eq "active state contains dot icon" "true" "$(echo "$result" | grep -q '●' && echo true || echo false)"

# Test: Current pane set to "waiting" → yellow icon
tmux set -p @claude_state "waiting"
result=$(bash "$STATUS_SCRIPT")
assert_eq "waiting state contains yellow" "true" "$(echo "$result" | grep -q 'fg=yellow' && echo true || echo false)"

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
```

Note: Multi-session grouping and priority logic (waiting > active) is difficult to test in a single-pane test environment since we cannot create panes in other sessions from within a test script. This is covered by the integration tests in Task 7. The awk-based grouping logic is straightforward — `asorti` + priority check — and correctness is verifiable by inspection.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_status.sh`
Expected: FAIL — `scripts/status.sh` does not exist yet.

- [ ] **Step 3: Write `scripts/status.sh`**

Create `scripts/status.sh`:

```bash
#!/usr/bin/env bash
# status.sh — tmux status bar renderer for Claude Code pane states
# Called by tmux via #(path/to/status.sh) in status-left or status-right.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Read config options with defaults
ICON_ACTIVE=$(get_option "@claude_icon_active" "●")
ICON_WAITING=$(get_option "@claude_icon_waiting" "●")
COLOR_ACTIVE=$(get_option "@claude_color_active" "green")
COLOR_WAITING=$(get_option "@claude_color_waiting" "yellow")
SHOW_SESSION=$(get_option "@claude_show_session_name" "yes")
SEPARATOR=$(get_option "@claude_separator" " ")
STALE_CHECK=$(get_option "@claude_stale_check" "off")

# Get all panes with @claude_state set
# Format: session_name state
# Uses awk for grouping to avoid bash associative arrays (not available in bash 3.2 on macOS)
pane_data=$(tmux list-panes -a -F '#{session_name} #{@claude_state}' 2>/dev/null) || exit 0

# Use awk to:
# 1. Filter panes with no state
# 2. Group by session, pick most urgent state (waiting > active)
# 3. Render output with tmux color codes
echo -n "$(echo "$pane_data" | awk -v icon_active="$ICON_ACTIVE" \
    -v icon_waiting="$ICON_WAITING" \
    -v color_active="$COLOR_ACTIVE" \
    -v color_waiting="$COLOR_WAITING" \
    -v show_session="$SHOW_SESSION" \
    -v separator="$SEPARATOR" \
    '
    $2 != "" {
      session = $1
      state = $2
      # Priority: waiting > active (only upgrade, never downgrade)
      if (!(session in states) || state == "waiting") {
        states[session] = state
      }
    }
    END {
      # Collect session names and sort (POSIX awk compatible — no asorti)
      n = 0
      for (s in states) {
        sorted[n++] = s
      }
      # Simple insertion sort (session count is small)
      for (i = 1; i < n; i++) {
        key = sorted[i]
        j = i - 1
        while (j >= 0 && sorted[j] > key) {
          sorted[j+1] = sorted[j]
          j--
        }
        sorted[j+1] = key
      }
      first = 1
      for (i = 0; i < n; i++) {
        session = sorted[i]
        state = states[session]
        if (!first) printf "%s", separator
        first = 0
        if (state == "waiting") {
          icon = "#[fg=" color_waiting "]" icon_waiting "#[default]"
        } else {
          icon = "#[fg=" color_active "]" icon_active "#[default]"
        }
        if (show_session == "yes") {
          printf "%s:%s", session, icon
        } else {
          printf "%s", icon
        }
      }
    }
    ')"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_status.sh`
Expected: All 4 tests PASS.

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x scripts/status.sh tests/test_status.sh
git add scripts/status.sh tests/test_status.sh
git commit -m "feat: add status.sh for tmux status bar rendering"
```

---

## Task 4: setup.sh — Hook Configuration Manager

**Files:**
- Create: `scripts/setup.sh`
- Create: `tests/test_setup.sh`

- [ ] **Step 1: Write test for setup.sh**

Create `tests/test_setup.sh`:

```bash
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

# Test: dry run (no flags) prints JSON but does not modify file
output=$(bash "$SETUP_SCRIPT" 2>&1)
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
has_notification=$(cat "$CLAUDE_SETTINGS_FILE" | jq 'has("hooks")')
# hooks key should be gone or empty
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_setup.sh`
Expected: FAIL — `scripts/setup.sh` does not exist yet.

- [ ] **Step 3: Write `scripts/setup.sh`**

Create `scripts/setup.sh`:

```bash
#!/usr/bin/env bash
# setup.sh — Configure Claude Code hooks for tmux-notification
# Usage:
#   setup.sh            # Dry run: print the hooks JSON
#   setup.sh --apply    # Write hooks to ~/.claude/settings.json
#   setup.sh --remove   # Remove hooks from ~/.claude/settings.json

set -euo pipefail

# Check for jq
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "Install it with: brew install jq (macOS) or apt install jq (Linux)" >&2
  exit 1
fi

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hook.sh"

# Settings file (can be overridden for testing via CLAUDE_SETTINGS_FILE env var)
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# Build the hook entry for a given event
build_hook_entry() {
  jq -n --arg cmd "$HOOK_SCRIPT" '[{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]'
}

# Build the full hooks config
build_hooks_config() {
  local hook_entry
  hook_entry=$(build_hook_entry)
  jq -n \
    --argjson entry "$hook_entry" \
    '{
      "hooks": {
        "Notification": $entry,
        "UserPromptSubmit": $entry,
        "SessionEnd": $entry
      }
    }'
}

# Check if our hook already exists in an event's hook array
has_our_hook() {
  local settings="$1" event="$2"
  echo "$settings" | jq -e --arg cmd "$HOOK_SCRIPT" \
    ".hooks[\"$event\"] // [] | map(select(.hooks[]?.command == \$cmd)) | length > 0" \
    >/dev/null 2>&1
}

apply_hooks() {
  # Ensure settings directory exists
  local settings_dir
  settings_dir=$(dirname "$SETTINGS_FILE")
  mkdir -p "$settings_dir"

  # Read existing settings or start with empty object
  local settings
  if [ -f "$SETTINGS_FILE" ]; then
    settings=$(cat "$SETTINGS_FILE")
  else
    settings='{}'
  fi

  local hook_entry
  hook_entry=$(jq -n --arg cmd "$HOOK_SCRIPT" '{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}')

  for event in Notification UserPromptSubmit SessionEnd; do
    if has_our_hook "$settings" "$event"; then
      continue
    fi
    settings=$(echo "$settings" | jq --argjson entry "$hook_entry" \
      ".hooks[\"$event\"] = ((.hooks[\"$event\"] // []) + [\$entry])")
  done

  echo "$settings" | jq '.' > "$SETTINGS_FILE"
  echo "Hooks configured in $SETTINGS_FILE"
  echo "Hook script: $HOOK_SCRIPT"
}

remove_hooks() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "No settings file found at $SETTINGS_FILE"
    return
  fi

  local settings
  settings=$(cat "$SETTINGS_FILE")

  for event in Notification UserPromptSubmit SessionEnd; do
    settings=$(echo "$settings" | jq --arg cmd "$HOOK_SCRIPT" \
      "if .hooks[\"$event\"] then
        .hooks[\"$event\"] |= map(select(.hooks | all(.command != \$cmd)))
        | if .hooks[\"$event\"] | length == 0 then del(.hooks[\"$event\"]) else . end
      else . end")
  done

  # Clean up empty hooks object
  settings=$(echo "$settings" | jq 'if .hooks == {} then del(.hooks) else . end')

  echo "$settings" | jq '.' > "$SETTINGS_FILE"
  echo "Hooks removed from $SETTINGS_FILE"
}

# Main
case "${1:-}" in
  --apply)
    apply_hooks
    ;;
  --remove)
    remove_hooks
    ;;
  *)
    echo "Dry run — this is what would be added to $SETTINGS_FILE:" >&2
    build_hooks_config
    echo "" >&2
    echo "Run with --apply to write, or --remove to clean up." >&2
    ;;
esac
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_setup.sh`
Expected: All 10 tests PASS.

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x scripts/setup.sh tests/test_setup.sh
git add scripts/setup.sh tests/test_setup.sh
git commit -m "feat: add setup.sh for Claude Code hook configuration"
```

---

## Task 5: notification.tmux — TPM Entry Point

**Files:**
- Create: `notification.tmux`
- Read: `scripts/utils.sh`

- [ ] **Step 1: Write `notification.tmux`**

Create `notification.tmux`:

```bash
#!/usr/bin/env bash
# notification.tmux — TPM entry point for tmux-notification plugin
# Registers default option values for @claude_* options.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$CURRENT_DIR/scripts/utils.sh"

# Register defaults (only sets if not already configured by user)
# Avoids declare -A for bash 3.2 compatibility (macOS default)
set_default() {
  local option="$1" value="$2"
  local current
  current=$(tmux show-option -gqv "$option" 2>/dev/null)
  if [ -z "$current" ]; then
    tmux set-option -g "$option" "$value"
  fi
}

set_default "@claude_icon_active" "●"
set_default "@claude_icon_waiting" "●"
set_default "@claude_color_active" "green"
set_default "@claude_color_waiting" "yellow"
set_default "@claude_show_session_name" "yes"
set_default "@claude_separator" " "
set_default "@claude_stale_check" "off"
set_default "@claude_debug" "off"

# Check if hooks are configured
HOOK_SCRIPT="$CURRENT_DIR/scripts/hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
  if ! grep -q "$HOOK_SCRIPT" "$SETTINGS_FILE" 2>/dev/null; then
    tmux display-message "tmux-notification: Run $CURRENT_DIR/scripts/setup.sh --apply to configure Claude Code hooks"
  fi
else
  tmux display-message "tmux-notification: Run $CURRENT_DIR/scripts/setup.sh --apply to configure Claude Code hooks"
fi
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x notification.tmux
git add notification.tmux
git commit -m "feat: add notification.tmux TPM entry point"
```

---

## Task 6: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

Create `README.md`:

```markdown
# tmux-notification

A tmux plugin that shows when [Claude Code](https://claude.ai/code) needs your attention in other tmux sessions/panes.

When running Claude Code across multiple tmux sessions, this plugin displays compact status icons in your tmux status bar so you know which sessions are active and which are waiting for input — without switching panes.

## How It Works

```
Claude Code hook event → hook.sh → sets tmux pane variable → status bar reads it
```

Uses Claude Code's [hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) to detect state changes. No daemons, no polling, no temp files.

## Requirements

- tmux (with TPM)
- jq
- Claude Code (with hook support)

## Installation

### 1. Add plugin to `.tmux.conf`

```bash
set -g @plugin 'raki/tmux-notification'
```

Press `prefix + I` to install.

### 2. Add to your status bar

Place this wherever you want in your `status-right` (or `status-left`):

```bash
set -g status-right '#{status-right} #(~/.tmux/plugins/tmux-notification/scripts/status.sh)'
```

### 3. Configure Claude Code hooks

```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --apply
```

That's it. Restart Claude Code and you'll see status icons appear.

## Status Icons

| Icon | Color | Meaning |
|------|-------|---------|
| ● | Green | Claude is working |
| ● | Yellow | Claude needs your input |

Example status bar: `proj1:● proj2:●` (proj1 active, proj2 waiting)

## Configuration

All options are set via tmux options in `.tmux.conf`:

```bash
# Icons (default: ●)
set -g @claude_icon_active '●'
set -g @claude_icon_waiting '●'

# Colors (default: green/yellow)
set -g @claude_color_active 'green'
set -g @claude_color_waiting 'yellow'

# Show session name prefix (default: yes)
set -g @claude_show_session_name 'yes'

# Separator between entries (default: ' ')
set -g @claude_separator ' '

# Debug logging (default: off)
set -g @claude_debug 'on'
```

## Uninstall

Remove hooks from Claude Code:

```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --remove
```

Then remove the plugin line from `.tmux.conf` and press `prefix + alt + u`.

## How It Detects State

The plugin uses three Claude Code hook events:

- **UserPromptSubmit** — User sent a prompt → state = `active`
- **Notification** (permission_prompt, idle_prompt, elicitation_dialog) — Claude needs input → state = `waiting`
- **SessionEnd** — Claude exited → state cleared

State is stored in tmux per-pane user variables (`@claude_state`), so there are no external files or processes.

## Troubleshooting

**No icons showing:**
1. Check hooks are configured: `cat ~/.claude/settings.json | jq '.hooks'`
2. Restart Claude Code after setting up hooks
3. Verify `status.sh` is in your status bar: `tmux show -g status-right`

**Enable debug logging:**
```bash
set -g @claude_debug 'on'
# Logs go to /tmp/tmux-notification-<uid>.log
```

**Status bar updates too slowly:**
```bash
# Lower the refresh interval (default is 15s)
set -g status-interval 5
```

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with installation and usage instructions"
```

---

## Task 7: Integration Test — End-to-End Verification

**Files:**
- Read: all scripts

- [ ] **Step 1: Run all unit tests**

```bash
bash tests/test_utils.sh && bash tests/test_hook.sh && bash tests/test_status.sh && bash tests/test_setup.sh
```

Expected: All tests pass.

- [ ] **Step 2: Manual integration test — set state via hook.sh**

```bash
# Simulate UserPromptSubmit
echo '{"hook_event_name":"UserPromptSubmit","session_id":"test","prompt":"hi"}' | bash scripts/hook.sh

# Check state was set
tmux show-options -p -v @claude_state
# Expected: active

# Check status.sh output
bash scripts/status.sh
# Expected: contains session name and green icon
```

- [ ] **Step 3: Manual integration test — waiting state**

```bash
# Simulate Notification with idle_prompt
echo '{"hook_event_name":"Notification","session_id":"test","notification_type":"idle_prompt","message":"done"}' | bash scripts/hook.sh

# Check state
tmux show-options -p -v @claude_state
# Expected: waiting

# Check status output
bash scripts/status.sh
# Expected: contains session name and yellow icon
```

- [ ] **Step 4: Manual integration test — session end**

```bash
# Simulate SessionEnd
echo '{"hook_event_name":"SessionEnd","session_id":"test","reason":"logout"}' | bash scripts/hook.sh

# Check state is cleared
tmux show-options -p -v @claude_state
# Expected: empty/no output

# Check status output
bash scripts/status.sh
# Expected: empty (no active sessions)
```

- [ ] **Step 5: Manual integration test — setup.sh dry run and apply**

```bash
# Dry run
bash scripts/setup.sh

# Apply to a test file
CLAUDE_SETTINGS_FILE=/tmp/test-claude-settings.json bash scripts/setup.sh --apply
cat /tmp/test-claude-settings.json | jq .

# Remove
CLAUDE_SETTINGS_FILE=/tmp/test-claude-settings.json bash scripts/setup.sh --remove
cat /tmp/test-claude-settings.json | jq .

# Clean up
rm /tmp/test-claude-settings.json
```

- [ ] **Step 6: Commit any fixes from integration testing**

```bash
git add -A
git commit -m "fix: integration test fixes" # Only if changes were needed
```
