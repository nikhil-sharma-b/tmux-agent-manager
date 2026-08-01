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
    --color='fg:-1,bg:-1,hl:4,fg+:4:bold,bg+:-1,hl+:12,info:8,prompt:8,pointer:4,header:8,gutter:8'
}

prompt_directory() {
  local base=$1 path resolved
  while true; do
    printf '\033[2J\033[H\n  \033[1mdirectory path\033[0m  \033[90mrelative to %s · empty cancels\033[0m\n\n  › ' "$base" >&2
    IFS= read -r path || return 1
    [[ -n $path ]] || return 1
    if resolved=$(resolve_directory "$path" "$base"); then
      cwd=$resolved
      return
    fi
    printf '\n\n  \033[31mnot a directory: %s\033[0m\n' "$path" >&2
    sleep 1
  done
}

browse_directory() {
  local base=$1 cwd_file resolved
  require_command yazi
  cwd_file=$(mktemp "${TMPDIR:-/tmp}/tmux-agent-yazi.XXXXXX")
  if ! yazi "$base" --cwd-file="$cwd_file"; then
    rm -f "$cwd_file"
    return 1
  fi
  IFS= read -r resolved <"$cwd_file" || resolved=''
  rm -f "$cwd_file"
  cwd=$(resolve_directory "$resolved" "$base")
}

harness=$(printf 'claude\ncodex\nopencode\n' | pick agent 1) || exit 0

printf '\033[2J\033[H\n  \033[1mlabel\033[0m  \033[90mstep 2 of 3 · enter skips\033[0m\n\n  › '
IFS= read -r label || exit 0
label=$(clean_text "$label")
source_pane=${TMUX_AGENT_SOURCE_PANE:-${TMUX_PANE:-}}
source_cwd=$(tmux display-message -p -t "$source_pane" '#{pane_current_path}')
workspace=$(printf 'current directory\nenter directory path\nbrowse with yazi\nnew worktree\n' | pick workspace 3) || exit 0

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
  # Managed threads want the agent alone in the window, not the editor split
  # tmux-worktree lays out for hand-driven work.
  exec "$worktree_bin" create --session-name "$session" --no-editor --right-command "$command"
fi

case $workspace in
  'enter directory path') prompt_directory "$source_cwd" || exit 0 ;;
  'browse with yazi') browse_directory "$source_cwd" || exit 0 ;;
  *) cwd=$source_cwd ;;
esac
window_name=${label:-$harness}
create_agent_session "$session" "$cwd" "$window_name" "$command"
