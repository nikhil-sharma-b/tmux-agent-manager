#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-sidebar.XXXXXX")
mode=$(tmux show-option -gqv @agent-manager-sidebar-mode)
case $mode in
  live|history|sessions) ;;
  *) mode=live ;;
esac
selected=0
selected_run=''
last_signature=''
force_redraw=1
show_help=0
interval=$(agent_option '@agent-manager-sidebar-interval' '1')
[[ $interval =~ ^[1-9][0-9]*$ ]] || interval=1

persist_mode() {
  tmux set-option -g @agent-manager-sidebar-mode "$mode"
  tmux set-option -p -t "$TMUX_PANE" @agent-manager-sidebar-mode "$mode" 2>/dev/null || true
}

cleanup() {
  printf '\033[?25h\033[?1049l'
  rm -rf "$snapshot_dir"
}
trap cleanup EXIT INT TERM
printf '\033[?1049h\033[?25l'
persist_mode

open_finder() {
  "$plugin_dir/bin/tmux-agent" finder "$mode" || true
  printf '\033[?25l'
  force_redraw=1
}

create_agent() {
  local target width height border
  target=$(tmux show-option -gqv @agent-manager-sidebar-target)
  width=$(agent_option '@agent-manager-width' '80%')
  height=$(agent_option '@agent-manager-height' '70%')
  border=$(agent_option '@agent-manager-border-style' 'fg=brightblack')
  tmux display-popup -E -w "$width" -h "$height" -b rounded -s "$border" -d / \
    -e "TMUX_AGENT_SOURCE_PANE=$target" "$script_dir/new.sh"
}

rename_selected() {
  ((count > 0)) || return
  IFS=$'\t' read -r run kind _ <<<"${rows[$selected]}"
  [[ $kind != native:* ]] || return
  printf '\033[?25h'
  "$script_dir/rename.sh" "$run" || true
  printf '\033[?25l'
  force_redraw=1
}

select_index() {
  selected=$1
  IFS=$'\t' read -r selected_run _ <<<"${rows[$selected]}"
  tmux set-option -p -t "$TMUX_PANE" @agent-manager-sidebar-selected "$selected_run" 2>/dev/null || true
  dirty=1
}

refresh_rows() {
  local geometry signature
  if [[ $mode == sessions ]]; then
    "$script_dir/native-sessions.sh" collect "$snapshot_dir" >/dev/null 2>&1 || true
  else
    "$script_dir/collect.sh" "$snapshot_dir" "$mode" fast >/dev/null 2>&1 || true
  fi
  mapfile -t rows <"$snapshot_dir/list"
  count=${#rows[@]}
  if ((count == 0)); then
    selected=0
    selected_run=''
  else
    if [[ -n $selected_run ]]; then
      for index in "${!rows[@]}"; do
        IFS=$'\t' read -r run _ <<<"${rows[$index]}"
        [[ $run == "$selected_run" ]] && selected=$index
      done
    fi
    ((selected >= count)) && selected=$((count - 1))
    IFS=$'\t' read -r selected_run _ <<<"${rows[$selected]}"
  fi
  tmux set-option -p -t "$TMUX_PANE" @agent-manager-sidebar-selected "$selected_run" 2>/dev/null || true
  geometry=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width}x#{pane_height}' 2>/dev/null || true)
  signature=$(printf '%s\n' "$mode" "$geometry" "$show_help" "${rows[@]}")
  if ((force_redraw == 1)) || [[ $signature != "$last_signature" ]]; then
    dirty=1
    force_redraw=0
    last_signature=$signature
  fi
}

read_geometry() {
  pane_height=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_height}' 2>/dev/null || printf '24')
  pane_width=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null || printf '38')
  printf -v rule '%*s' "$pane_width" ''
  rule=${rule// /─}
}

# Mode tabs double as the only always-visible label for h and s.
render_tabs() {
  local tab out=' '
  for tab in live history saved; do
    if [[ $tab == "$mode" || ($tab == saved && $mode == sessions) ]]; then
      out+=$(printf '\033[1;4m%s\033[0m  ' "$tab")
    else
      out+=$(printf '\033[90m%s\033[0m  ' "$tab")
    fi
  done
  printf '%s\n' "$out"
}

# Padding is computed from character counts because printf widths count bytes.
help_row() {
  local pad=$((5 - ${#1}))
  ((pad < 1)) && pad=1
  printf ' \033[1m%s\033[0m%*s\033[90m%s\033[0m\n' "$1" "$pad" '' "$2"
}

render_help() {
  printf '\033[H\033[2J'
  printf '\033[34;1m keys\033[0m\n'
  printf '\033[90m%s\033[0m\n' "$rule"
  help_row 'j k' 'move'
  help_row '↵' 'open agent'
  help_row 'n' 'new agent'
  help_row '/' 'fuzzy find'
  help_row 'h' 'history'
  help_row 's' 'saved sessions'
  help_row 'r' 'rename agent'
  help_row 'R' 'refresh'
  help_row 'q' 'hide sidebar'
  printf '\033[%d;1H\033[90m%s\033[0m\n \033[90many key closes\033[0m' \
    "$((pane_height - 1))" "$rule"
}

render_rows() {
  local index end offset max_rows label state kind meta glyph label_width remaining

  read_geometry
  if ((show_help == 1)); then
    render_help
    return
  fi

  max_rows=$((pane_height - 6))
  ((max_rows < 1)) && max_rows=1
  offset=0
  ((selected >= max_rows)) && offset=$((selected - max_rows + 1))

  printf '\033[H\033[2J'
  printf '\033[34;1m AI agents\033[0m'
  ((count > 0)) && printf '\033[90m  %s\033[0m' "$count"
  printf '\n'
  render_tabs
  printf '\033[90m%s\033[0m\n' "$rule"

  if ((count == 0)); then
    printf '\n \033[90mNo %s agents\033[0m\n' "$([[ $mode == sessions ]] && printf '%s' saved || printf '%s' "$mode")"
    printf ' \033[90mpress n to start one\033[0m\n'
  else
    end=$((offset + max_rows))
    ((end > count)) && end=$count
    for ((index = offset; index < end; index++)); do
      IFS=$'\t' read -r run kind session window pane size priority label state title metadata <<<"${rows[$index]}"
      if [[ $kind == native:* ]]; then
        meta=${kind#native:}
      else
        meta=$state
      fi
      # Right column only earns its space on a reasonably wide sidebar.
      if ((pane_width < 30)); then
        meta=''
        label_width=$((pane_width - 3))
      else
        meta=$(truncate_text "$meta" 9)
        label_width=$((pane_width - 5 - ${#meta}))
      fi
      ((label_width < 4)) && label_width=4
      label=$(truncate_text "$label" "$label_width")
      remaining=$((label_width - ${#label}))
      case $state in
        attention|turn-failed) glyph='\033[33;1m!\033[0m' ;;
        ready) glyph='\033[32;1m◆\033[0m' ;;
        working) glyph='\033[34;1m●\033[0m' ;;
        stale) glyph='\033[33m?\033[0m' ;;
        crashed) glyph='\033[31;1m×\033[0m' ;;
        *) glyph='\033[90m·\033[0m' ;;
      esac
      if ((index == selected)); then
        printf '\033[34;1m▌\033[0m%b \033[1m%s\033[0m' "$glyph" "$label"
      else
        printf ' %b %s' "$glyph" "$label"
      fi
      ((remaining > 0)) && printf '%*s' "$remaining" ''
      [[ -n $meta ]] && printf '  \033[90m%s\033[0m' "$meta"
      printf '\n'
    done
    ((end < count)) && printf ' \033[90m↓ %s more\033[0m\n' "$((count - end))"
  fi

  printf '\033[%d;1H\033[90m%s\033[0m\n' "$((pane_height - 1))" "$rule"
  printf '\033[90m%s\033[0m' " $(truncate_text '↵ open · n new · / find · ? keys' "$((pane_width - 2))")"
}

while true; do
  dirty=0
  refresh_rows
  ticks=$((interval * 20))
  for ((tick = 0; tick < ticks; tick++)); do
    if ((dirty == 1)); then
      render_rows
      dirty=0
    fi

    key=''
    if IFS= read -rsn1 -t 0.05 key; then
      if ((show_help == 1)); then
        show_help=0
        force_redraw=1
        break
      fi
      # Arrow keys arrive as an escape sequence; map them onto j/k.
      if [[ $key == $'\033' ]]; then
        IFS= read -rsn2 -t 0.02 key || key=''
        case $key in
          '[A') key=k ;;
          '[B') key=j ;;
          *) key='' ;;
        esac
      fi
      case $key in
        j) ((count > 0 && selected < count - 1)) && select_index $((selected + 1)) ;;
        k) ((selected > 0)) && select_index $((selected - 1)) ;;
        '')
          if ((count > 0)); then
            IFS=$'\t' read -r run kind session window pane size priority label _ <<<"${rows[$selected]}"
            "$script_dir/open.sh" "$run" "$kind" "$session" "$window" "$pane" "$size" "$label" || true
          fi
          break
          ;;
        h)
          [[ $mode == live ]] && mode=history || mode=live
          persist_mode
          selected=0
          selected_run=''
          break
          ;;
        s)
          [[ $mode == sessions ]] && mode=live || mode=sessions
          persist_mode
          selected=0
          selected_run=''
          break
          ;;
        n) create_agent; break ;;
        /|f|o) open_finder; break ;;
        '?') show_help=1; force_redraw=1; break ;;
        q) "$script_dir/sidebar-toggle.sh" hide "$TMUX_PANE" "${TMUX_AGENT_CLIENT:-}"; exit 0 ;;
        r) rename_selected; break ;;
        R) force_redraw=1; break ;;
      esac
    fi
  done
done
