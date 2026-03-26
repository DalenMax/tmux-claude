#!/usr/bin/env bash
# status.sh — tmux status bar renderer for Claude Code pane states
# Called by tmux via #(path/to/status.sh) in status-left or status-right.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Read config options with defaults
ICON_ACTIVE=$(get_option "@claude_icon_active" "●")
ICON_WAITING=$(get_option "@claude_icon_waiting" "●")
COLOR_ACTIVE=$(get_option "@claude_color_active" "colour34")
COLOR_WAITING=$(get_option "@claude_color_waiting" "colour39")
SHOW_SESSION=$(get_option "@claude_show_session_name" "yes")
SEPARATOR=$(get_option "@claude_separator" " ")

# Get all panes with @claude_state set
# Format: session_name state
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
