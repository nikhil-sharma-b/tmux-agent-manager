#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
kind=${2:-live}

# Every line is cut to the preview width: wrapped lines are what made this
# unreadable in a narrow pane.
cols=${FZF_PREVIEW_COLUMNS:-60}
[[ $cols =~ ^[0-9]+$ ]] && ((cols >= 20)) || cols=60
lines=${FZF_PREVIEW_LINES:-20}
[[ $lines =~ ^[0-9]+$ ]] || lines=20
key_width=8
((cols < 44)) && key_width=6
value_width=$((cols - key_width - 3))
((value_width < 10)) && value_width=10

title() {
  printf '\033[1m%s\033[0m\n' "$(truncate_text "$1" $((cols - 1)))"
}

subtitle() {
  printf '\033[90m%s\033[0m\n\n' "$(truncate_text "$1" $((cols - 1)))"
}

field() {
  printf ' \033[90m%-*s\033[0m %s\n' "$key_width" "$1" "$(truncate_text "$2" "$value_width")"
}

# Paths and IDs matter at their tail, so they lose characters from the left.
tail_text() {
  local text=${1/#$HOME/\~}
  if ((${#text} > value_width)); then
    printf '…%s' "${text: -$((value_width - 1))}"
  else
    printf '%s' "$text"
  fi
}

if [[ $kind == native:* ]]; then
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-manager/native-sessions.tsv
  [[ -f $cache ]] || exit 0
  IFS=$'\t' read -r _ _ cwd _ _ _ _ session_title _ < <(awk -F '\t' -v id="$run" '$1 == id' "$cache")
  [[ -n ${session_title:-} ]] || exit 0
  title "$session_title"
  subtitle "${kind#native:} · saved session"
  field path "$(tail_text "$cwd")"
  exit 0
fi

valid_id "$run" || exit 1
if [[ $kind == history || $kind == history-only ]]; then
  file="$(history_root)/$run.json"
  [[ -f $file ]] || exit 0
  # A run outside a repository has an empty branch, which a tab-separated read
  # would drop, shifting the path and state into the wrong fields.
  mapfile -t fields < <(jq -r '
    .label, .harness, (if (.branch // "") == "" then "-" else .branch end),
    .cwd, (.last_event.state // "unknown"), (.ended_at|todate)' "$file")
  label=${fields[0]:-} harness=${fields[1]:-} branch=${fields[2]:--}
  cwd=${fields[3]:-} state=${fields[4]:-unknown} ended=${fields[5]:-}
  title "$label"
  subtitle "$harness · $state · no resume"
  field branch "${branch:--}"
  field path "$(tail_text "$cwd")"
  field ended "$ended"
  exit 0
fi

dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
event=$(latest_event "$dir/events.jsonl")
IFS=$'\t' read -r label harness managed branch cwd session window pane natives < <(jq -r '
  [.label,.harness,(.managed|tostring),(if .branch == "" then "-" else .branch end),.cwd,
   .session_id,.window_id,.pane_id,((.native_ids // [])|length|tostring)]|@tsv' "$dir/meta.json")
state=$(jq -r '.state' <<<"$event")

title "$label"
[[ $managed == true ]] || harness="$harness (degraded)"
subtitle "$harness · $state"
field branch "$branch"
field path "$(tail_text "$cwd")"
field pane "$session $window $pane"
if ((natives > 0)); then
  native_first=$(jq -r '.native_ids[0]' "$dir/meta.json")
  ((natives > 1)) && native_first="$native_first +$((natives - 1))"
  field native "$(tail_text "$native_first")"
fi

# Whatever vertical space is left goes to the event log, newest last.
budget=$((lines - 9))
((budget < 2)) && budget=2
((budget > 8)) && budget=8
printf '\n \033[90mrecent\033[0m\n\n'
# A turn emits the same event many times; repeats collapse into one line.
jq -sr '.[-60:][] | .at as $at |
  [($at|try strflocaltime("%H:%M") catch ($at|todate|.[11:16])),
   (.event|split(".")|last),.state]|@tsv' "$dir/events.jsonl" |
  awk -F '\t' '{
    key = $2 FS $3
    if (key == last) { count++ } else { if (last != "") print at "\t" last "\t" count; last = key; count = 1 }
    at = $1
  } END { if (last != "") print at "\t" last "\t" count }' |
  tail -n "$budget" |
  while IFS=$'\t' read -r at name event_state count; do
    ((count > 1)) && event_state="$event_state ×$count"
    printf ' \033[90m%s\033[0m %s\n' "$at" \
      "$(truncate_text "$name $event_state" $((cols - 8)))"
  done
