# tmux-agent-manager

Manage Claude Code, Codex, OpenCode, and Antigravity CLI conversations as tracked tmux panes. The popup jumps to agents across sessions and shows working, attention, unseen-result, stale, and failed states.

There are two scopes. **Live** is what is running now. **Saved** is every conversation the harnesses can resume, enriched with what this plugin remembers about the runs that used them — the branch, and how each one ended. Runs whose conversation the harness no longer has still appear there; opening one starts a fresh agent in the directory the work happened in.

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
- [Yazi](https://yazi-rs.github.io/) for optional directory browsing
- [GitHub CLI](https://cli.github.com/) (`gh`) for optional pull-request merge detection

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

Creating an agent asks two things: the harness and the workspace. There is no label step. A new run is named after its git branch, or its directory when there is no branch, and adopts the harness's own session title as soon as the harness writes one. Renaming pins the name, so an adopted title never replaces one you chose.

The workspace can be the current directory, a typed directory path, a directory browsed with Yazi, or a new worktree. Typed relative paths start from the current pane's directory; absolute paths and `~/...` are also supported. In Yazi, navigate to the wanted directory and quit to use it.

## Controls

Sidebar controls. Press `?` in the sidebar for this list in the pane:

- `j` / `k` or arrows: select agent
- `Enter`: jump to selected agent
- `n`: create an agent
- `h` or `s`: toggle live agents and saved sessions
- `/`, `f`, or `o`: fuzzy search the current view in the sidebar pane
- `r`: rename the selected managed session
- `x`: stop the selected managed session
- `R`: refresh
- `q`: hide sidebar

The sidebar shows one line per agent: a state glyph, the label, and the state or harness on the right. The tab row marks the current scope, and the footer keeps the four main keys visible.

Press `prefix + Ctrl-a` to open the detailed popup directly.

Search fuzzy-matches the current scope. Scope tabs stay in the header; the actions are `Ctrl-l` live, `Ctrl-s` saved sessions, `Ctrl-n` new, `Ctrl-e` rename, `Ctrl-x` stop, `Ctrl-o` details, `Ctrl-p` pane output, `Ctrl-r` refresh.

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
- `× crashed`: harness process exited unsuccessfully. The pane is held open so
  the error stays readable; closing it archives the run as `crashed`
- `cancelled`: harness process was interrupted and moved to history
- `merged`: the run's pull request merged, so the run moved to history

A run started on a git branch is retired once its pull request merges. The check
needs the GitHub CLI (`gh`) and runs at most once per
`@agent-manager-merge-poll-seconds`. Without `gh` the check is skipped, and
setting the interval to `0` disables it. Run it on demand with
`tmux-agent check-merges`.

The run moves to history and its `ai-<label>-<id>` session is killed, which ends
the harness process in it. Set `@agent-manager-merge-kill-session` to `off` to
archive the run but leave the session running. A harness launched outside the
plugin keeps whichever session it was started in; only sessions the plugin
created for a managed run are closed.

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
set -g @agent-manager-merge-poll-seconds '120'
set -g @agent-manager-merge-kill-session 'on'
set -g @agent-manager-worktree-command '~/repos/tmux-worktree/bin/tmux-worktree'
```

Claude launches use the `cc` alias or function from your interactive shell when it exists, then fall back to `claude`. Override it for the tmux server when needed:

```tmux
set-environment -g TMUX_AGENT_CLAUDE_COMMAND claude
```

The manager is scoped to the current tmux server. It tracks managed launches immediately. Directly launched harnesses appear as degraded entries after their first adapter event.

One sidebar pane follows the most recently active tmux client. With multiple attached clients, it moves to whichever client changes panes or windows last.

OpenCode loads the adapter from `~/.config/opencode/plugin/tmux-agent-manager.js`.

Antigravity CLI (`agy`, tested against 1.1.9) has no alias convention, so it is launched directly and resumes with `--conversation <id>`:

```tmux
set-environment -g TMUX_AGENT_ANTIGRAVITY_COMMAND agy
```

Its hooks go into `~/.gemini/config/hooks.json` under a `tmux-agent-manager` entry, since that file is keyed by hook name rather than by event. Setup rewrites only that entry and leaves every other named hook alone; an entry of that name it did not write is reported as a collision instead of being replaced. Override the path with `ANTIGRAVITY_HOOKS_FILE`.

Antigravity offers no permission or session-lifecycle hook, so `working`, `ready`, and `turn-failed` come from the harness while `starting`, `exited`, `cancelled`, and `crashed` come from the wrapper around a managed launch. It never reports `attention`, and an `agy` started outside the plugin stays listed until its pane dies. The status hook is deliberately not registered for `PreToolUse`: that hook has to return a permission decision, and answering it would approve or block tool calls rather than just observe them.

Saved Antigravity conversations come from `~/.gemini/antigravity-cli` (override with `ANTIGRAVITY_DATA_DIR`). Summary rows are written lazily, so a conversation with no row yet is still listed and resumable under its directory name, taken from the conversation files and the workspace cache beside them.

List or refresh the saved sessions from the command line (`sessions` still works):

```sh
tmux-agent saved
tmux-agent saved refresh
```

The catalog stores only session IDs, generated titles, directories, and timestamps. Prompt and transcript bodies are not cached.

## Test

```sh
./tests/all.sh
```

Each suite runs against its own tmux server on a private socket, under a
temporary `HOME` and XDG directories, so none of them touch a running session.

- `run.sh` — the core suite; fails on the first assertion
- `scenarios.sh` — end-to-end behaviour: the state machine, how runs end,
  window marks, pruning, plugin reload
- `labels.sh` — the fallback name, adopting a harness title, and pinning
- `interactive.sh` — drives the wizard, sidebar, and search with `send-keys`
  and asserts on what the pane renders

The three scenario suites report every failure rather than stopping at the
first, since a broken scenario rarely invalidates the ones after it.
