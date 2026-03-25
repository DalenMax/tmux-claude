# tmux-notification: Cross-Session Claude Code State Awareness

**Date:** 2026-03-25
**Status:** Draft

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
| `waiting` | Claude needs input/approval | `Notification` (permission_prompt, idle_prompt), `Stop` |
| (unset) | No Claude running / session ended | `SessionEnd` (unsets variable) |

### State Transitions

```
         UserPromptSubmit
  ┌──────────────────────────┐
  │                          ▼
(unset) ◄── SessionEnd ── ACTIVE
                             │
                             │ Notification (idle_prompt / permission_prompt) or Stop
                             ▼
                          WAITING
                             │
                             │ UserPromptSubmit
                             ▼
                           ACTIVE
```

## Hook Configuration

Four Claude Code hooks, all pointing to the same `hook.sh`:

| Hook Event | Matcher | Purpose |
|------------|---------|---------|
| `Notification` | `""` (all) | Detect permission_prompt, idle_prompt → set waiting |
| `UserPromptSubmit` | `""` | User sent prompt → set active |
| `Stop` | `""` | Claude finished responding → set waiting |
| `SessionEnd` | `""` | Claude exited → unset state |

Hooks are configured globally in `~/.claude/settings.json`. They fire for all Claude Code instances. The hook script determines which tmux pane it belongs to.

## Pane Discovery

The hook script must map itself to a tmux pane. Claude Code hooks do NOT expose tmux pane info.

**Mechanism:** Walk the process tree from the hook script's PID upward until a PID matches a tmux pane's shell PID.

```bash
pane_map=$(tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_index}.#{pane_index}')

pid=$$
while [ "$pid" -gt 1 ]; do
  match=$(echo "$pane_map" | awk -v p="$pid" '$1 == p {print $2}')
  if [ -n "$match" ]; then
    # Found the pane
    break
  fi
  pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
done
```

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

**Stale state handling:** If `@claude_state` is set but no Claude process is running in that pane (detectable by checking if the pane PID's children include a Claude process), the status script ignores it.

## Plugin Structure

```
tmux-notification/
├── notification.tmux          # TPM entry point, registers defaults
├── scripts/
│   ├── hook.sh                # Claude Code hook handler, sets pane state
│   ├── status.sh              # Status bar renderer, aggregates pane states
│   ├── utils.sh               # Shared helpers (pane discovery)
│   └── setup.sh               # One-command Claude Code hook configuration
└── README.md
```

## Installation & Setup

### Step 1: TPM install
```bash
# .tmux.conf
set -g @plugin 'raki/tmux-notification'
```
Then `prefix + I`.

### Step 2: Add to status bar
```bash
# .tmux.conf
set -g status-right '... #(~/.tmux/plugins/tmux-notification/scripts/status.sh) ...'
```

### Step 3: Configure Claude Code hooks
```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --apply
```

This script detects the plugin install path, generates the correct hooks JSON, and merges it into `~/.claude/settings.json`.

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
- **jq** — for parsing JSON from Claude Code hooks
- **Claude Code** — with hook support (provides the events)

No other tmux plugins required. No runtime daemons. No external services.

## Limitations & Edge Cases

1. **Claude crash without SessionEnd:** Pane variable stays stale. Status script mitigates by checking for live Claude process.
2. **Non-tmux usage:** Hook script detects if tmux is not running and exits silently (no-op).
3. **Headless Claude (`-p` flag):** Notification hooks do NOT fire in non-interactive mode. Plugin only works for interactive Claude sessions.
4. **Status bar refresh delay:** tmux refreshes status bar on `status-interval` (default 15s). User can lower to 5s for faster updates. The pane variable itself is set instantly.
5. **Multiple Claude instances in one pane:** Not a typical scenario. Last hook write wins.
