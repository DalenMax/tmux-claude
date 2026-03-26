#!/usr/bin/env bash
# hook.sh — Claude Code hook handler for tmux-claude
# Called by Claude Code hooks. Reads JSON from stdin, sets @claude_state on the tmux pane.
#
# SAFETY: This script runs inside Claude Code's hook system. It MUST:
# - Never hang (watchdog kills us after 10 seconds)
# - Never output errors to stderr (redirected to /dev/null)
# - Always exit 0 (never block Claude Code)

set -eo pipefail
exec 2>/dev/null

# Watchdog: kill ourselves after 10 seconds no matter what
( sleep 10; kill $$ 2>/dev/null ) &
WATCHDOG_PID=$!
trap 'kill $WATCHDOG_PID 2>/dev/null; exit 0' EXIT

# Check for jq
if ! command -v jq &>/dev/null; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Read JSON from stdin with timeout (never hang on broken pipe)
INPUT=""
while IFS= read -r -t 5 line; do
  INPUT="${INPUT}${line}"
done

# Parse hook event name
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty') || exit 0
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

# Get current state before changing it
PREV_STATE=$(tmux show -p -t "$PANE_TARGET" -qv @claude_state 2>/dev/null || echo "")

# Dispatch based on event
NEW_STATE=""
case "$EVENT" in
  UserPromptSubmit|PostToolUse)
    # UserPromptSubmit: user sent a new prompt
    # PostToolUse: a tool just ran successfully — Claude is working
    #   (also fires after user approves a permission, fixing the
    #    PermissionRequest→approve→still-red bug)
    tmux set -p -t "$PANE_TARGET" @claude_state "active"
    log_debug "hook.sh: set active on $PANE_TARGET ($EVENT)"
    ;;
  Stop|StopFailure)
    # Stop fires reliably at end of every successful turn
    # StopFailure fires on API errors — Claude is still waiting for input
    tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
    NEW_STATE="waiting"
    log_debug "hook.sh: set waiting on $PANE_TARGET ($EVENT)"
    ;;
  PermissionRequest)
    # Fires reliably when permission dialog appears
    tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
    NEW_STATE="waiting"
    log_debug "hook.sh: set waiting on $PANE_TARGET (permission request)"
    ;;
  Notification)
    # Backup: Notification is unreliable but still useful as a fallback
    NOTIFICATION_TYPE=$(echo "$INPUT" | jq -r '.notification_type // empty') || exit 0
    case "$NOTIFICATION_TYPE" in
      permission_prompt|idle_prompt|elicitation_dialog)
        tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
        NEW_STATE="waiting"
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

# Play sound only on transition to waiting (not if already waiting)
if [ "$NEW_STATE" = "waiting" ] && [ "$PREV_STATE" != "waiting" ]; then
  play_notification_sound
fi

# Force immediate status bar refresh so the change is visible instantly
tmux refresh-client -S 2>/dev/null || true

exit 0
