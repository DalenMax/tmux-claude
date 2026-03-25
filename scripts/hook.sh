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
  Stop|StopFailure)
    # Stop fires reliably at end of every successful turn
    # StopFailure fires on API errors — Claude is still waiting for input
    tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
    log_debug "hook.sh: set waiting on $PANE_TARGET ($EVENT)"
    ;;
  PermissionRequest)
    # Fires reliably when permission dialog appears
    tmux set -p -t "$PANE_TARGET" @claude_state "waiting"
    log_debug "hook.sh: set waiting on $PANE_TARGET (permission request)"
    ;;
  Notification)
    # Backup: Notification is unreliable but still useful as a fallback
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

# Force immediate status bar refresh so the change is visible instantly
tmux refresh-client -S 2>/dev/null || true

exit 0
