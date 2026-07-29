#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

action=${1:-toggle}
target=${2:-${TMUX_PANE:-}}
client=${3:-}
ensure_state_dirs
exec 7>"$(runtime_root)/sidebar.lock"
flock 7
sidebar=$(tmux show-option -gqv @agent-manager-sidebar-pane)
if [[ -n $sidebar ]] && ! pane_exists "$sidebar"; then
  sidebar=''
  tmux set-option -gu @agent-manager-sidebar-pane 2>/dev/null || true
fi
tmux set-option -gu @agent-manager-sidebar-moving 2>/dev/null || true

if [[ $action == hide || ($action == toggle && -n $sidebar) ]]; then
  tmux set-option -g @agent-manager-sidebar-hidden 1
  [[ -n $sidebar ]] && tmux kill-pane -t "$sidebar" 2>/dev/null || true
  tmux set-option -gu @agent-manager-sidebar-pane 2>/dev/null || true
  tmux set-option -gu @agent-manager-sidebar-target 2>/dev/null || true
  exit 0
fi

if [[ $action == focus && -n $sidebar ]]; then
  sidebar_window=$(tmux display-message -p -t "$sidebar" '#{window_id}')
  target_window=$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null || true)
  if [[ -n $target_window && $sidebar_window != "$target_window" ]]; then
    width=$(agent_option '@agent-manager-sidebar-width' '38')
    tmux join-pane -d -h -l "$width" -s "$sidebar" -t "$target"
  fi
  pane_exists "$sidebar" || exit 1
  tmux select-pane -t "$sidebar"
  exit 0
fi

[[ -n $sidebar ]] && exit 0
[[ $target =~ ^%[0-9]+$ ]] || exit 0
tmux set-option -gu @agent-manager-sidebar-hidden 2>/dev/null || true
width=$(agent_option '@agent-manager-sidebar-width' '38')
sidebar=$(tmux split-window -d -h -l "$width" -P -F '#{pane_id}' -t "$target" \
  -c '#{pane_current_path}' -e "TMUX_AGENT_CLIENT=$client" "$script_dir/sidebar.sh")
tmux set-option -g @agent-manager-sidebar-pane "$sidebar"
tmux set-option -g @agent-manager-sidebar-target "$target"
