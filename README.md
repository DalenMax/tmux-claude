# tmux-notification

A tmux plugin that shows when [Claude Code](https://claude.ai/code) needs your attention in other tmux sessions/panes.

When running Claude Code across multiple tmux sessions, this plugin displays compact status icons in your tmux status bar so you know which sessions are active and which are waiting for input — without switching panes.

## How It Works

Claude Code hook event → hook.sh → sets tmux pane variable → status bar reads it

Uses Claude Code's [hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) to detect state changes. No daemons, no polling, no temp files.

## Requirements

- tmux (with TPM)
- jq
- Claude Code (with hook support)

## Installation

### 1. Add plugin to `.tmux.conf`

```
set -g @plugin 'raki/tmux-notification'
```

Press `prefix + I` to install.

### 2. Add to your status bar

Place this wherever you want in your `status-right` (or `status-left`):

```
set -g status-right '#{status-right} #(~/.tmux/plugins/tmux-notification/scripts/status.sh)'
```

### 3. Configure Claude Code hooks

```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --apply
```

That's it. Restart Claude Code and you'll see status icons appear.

## Status Icons

| Icon | Color | Meaning |
|------|-------|---------|
| ● | Green | Claude is working |
| ● | Yellow | Claude needs your input |

Example status bar: `proj1:● proj2:●` (proj1 active, proj2 waiting)

## Configuration

All options are set via tmux options in `.tmux.conf`:

```
# Icons (default: ●)
set -g @claude_icon_active '●'
set -g @claude_icon_waiting '●'

# Colors (default: green/yellow)
set -g @claude_color_active 'green'
set -g @claude_color_waiting 'yellow'

# Show session name prefix (default: yes)
set -g @claude_show_session_name 'yes'

# Separator between entries (default: ' ')
set -g @claude_separator ' '

# Debug logging (default: off)
set -g @claude_debug 'on'
```

## Uninstall

Remove hooks from Claude Code:

```bash
~/.tmux/plugins/tmux-notification/scripts/setup.sh --remove
```

Then remove the plugin line from `.tmux.conf` and press `prefix + alt + u`.

## How It Detects State

The plugin uses three Claude Code hook events:

- **UserPromptSubmit** — User sent a prompt → state = `active`
- **Notification** (permission_prompt, idle_prompt, elicitation_dialog) — Claude needs input → state = `waiting`
- **SessionEnd** — Claude exited → state cleared

State is stored in tmux per-pane user variables (`@claude_state`), so there are no external files or processes.

## Troubleshooting

**No icons showing:**
1. Check hooks are configured: `cat ~/.claude/settings.json | jq '.hooks'`
2. Restart Claude Code after setting up hooks
3. Verify `status.sh` is in your status bar: `tmux show -g status-right`

**Enable debug logging:**
```
set -g @claude_debug 'on'
# Logs go to /tmp/tmux-notification-<uid>.log
```

**Status bar updates too slowly:**
```
# Lower the refresh interval (default is 15s)
set -g status-interval 5
```

## License

MIT
