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

# The finder runs both in the wide popup and inside the narrow sidebar pane, so
# the layout is chosen from the terminal it actually got.
width=$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2 )
[[ $width =~ ^[0-9]+$ ]] || width=$(tput cols 2>/dev/null || printf '80')
[[ $width =~ ^[0-9]+$ ]] || width=80

if ((width >= 96)); then
  # Wide: details sit beside the list. The key line is sized for the list
  # column, not the whole terminal, because the header stops at the preview.
  columns='10..'
  preview_window='right,52%,border-left'
  # The footer is confined to the list column here, and details are already
  # on screen, so ^o stays out of the line.
  keys='↵ open · ^n new · ^e rename · ^x stop'
elif ((width >= 60)); then
  # Medium: too narrow to split sideways, so details open below on request and
  # the key line stays the last thing on screen.
  columns='10..'
  preview_window='down,55%,border-top,hidden'
  keys='↵ open · ^n new · ^e rename · ^x stop · ^o details'
else
  # Narrow: a picker only. Details stay hidden until asked for, and the meta
  # column is dropped so labels get the whole width.
  columns='10'
  preview_window='down,70%,border-top,hidden'
  keys='↵ open · ^n new · ^o details'
fi

# fzf grew --footer in 0.65. With it the keys sit under the list like they do in
# the sidebar; without it they stay on a second header line.
fzf_version=$(fzf --version 2>/dev/null | awk '{print $1}')
IFS=. read -r fzf_major fzf_minor _ <<<"${fzf_version:-0.0.0}"
[[ $fzf_major =~ ^[0-9]+$ ]] || fzf_major=0
[[ $fzf_minor =~ ^[0-9]+$ ]] || fzf_minor=0
footer_opts=()
if ((fzf_major > 0 || fzf_minor >= 65)); then
  footer_opts=(--footer="$keys" --footer-border=top --header-border=bottom
    --color='footer:8,footer-border:8,header-border:8')
  keys=''
fi

header_for() {
  local active=$1 tab out=''
  for tab in live history saved; do
    if [[ $tab == "$active" ]]; then
      out+=$(printf '\033[1;4m%s\033[0m  ' "$tab")
    else
      out+=$(printf '\033[90m%s\033[0m  ' "$tab")
    fi
  done
  [[ -n $keys ]] && printf '%s\n\033[90m%s\033[0m' "$out" "$keys" && return
  printf '%s' "$out"
}

export TMUX_AGENT_SCRIPTS=$script_dir
export TMUX_AGENT_SNAPSHOT=$snapshot_dir
export TMUX_AGENT_CLIENT
TMUX_AGENT_CLIENT=$(tmux display-message -p '#{client_name}')

fzf \
  --height=100% --ansi --delimiter=$'\t' --with-nth="$columns" --no-multi \
  --layout=reverse --border=none --no-scrollbar --separator=' ' \
  --pointer='▌' --marker=' ' \
  --color='fg:-1,bg:-1,hl:4,fg+:4:bold,bg+:-1,hl+:12,info:8,prompt:8,pointer:4,marker:4,spinner:8,header:8,border:8,gutter:8' \
  --info=hidden --prompt=' › ' \
  --header="$(header_for "$scope")" \
  --header-first --padding='0,1' "${footer_opts[@]}" \
  --preview='"$TMUX_AGENT_SCRIPTS/preview.sh" {1} {2}' \
  --preview-window="$preview_window" \
  --bind='ctrl-o:toggle-preview' \
  --bind='enter:execute-silent("$TMUX_AGENT_SCRIPTS/open.sh" {1} {2} {3} {4} {5} {6} {8})+abort' \
  --bind='ctrl-n:execute("$TMUX_AGENT_SCRIPTS/new.sh")+abort' \
  --bind='ctrl-e:execute("$TMUX_AGENT_SCRIPTS/rename.sh" {1})+reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  --bind='ctrl-x:execute("$TMUX_AGENT_SCRIPTS/stop.sh" {1})+reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  --bind='ctrl-p:change-preview("$TMUX_AGENT_SCRIPTS/capture.sh" {1})' \
  --bind="ctrl-h:reload(\"\$TMUX_AGENT_SCRIPTS/finder-collect.sh\" \"\$TMUX_AGENT_SNAPSHOT\" history)+change-header($(header_for history))" \
  --bind="ctrl-s:reload(\"\$TMUX_AGENT_SCRIPTS/finder-collect.sh\" \"\$TMUX_AGENT_SNAPSHOT\" sessions)+change-header($(header_for saved))" \
  --bind="ctrl-l:reload(\"\$TMUX_AGENT_SCRIPTS/finder-collect.sh\" \"\$TMUX_AGENT_SNAPSHOT\" live)+change-header($(header_for live))" \
  --bind='ctrl-r:reload("$TMUX_AGENT_SCRIPTS/finder-collect.sh" "$TMUX_AGENT_SNAPSHOT")' \
  <"$snapshot_dir/list" >/dev/null
