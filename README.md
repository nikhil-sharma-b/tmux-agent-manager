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
- [tmux-worktree](https://github.com/nikhil-sharma-b/tmux-worktree) for new-worktree creation, with `--no-editor` support

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

Sidebar controls. Press `?` in the sidebar for this list in the pane:

- `j` / `k` or arrows: select agent
- `Enter`: jump to selected agent
- `n`: create an agent
- `h`: toggle live agents and history
- `s`: toggle native Claude, Codex, and OpenCode sessions
- `/`, `f`, or `o`: fuzzy search the current live, history, or saved view in the sidebar pane
- `r`: refresh
- `q`: hide sidebar

The sidebar shows one line per agent: a state glyph, the label, and the state or harness on the right. The tab row marks the current scope, and the footer keeps the four main keys visible.

Press `prefix + Ctrl-a` to open the detailed popup directly.

Search fuzzy-matches the current scope. Scope tabs stay in the header; the actions are `Ctrl-l` live, `Ctrl-h` history, `Ctrl-s` saved sessions, `Ctrl-n` new, `Ctrl-e` rename, `Ctrl-x` stop, `Ctrl-o` details, `Ctrl-p` pane output, `Ctrl-r` refresh.

Search matches the sidebar layout: scope tabs on top, keys along the bottom. It adapts to the terminal it opens in, so the same keys work in the popup and in the sidebar pane:

- 96 columns or wider: details beside the list
- narrower: list only, with `Ctrl-o` opening details below it

Bottom keys need fzf 0.65 or newer. Older versions keep them on a second header line.

Details are cut to the available width rather than wrapped, and repeated events collapse into one line.

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
