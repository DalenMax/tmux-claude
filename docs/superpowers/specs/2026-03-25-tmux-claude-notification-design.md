# tmux-notification: Cross-Session Claude Code State Awareness

**Date:** 2026-03-25
**Status:** Draft (rev 2)

## Problem

When running Claude Code in multiple tmux sessions/panes simultaneously, there is no way to know from one pane that another pane's Claude instance is waiting for input (approval or next prompt) without switching to it. This causes idle time and context-switching overhead.

## Solution

A tmux plugin (TPM-compatible) that uses Claude Code's hook system to track each Claude instance's state and display compact status icons in the tmux status bar.

## Architecture

```
Claude Code hook event
   → hook.sh receives JSON on stdin
   → discovers which tmux pane it belongs to (process tree walk)
   → sets tmux per-pane user variable @claude_state
   → status.sh reads all pane states via tmux list-panes
   → renders compact icons in tmux status bar
```

No daemons, no temp files, no polling. Event-driven state via Claude Code hooks, stored natively in tmux per-pane variables.

## States

Three states per pane:

| State | Meaning | Set by hook |
|-------|---------|-------------|
| `active` | Claude is working | `UserPromptSubmit` |
| `waiting` | Claude needs input/approval | `Notification` (permission_prompt, idle_prompt, elicitation_dialog) |
| (unset) | No Claude running / session ended | `SessionEnd` (unsets variable) |

### State Transitions

```
         UserPromptSubmit
  ┌──────────────────────────┐
  │                          ▼
(unset) ◄── SessionEnd ── ACTIVE
  │                          │
  │                          │ Notification (idle_prompt / permission_prompt / elicitation_dialog)
  │                          ▼
  ├────── SessionEnd ──── WAITING
                             │
                             │ UserPromptSubmit
                             ▼
                           ACTIVE
```

Note: A `Notification` event can arrive when state is `(unset)` if the plugin is installed while Claude is already mid-session. The hook handles this gracefully — it sets `waiting` regardless of prior state.

## Hook Configuration

Three Claude Code hooks, all pointing to the same `hook.sh`:

| Hook Event | Matcher | Purpose |
|------------|---------|---------|
| `Notification` | `""` (all types) | Detect waiting states (script filters by notification_type) |
| `UserPromptSubmit` | `""` | User sent prompt → set active |
| `SessionEnd` | `""` | Claude exited → unset state |

**Why no `Stop` hook:** `Stop` fires when Claude finishes generating a response. This does NOT mean the user needs to act — `Notification` with `idle_prompt` fires separately when user input is actually needed. Using `Stop` would cause every completed response to show as "waiting," making the signal meaningless noise.

Hooks are configured globally in `~/.claude/settings.json`. They fire for all Claude Code instances. The hook script determines which tmux pane it belongs to.

### Hook JSON Payloads

Each hook receives JSON on stdin. Common fields for all events:

```json
{
  "session_id": "string",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/working/directory",
  "permission_mode": "default|plan|acceptEdits|auto|dontAsk|bypassPermissions",
  "hook_event_name": "string"
}
```

**Notification** — additional fields:
```json
{
  "message": "string",
  "title": "string (optional)",
  "notification_type": "permission_prompt|idle_prompt|auth_success|elicitation_dialog"
}
```

The hook script reads `notification_type` via `jq -r '.notification_type'` and only sets `waiting` for:
- `permission_prompt` — Claude needs tool approval
- `idle_prompt` — Claude finished, waiting for next instruction
- `elicitation_dialog` — MCP server requesting user input

It ignores `auth_success` (informational, no user action needed).

**UserPromptSubmit** — additional fields:
```json
{
  "prompt": "string"
}
```

**SessionEnd** — additional fields:
```json
{
  "reason": "clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other"
}
```

## Pane Discovery

The hook script must map itself to a tmux pane. Claude Code hooks do NOT expose tmux pane info.

**Mechanism:** Walk the process tree from the hook script's PID upward until a PID matches a tmux pane's shell PID.

```bash
pane_map=$(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}')

pid=$$
max_depth=50
i=0
while [ "$pid" -gt 1 ] && [ "$i" -lt "$max_depth" ]; do
  match=$(echo "$pane_map" | awk -v p="$pid" '$1 == p {print $2}')
  if [ -n "$match" ]; then
    # Found the pane
    break
  fi
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  i=$((i + 1))
done
```

**Non-tmux detection:** If the loop reaches PID 1 or hits max_depth without matching a pane, the script exits silently (exit 0). This handles cases where Claude Code is running outside tmux. Checking `$TMUX` alone is insufficient because the hook subprocess inherits `$TMUX` from the tmux-spawned shell even though the hook itself doesn't have a direct pane relationship.

Once the pane target is known:
```bash
tmux set -p -t "$pane_target" @claude_state "waiting"
```

## Status Bar Rendering

`status.sh` is called by tmux's status format string via `#(path/to/status.sh)`.

**Logic:**
1. `tmux list-panes -a -F '#{session_name} #{@claude_state}'`
2. Filter out panes with no `@claude_state` set
3. Group by session name, pick most urgent state per session (waiting > active)
4. Render: `session_name:icon` with color

**Rendering rules:**

| State | Icon | Color |
|-------|------|-------|
| `active` | `●` | green |
| `waiting` | `●` | yellow |

**Output example:**
```
proj1:#[fg=green]●#[default] proj2:#[fg=yellow]●
```

**Stale state handling:** If `@claude_state` is set but no Claude process is running in that pane, the status script ignores it. Detection: check if any child process of the pane's shell PID has "claude" in its command name (`ps -o comm= -p $(pgrep -P <pane_pid>)` or similar). This is a best-effort heuristic — if Claude's process name changes, stale states will persist until the next `SessionEnd` or tmux restart.

**tmux server restart:** All per-pane user variables are lost on tmux server restart. This is fine — they will be re-set on the next hook event. No persistence beyond tmux's lifetime is attempted.

**Concurrent hook execution:** Two hooks can fire nearly simultaneously for the same pane (e.g., `Notification` immediately after a prior event). Since `tmux set` is atomic at the tmux server level, the last write wins. This is correct behavior — no locking needed.

## Plugin Structure

```
tmux-notification/
├── notification.tmux          # TPM entry point, registers option defaults
├── scripts/
│   ├── hook.sh                # Claude Code hook handler, sets pane state
│   ├── status.sh              # Status bar renderer, aggregates pane states
│   ├── utils.sh               # Shared helpers (pane discovery)
│   └── setup.sh               # Claude Code hook configuration (install/remove)
└── README.md
```

### notification.tmux responsibilities

1. Register default values for all `@claude_*` tmux options (icons, colors, separator, etc.)
2. Print a one-line message on first load if hooks are not yet configured, pointing user to `setup.sh`

It does NOT automatically modify `status-right` — the user places `#(path/to/status.sh)` where they want it.

## Installation & Setup

### Step 1: TPM install
```bash
# .tmux.conf
set -g @plugin 'raki/tmux-notification'
```
Then `prefix + I`.

### Step 2: Add to status bar
```bash
# .tmux.conf (place wherever you want in your status bar)
set -g status-right '... #(~/.tmux/plugins/tmux-notification/scripts/status.sh) ...'
```

### Step 3: Configure Claude Code hooks
```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --apply
```

### Uninstall hooks
```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --remove
```

## setup.sh Behavior

**Path detection:** Uses `$(cd "$(dirname "$0")/.." && pwd)` to find the plugin root, then constructs absolute paths to `scripts/hook.sh`.

**Target file:** `~/.claude/settings.json` (user-level, applies to all projects).

**Target JSON structure:**
```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/scripts/hook.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/scripts/hook.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/scripts/hook.sh"
          }
        ]
      }
    ]
  }
}
```

**Merge strategy (`--apply`):**
1. Read existing `~/.claude/settings.json` (or start with `{}` if absent)
2. For each hook event (Notification, UserPromptSubmit, SessionEnd):
   - If the event key exists, append our hook entry to the array (do not overwrite existing hooks)
   - If the event key does not exist, create it with our hook entry
3. Write back with `jq` preserving all other settings

**Remove strategy (`--remove`):**
1. Read existing `~/.claude/settings.json`
2. For each hook event, filter out entries where `command` contains the plugin's `hook.sh` path
3. Remove empty hook event arrays
4. Write back

**Dry run (no flag):** Print the JSON that would be written, without modifying the file.

## Configuration Options

All configurable via tmux options with sensible defaults:

```bash
# Icons
set -g @claude_icon_active '●'     # default
set -g @claude_icon_waiting '●'    # default

# Colors
set -g @claude_color_active 'green'   # default
set -g @claude_color_waiting 'yellow' # default

# Display
set -g @claude_show_session_name 'yes'  # default
set -g @claude_separator ' '            # default
```

## Dependencies

- **tmux** (obviously)
- **jq** — for parsing JSON from Claude Code hooks and for `setup.sh`
- **Claude Code** — with hook support (provides the events)

No other tmux plugins required. No runtime daemons. No external services.

## Error Handling

- **jq not installed:** `hook.sh` checks for `jq` on first line. If missing, exits silently (exit 0). `setup.sh` checks for `jq` and prints an error message with install instructions.
- **tmux command fails:** `hook.sh` exits silently. Status bar shows nothing.
- **Debug logging:** Controlled by tmux option `set -g @claude_debug 'on'`. When enabled, `hook.sh` appends to `/tmp/tmux-notification.log`. Off by default.

## Limitations & Edge Cases

1. **Claude crash without SessionEnd:** Pane variable stays stale. Status script mitigates by checking for live Claude process (best-effort heuristic).
2. **Non-tmux usage:** Hook script exits silently if process tree walk finds no matching tmux pane.
3. **Headless Claude (`-p` flag):** Notification hooks do NOT fire in non-interactive mode. Plugin only works for interactive Claude sessions.
4. **Status bar refresh delay:** tmux refreshes status bar on `status-interval` (default 15s). User can lower to 5s for faster updates. The pane variable itself is set instantly.
5. **Multiple Claude instances in one pane:** Not a typical scenario. Last hook write wins.
6. **Detached sessions:** States are still tracked and displayed for detached tmux sessions. This is intentional — the status bar shows all sessions so the user knows when to reattach.
7. **tmux server restart:** All state is lost. Repopulated on next hook event. No persistence attempted.
8. **Plugin path change (e.g., TPM reinstall):** Hooks in `settings.json` point to absolute paths. If the plugin moves, run `setup.sh --remove` then `setup.sh --apply` to update paths.

## Testing

Manual verification steps:

1. **State setting:** Run `tmux set -p @claude_state waiting` in a pane, confirm `status.sh` outputs the yellow icon.
2. **State clearing:** Run `tmux set -pu @claude_state`, confirm pane disappears from status output.
3. **Hook integration:** Start Claude Code, submit a prompt, verify pane shows green. Wait for permission prompt, verify pane shows yellow.
4. **Non-tmux:** Run `hook.sh` outside tmux (pipe it test JSON), verify it exits silently.
5. **setup.sh:** Run without flags to see dry-run output. Run `--apply`, verify `settings.json` is correct. Run `--remove`, verify hooks are gone.
