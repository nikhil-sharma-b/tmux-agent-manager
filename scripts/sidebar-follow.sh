#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

target=${1:-}
client=${2:-}
[[ $target =~ ^%[0-9]+$ ]] || exit 0
ensure_state_dirs
exec 7>"$(runtime_root)/sidebar.lock"
flock -n 7 || exit 0
sidebar=$(tmux show-option -gqv @agent-manager-sidebar-pane)

if [[ -z $sidebar ]] || ! pane_exists "$sidebar"; then
  if [[ $(agent_option '@agent-manager-sidebar' 'on') == on && \
        $(tmux show-option -gqv @agent-manager-sidebar-hidden) != 1 ]]; then
    width=$(agent_option '@agent-manager-sidebar-width' '38')
    sidebar=$(tmux split-window -d -h -l "$width" -P -F '#{pane_id}' -t "$target" \
      -c '#{pane_current_path}' -e "TMUX_AGENT_CLIENT=$client" "$script_dir/sidebar.sh")
    tmux set-option -g @agent-manager-sidebar-pane "$sidebar"
    tmux set-option -g @agent-manager-sidebar-target "$target"
  fi
  exit 0
fi

[[ $target == "$sidebar" ]] && exit 0
tmux set-option -g @agent-manager-sidebar-target "$target"
sidebar_window=$(tmux display-message -p -t "$sidebar" '#{window_id}')
target_window=$(tmux display-message -p -t "$target" '#{window_id}')
[[ $sidebar_window == "$target_window" ]] && exit 0

width=$(agent_option '@agent-manager-sidebar-width' '38')
tmux join-pane -d -h -l "$width" -s "$sidebar" -t "$target"
