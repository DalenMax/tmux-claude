#!/usr/bin/env bash
# utils.sh — shared helpers for tmux-claude plugin

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
# Uses a single ps call to grab the full process table (avoids forking per iteration).
find_pane_target() {
  # Check if tmux is available
  if ! command -v tmux &>/dev/null; then
    return
  fi

  local pane_map
  pane_map=$(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}' 2>/dev/null) || return

  # Grab entire process table once (instead of forking ps per iteration)
  local ps_table
  ps_table=$(ps -eo pid=,ppid= 2>/dev/null) || return

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
    pid=$(echo "$ps_table" | awk -v p="$pid" '$1 == p {print $2}')
    if [ -z "$pid" ]; then
      return
    fi
    i=$((i + 1))
  done
}

# Set up debug logging. Call once after sourcing utils.sh.
# After this, log_debug is either a real function or a no-op.
_CLAUDE_DEBUG=$(get_option "@claude_debug" "off")
if [ "$_CLAUDE_DEBUG" = "on" ]; then
  _CLAUDE_LOG_FILE="/tmp/tmux-claude-$(id -u).log"
  log_debug() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$_CLAUDE_LOG_FILE"; }
else
  log_debug() { :; }
fi
