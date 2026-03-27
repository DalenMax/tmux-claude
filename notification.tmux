#!/usr/bin/env bash
# notification.tmux — TPM entry point for tmux-claude plugin
# Auto-configures everything: option defaults, status bar, and Claude Code hooks.

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

set_default "@claude_icon_active" "▶"
set_default "@claude_icon_waiting" "⏸"
set_default "@claude_color_active" "colour34"
set_default "@claude_color_waiting" "colour214"
set_default "@claude_show_session_name" "yes"
set_default "@claude_separator" " "
set_default "@claude_stale_check" "off"
set_default "@claude_sound" "off"
set_default "@claude_sound_file" ""
set_default "@claude_debug" "off"

# Use the second status bar for Claude status.
# Runs twice: now (in case we load last) and after a delay (in case theme overwrites us).
STATUS_SCRIPT="$CURRENT_DIR/scripts/status.sh"
tmux set -g status 2
tmux set -g 'status-format[1]' "#[align=right]#(${STATUS_SCRIPT})"

# Re-apply after themes finish loading (themes may overwrite status-format[1])
( sleep 2; tmux set -g 'status-format[1]' "#[align=right]#(${STATUS_SCRIPT})" ) &

# Auto-configure Claude Code hooks (idempotent — safe to run every time)
HOOK_SCRIPT="$CURRENT_DIR/scripts/hook.sh"
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
  if ! grep -Fq "$HOOK_SCRIPT" "$SETTINGS_FILE" 2>/dev/null; then
    "$CURRENT_DIR/scripts/setup.sh" --apply >/dev/null 2>&1
  fi
else
  "$CURRENT_DIR/scripts/setup.sh" --apply >/dev/null 2>&1
fi
