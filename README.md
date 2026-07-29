# tmux-agent-manager

Manage Claude Code, Codex, and OpenCode conversations as tracked tmux panes. The popup jumps to agents across sessions and shows working, attention, unseen-result, stale, and failed states.

Every managed thread starts in its own `ai-<label>-<id>` tmux session. Worktree threads also get unique sessions, even when they reuse an existing branch worktree.

## Requirements

- tmux 3.2+
- Bash
- fzf
- jq
- sqlite3
- flock
- Git
- [tmux-worktree](https://github.com/nikhil-sharma-b/tmux-worktree) for new-worktree creation

## Install

For a local checkout:

```tmux
run-shell '~/repos/tmux-agent-manager/tmux-agent-manager.tmux'
```

Reload tmux, then install harness adapters:

```sh
~/repos/tmux-agent-manager/bin/tmux-agent setup
~/repos/tmux-agent-manager/bin/tmux-agent setup --apply
~/repos/tmux-agent-manager/bin/tmux-agent doctor
```

The persistent sidebar opens automatically. Press `prefix + A` to hide or reopen it in the current window.

## Controls

Sidebar controls:

- `j` / `k`: select agent
- `Enter`: jump to selected agent
- `n`: create an agent
- `h`: toggle live agents and history
- `s`: toggle native Claude, Codex, and OpenCode sessions
- `o`: open detailed popup
- `r`: refresh
- `q`: hide sidebar

Press `prefix + Ctrl-a` to open the detailed popup directly. Its existing rename, stop, preview, and refresh controls remain available.

In the popup, use `Ctrl-s` for native saved sessions, `Ctrl-h` for manager history, and `Ctrl-l` to return to live agents.

## States

- `● working`: active turn
- `! attention`: permission, user decision, or recoverable turn failure
- `◆ ready`: completed result not yet viewed
- `? stale`: working event received no update within the configured threshold
- `× crashed`: harness process exited unsuccessfully
- `cancelled`: harness process was interrupted and moved to history

Only metadata and lifecycle events are stored. Prompts, transcripts, and captured pane output are never persisted.

## Configuration

```tmux
set -g @agent-manager-key 'A'
set -g @agent-manager-finder-key 'C-a'
set -g @agent-manager-sidebar 'on'
set -g @agent-manager-sidebar-width '38'
set -g @agent-manager-sidebar-interval '1'
set -g @agent-manager-width '80%'
set -g @agent-manager-height '70%'
set -g @agent-manager-border-style 'fg=brightblack'
set -g @agent-manager-title ''
set -g @agent-manager-stale-seconds '1800'
set -g @agent-manager-history-limit '100'
set -g @agent-manager-native-cache-seconds '60'
set -g @agent-manager-worktree-command '~/repos/tmux-worktree/bin/tmux-worktree'
```

The manager is scoped to the current tmux server. It tracks managed launches immediately. Directly launched harnesses appear as degraded entries after their first adapter event.

One sidebar pane follows the most recently active tmux client. With multiple attached clients, it moves to whichever client changes panes or windows last.

OpenCode loads the adapter from `~/.config/opencode/plugin/tmux-agent-manager.js`.

List or refresh every resumable native harness session from the command line:

```sh
tmux-agent sessions
tmux-agent sessions refresh
```

The catalog stores only session IDs, generated titles, directories, and timestamps. Prompt and transcript bodies are not cached.

## Test

```sh
./tests/run.sh
```
