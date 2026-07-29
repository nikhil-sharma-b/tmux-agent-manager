#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-sidebar.XXXXXX")
mode=live
selected=0
selected_run=''
interval=$(agent_option '@agent-manager-sidebar-interval' '1')
[[ $interval =~ ^[1-9][0-9]*$ ]] || interval=1

cleanup() {
  printf '\033[?25h\033[?1049l'
  rm -rf "$snapshot_dir"
}
trap cleanup EXIT INT TERM
printf '\033[?1049h\033[?25l'

open_finder() {
  local width height border title
  width=$(agent_option '@agent-manager-width' '80%')
  height=$(agent_option '@agent-manager-height' '70%')
  border=$(agent_option '@agent-manager-border-style' 'fg=brightblack')
  title=$(agent_option '@agent-manager-title' '')
  tmux display-popup -E -w "$width" -h "$height" -b rounded -s "$border" \
    -T "$title" -d / "$plugin_dir/bin/tmux-agent finder"
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

refresh_rows() {
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
}

render_rows() {
  pane_height=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_height}' 2>/dev/null || printf '24')
  pane_width=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width}' 2>/dev/null || printf '38')
  max_rows=$(((pane_height - 6) / 3))
  ((max_rows < 1)) && max_rows=1
  offset=0
  ((selected >= max_rows)) && offset=$((selected - max_rows + 1))

  printf '\033[H\033[2J'
  printf '\033[34;1m AI agents\033[0m  \033[90m%s\033[0m\n' "$mode"
  printf '\033[90m j/k move · ↵ open · n new\033[0m\n'
  printf '\033[90m s saved · h history · o popup\033[0m\n\n'
  if ((count == 0)); then
    printf ' \033[90mNo %s agents\033[0m\n' "$mode"
  else
    end=$((offset + max_rows))
    ((end > count)) && end=$count
    for ((index = offset; index < end; index++)); do
      IFS=$'\t' read -r run kind session window pane size priority label state title metadata <<<"${rows[$index]}"
      label_width=$((pane_width > 6 ? pane_width - 6 : 18))
      display_label=$(truncate_text "$label" "$label_width")
      if ((index == selected)); then
        row_width=$((pane_width > 4 ? pane_width - 3 : 20))
        printf '\033[7m %-*s \033[0m\n' "$row_width" "$display_label"
      else
        case $state in
          attention|turn-failed) glyph='\033[33;1m!\033[0m' ;;
          ready) glyph='\033[32;1m◆\033[0m' ;;
          working) glyph='\033[34;1m●\033[0m' ;;
          stale) glyph='\033[33m?\033[0m' ;;
          crashed) glyph='\033[31;1m×\033[0m' ;;
          *) glyph='\033[90m·\033[0m' ;;
        esac
        printf ' %b %s\n' "$glyph" "$display_label"
      fi
      printf '   \033[90m%s\033[0m\n\n' "$state"
    done
  fi
}

while true; do
  refresh_rows
  dirty=1
  ticks=$((interval * 20))
  for ((tick = 0; tick < ticks; tick++)); do
    if ((dirty == 1)); then
      render_rows
      dirty=0
    fi

    key=''
    if IFS= read -rsn1 -t 0.05 key; then
      case $key in
        j)
          if ((count > 0 && selected < count - 1)); then
            selected=$((selected + 1))
            IFS=$'\t' read -r selected_run _ <<<"${rows[$selected]}"
            tmux set-option -p -t "$TMUX_PANE" @agent-manager-sidebar-selected "$selected_run" 2>/dev/null || true
            dirty=1
          fi
          ;;
        k)
          if ((selected > 0)); then
            selected=$((selected - 1))
            IFS=$'\t' read -r selected_run _ <<<"${rows[$selected]}"
            tmux set-option -p -t "$TMUX_PANE" @agent-manager-sidebar-selected "$selected_run" 2>/dev/null || true
            dirty=1
          fi
          ;;
        '')
          if ((count > 0)); then
            IFS=$'\t' read -r run kind session window pane size _ <<<"${rows[$selected]}"
            "$script_dir/open.sh" "$run" "$kind" "$session" "$window" "$pane" "$size" "$label" || true
          fi
          break
          ;;
        h)
          [[ $mode == live ]] && mode=history || mode=live
          selected=0
          selected_run=''
          break
          ;;
        s)
          [[ $mode == sessions ]] && mode=live || mode=sessions
          selected=0
          selected_run=''
          break
          ;;
        n) create_agent; break ;;
        o) open_finder; break ;;
        q) "$script_dir/sidebar-toggle.sh" hide "$TMUX_PANE" "${TMUX_AGENT_CLIENT:-}"; exit 0 ;;
        r) break ;;
      esac
    fi
  done
done
