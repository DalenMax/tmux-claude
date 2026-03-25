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
