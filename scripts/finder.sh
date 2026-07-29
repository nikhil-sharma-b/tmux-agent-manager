#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"
require_command fzf

snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-manager.XXXXXX")
trap 'rm -rf "$snapshot_dir"' EXIT INT TERM
mode=${1:-live}
case $mode in
  live|history|sessions) ;;
  *) mode=live ;;
esac
scope=$mode
[[ $scope == sessions ]] && scope=saved
"$script_dir/finder-collect.sh" "$snapshot_dir" "$mode" >/dev/null

export TMUX_AGENT_SCRIPTS=$script_dir
export TMUX_AGENT_SNAPSHOT=$snapshot_dir
export TMUX_AGENT_CLIENT
TMUX_AGENT_CLIENT=$(tmux display-message -p '#{client_name}')

fzf \
  --height=100% --ansi --delimiter=$'\t' --with-nth='10..' --no-multi \
  --layout=reverse --border=none --no-scrollbar --separator=' ' \
  --pointer='▌' --marker=' ' \
  --color='fg:-1,bg:-1,hl:4,fg+:-1:regular,bg+:-1,hl+:12,info:8,prompt:8,pointer:4,marker:4,spinner:8,header:8,border:8,gutter:-1' \
  --info=hidden --prompt='  ' \
  --header="scope: $scope · ↵ open · ^l live · ^h history · ^s saved · ^r refresh · esc" \
  --header-first --padding='1,2' \
  --preview='"$TMUX_AGENT_SCRIPTS/preview.sh" {1} {2}' \
  --preview-window='right,55%,border-left' \
  --bind='enter:execute-silent("$TMUX_AGENT_SCRIPTS/open.sh" {1} {2} {3} {4} {5} {6} {8})+abort' \
  --bind='ctrl-n:execute("$TMUX_AGENT_SCRIPTS/new.sh")+abort' \
  --bind='ctrl-e:execute("$TMUX_AGENT_SCRIPTS/rename.sh" {1})+reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  --bind='ctrl-x:execute("$TMUX_AGENT_SCRIPTS/stop.sh" {1})+reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  --bind='ctrl-p:change-preview("$TMUX_AGENT_SCRIPTS/capture.sh" {1})' \
  --bind='ctrl-h:reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT" history)+change-header(scope: history · ↵ open · ^l live · ^h history · ^s saved · ^r refresh · esc)' \
  --bind='ctrl-s:reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT" sessions)+change-header(scope: saved · ↵ open · ^l live · ^h history · ^s saved · ^r refresh · esc)' \
  --bind='ctrl-l:reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT" live)+change-header(scope: live · ↵ open · ^l live · ^h history · ^s saved · ^r refresh · esc)' \
  --bind='ctrl-r:reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  <"$snapshot_dir/list" >/dev/null
