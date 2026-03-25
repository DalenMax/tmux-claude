# tmux-claude

A tmux plugin that shows when [Claude Code](https://claude.ai/code) needs your attention in other tmux sessions/panes.

When running Claude Code across multiple tmux sessions, this plugin displays compact status icons in your tmux status bar so you know which sessions are active and which are waiting for input — without switching panes.

## Installation

Add to `.tmux.conf`:

```bash
set -g @plugin 'DalenMax/tmux-claude'
```

Press `prefix + I` to install. Restart Claude Code. Done.

Everything is auto-configured — hooks, status bar, defaults. No manual setup needed.

## Requirements

- tmux (with [TPM](https://github.com/tmux-plugins/tpm))
- [jq](https://jqlang.github.io/jq/)
- [Claude Code](https://claude.ai/code) (with hook support)

## Status Icons

A second status line appears at the bottom of your tmux with:

| Dot | Color | Meaning |
|-----|-------|---------|
| ● | Blue | Claude is working |
| ● | Red | Claude needs your attention |

No dot = no Claude running in that session.

Example: `proj1:● proj2:●` (proj1 active, proj2 waiting for input)

## How It Works

```
Claude Code hook event → hook.sh → sets tmux pane variable → status bar reads it
```

Uses Claude Code's [hook system](https://docs.anthropic.com/en/docs/claude-code/hooks) to detect state changes. No daemons, no polling, no temp files. State updates are instant.

### Hook Events Used

| Hook | Sets State | When |
|------|-----------|------|
| `UserPromptSubmit` | active | User sent a prompt |
| `PostToolUse` | active | A tool just ran (Claude is working) |
| `PermissionRequest` | waiting | Claude needs approval |
| `Stop` | waiting | Claude finished responding |
| `StopFailure` | waiting | API error occurred |
| `Notification` | waiting | Fallback notification signal |
| `SessionEnd` | (cleared) | Claude exited |

State is stored in tmux per-pane user variables (`@claude_state`) — no external files or processes.

## Configuration

All optional. Set in `.tmux.conf` before the plugin line:

```bash
# Icons (default: ●)
set -g @claude_icon_active '●'
set -g @claude_icon_waiting '●'

# Colors (default: blue/red)
set -g @claude_color_active 'colour39'
set -g @claude_color_waiting 'colour196'

# Show session name prefix (default: yes)
set -g @claude_show_session_name 'yes'

# Separator between entries (default: ' ')
set -g @claude_separator ' '

# Debug logging (default: off)
set -g @claude_debug 'on'
```

## Uninstall

```bash
~/.tmux/plugins/tmux-claude/scripts/setup.sh --remove
```

Then remove the plugin line from `.tmux.conf` and press `prefix + alt + u`.

## Troubleshooting

**No icons showing:**
1. Check hooks are configured: `cat ~/.claude/settings.json | jq '.hooks'`
2. Restart Claude Code after installing the plugin (hooks load at startup)

**Enable debug logging:**
```bash
set -g @claude_debug 'on'
# Logs go to /tmp/tmux-claude-<uid>.log
```

## License

MIT
