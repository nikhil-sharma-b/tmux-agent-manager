#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

require_command fzf
require_command tmux

# Three named steps, so the popup always says where you are and what is next.
pick() {
  local step=$1
  fzf --height=100% --layout=reverse --border=none --no-scrollbar --info=hidden \
    --prompt=' › ' --pointer='▌' --padding='1,2' --ansi --header-first \
    --header="$(printf '\033[1m%s\033[0m  \033[90mstep %s of 3 · esc cancels\033[0m' "$step" "$2")" \
    --color='fg:-1,bg:-1,hl:4,fg+:-1:bold,bg+:-1,hl+:12,info:8,prompt:8,pointer:4,header:8,gutter:-1'
}

harness=$(printf 'claude\ncodex\nopencode\n' | pick agent 1) || exit 0

printf '\033[2J\033[H\n  \033[1mlabel\033[0m  \033[90mstep 2 of 3 · enter skips\033[0m\n\n  › '
IFS= read -r label || exit 0
label=$(clean_text "$label")
workspace=$(printf 'current directory\nnew worktree\n' | pick workspace 3) || exit 0

thread=$(new_uuid)
run=$(new_uuid)
session=$(agent_session_name "${label:-$harness}" "$run")
command="$(shell_quote "$plugin_dir/bin/tmux-agent") run --thread $(shell_quote "$thread") --run $(shell_quote "$run") --agent $(shell_quote "$harness") --label $(shell_quote "$label")"

if [[ $workspace == 'new worktree' ]]; then
  worktree_bin=$(expand_home "$(agent_option '@agent-manager-worktree-command' "$HOME/repos/tmux-worktree/bin/tmux-worktree")")
  [[ -x $worktree_bin ]] || {
    printf 'tmux-agent-manager: tmux-worktree not found: %s\n' "$worktree_bin" >&2
    sleep 2
    exit 1
  }
  exec "$worktree_bin" create --session-name "$session" --right-command "$command"
fi

source_pane=${TMUX_AGENT_SOURCE_PANE:-${TMUX_PANE:-}}
cwd=$(tmux display-message -p -t "$source_pane" '#{pane_current_path}')
window_name=${label:-$harness}
create_agent_session "$session" "$cwd" "$window_name" "$command"
