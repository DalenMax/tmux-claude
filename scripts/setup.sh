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
        "SessionEnd": $entry,
        "Stop": $entry,
        "StopFailure": $entry,
        "PermissionRequest": $entry,
        "PostToolUse": $entry
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

  for event in Notification UserPromptSubmit SessionEnd Stop StopFailure PermissionRequest PostToolUse; do
    if has_our_hook "$settings" "$event"; then
      continue
    fi
    settings=$(echo "$settings" | jq --argjson entry "$hook_entry" \
      ".hooks[\"$event\"] = ((.hooks[\"$event\"] // []) + [\$entry])")
  done

  echo "$settings" | jq '.' > "$SETTINGS_FILE"
  echo "Hooks configured in $SETTINGS_FILE" >&2
  echo "Hook script: $HOOK_SCRIPT" >&2
}

remove_hooks() {
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo "No settings file found at $SETTINGS_FILE" >&2
    return
  fi

  local settings
  settings=$(cat "$SETTINGS_FILE")

  for event in Notification UserPromptSubmit SessionEnd Stop StopFailure PermissionRequest PostToolUse; do
    settings=$(echo "$settings" | jq --arg cmd "$HOOK_SCRIPT" \
      "if .hooks[\"$event\"] then
        .hooks[\"$event\"] |= map(select(.hooks | all(.command != \$cmd)))
        | if .hooks[\"$event\"] | length == 0 then del(.hooks[\"$event\"]) else . end
      else . end")
  done

  # Clean up empty hooks object
  settings=$(echo "$settings" | jq 'if .hooks == {} then del(.hooks) else . end')

  echo "$settings" | jq '.' > "$SETTINGS_FILE"
  echo "Hooks removed from $SETTINGS_FILE" >&2
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
