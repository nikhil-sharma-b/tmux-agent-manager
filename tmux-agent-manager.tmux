#!/usr/bin/env bash

set -euo pipefail

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
key=$(tmux show-option -gqv @agent-manager-key)
finder_key=$(tmux show-option -gqv @agent-manager-finder-key)
width=$(tmux show-option -gqv @agent-manager-width)
height=$(tmux show-option -gqv @agent-manager-height)
border_style=$(tmux show-option -gqv @agent-manager-border-style)
title=$(tmux show-option -gqv @agent-manager-title)

key=${key:-A}
finder_key=${finder_key:-C-a}
width=${width:-80%}
height=${height:-70%}
border_style=${border_style:-fg=brightblack}
title=${title:-}

tmux bind-key "$key" run-shell \
  "$plugin_dir/scripts/sidebar-toggle.sh focus '#{pane_id}' '#{client_name}'"
tmux bind-key "$finder_key" display-popup -E -w "$width" -h "$height" \
  -b rounded -s "$border_style" -T "$title" -d / \
  -e "TMUX_AGENT_BIN=$plugin_dir/bin/tmux-agent" \
  "$plugin_dir/bin/tmux-agent finder"

tmux set-hook -g 'after-select-pane[70]' "run-shell -b '$plugin_dir/scripts/seen-current.sh #{pane_id}'"
tmux set-hook -g 'after-select-window[70]' "run-shell -b '$plugin_dir/scripts/seen-current.sh #{pane_id}'"
tmux set-hook -g 'client-session-changed[70]' "run-shell -b '$plugin_dir/scripts/seen-current.sh #{pane_id}'"
tmux set-hook -g 'after-select-pane[71]' "run-shell -b '$plugin_dir/scripts/sidebar-follow.sh #{pane_id} #{client_name}'"
tmux set-hook -g 'after-select-window[71]' "run-shell -b '$plugin_dir/scripts/sidebar-follow.sh #{pane_id} #{client_name}'"
tmux set-hook -g 'client-session-changed[71]' "run-shell -b '$plugin_dir/scripts/sidebar-follow.sh #{pane_id} #{client_name}'"
tmux set-hook -g 'pane-died[70]' "run-shell -b '$plugin_dir/bin/tmux-agent reconcile'"
tmux set-hook -g 'window-unlinked[70]' "run-shell -b '$plugin_dir/bin/tmux-agent reconcile'"

status_right=$(tmux show-option -gqv status-right)
if [[ $status_right != *"$plugin_dir/bin/tmux-agent status"* ]]; then
  tmux set-option -ag status-right "#($plugin_dir/bin/tmux-agent status)"
fi

window_format=$(tmux show-option -gwqv window-status-format)
if [[ $window_format != *'#{@agent-manager-window-mark}'* ]]; then
  tmux set-option -agw window-status-format ' #{@agent-manager-window-mark}'
fi
current_format=$(tmux show-option -gwqv window-status-current-format)
if [[ $current_format != *'#{@agent-manager-window-mark}'* ]]; then
  tmux set-option -agw window-status-current-format ' #{@agent-manager-window-mark}'
fi

tmux run-shell -b "$plugin_dir/bin/tmux-agent reconcile"
if [[ $(tmux show-option -gqv @agent-manager-sidebar) != off ]]; then
  tmux run-shell -b "$plugin_dir/scripts/sidebar-toggle.sh show '#{pane_id}' '#{client_name}'"
fi
