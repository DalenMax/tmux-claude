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
