#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
kind=${2:-live}
dim=$(printf '\033[90m')
title_color=$(printf '\033[1m')
reset=$(printf '\033[0m')

# Keys are dim so the eye lands on values; every view uses the same key column.
if [[ $kind == native:* ]]; then
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-manager/native-sessions.tsv
  [[ -f $cache ]] || exit 0
  awk -F '\t' -v id="$run" -v dim="$dim" -v bold="$title_color" -v reset="$reset" '$1 == id {
    printf "%s%s%s\n%s%s · saved session%s\n\n", bold, $8, reset, dim, substr($2,8), reset
    printf "%s  path      %s%s\n", dim, reset, $3
    exit
  }' "$cache"
  exit 0
fi

valid_id "$run" || exit 1
if [[ $kind == history ]]; then
  file="$(history_root)/$run.json"
  [[ -f $file ]] || exit 0
  jq -r --arg dim "$dim" --arg bold "$title_color" --arg reset "$reset" '
    def key(k): $dim + "  " + (k + "        ")[0:10] + $reset;
    $bold + .label + $reset + "\n" +
    $dim + .harness + " · " + (.last_event.state // "unknown") + " · history" + $reset + "\n\n" +
    key("branch") + (.branch // "-") + "\n" +
    key("path") + .cwd + "\n" +
    key("finished") + (.ended_at|todate)' "$file"
  exit 0
fi

dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
event=$(latest_event "$dir/events.jsonl")
jq -r --argjson event "$event" --arg dim "$dim" --arg bold "$title_color" --arg reset "$reset" '
  def key(k): $dim + "  " + (k + "        ")[0:10] + $reset;
  $bold + .label + $reset + "\n" +
  $dim + .harness + (if .managed then "" else " (degraded)" end) + " · " + $event.state + $reset + "\n\n" +
  key("branch") + (if .branch == "" then "-" else .branch end) + "\n" +
  key("path") + .cwd + "\n" +
  key("pane") + .session_id + " / " + .window_id + " / " + .pane_id + "\n" +
  key("native") + (if (.native_ids|length)==0 then "-" else (.native_ids|join(", ")) end)' "$dir/meta.json"
printf '\n%s  recent%s\n\n' "$dim" "$reset"
jq -sr --arg dim "$dim" --arg reset "$reset" '.[-6:][] | .at as $at |
  "  " + $dim + ($at|try strflocaltime("%H:%M") catch ($at|todate|.[11:16])) + $reset
  + "  " + (.event + "                  ")[0:18] + .state' "$dir/events.jsonl"
