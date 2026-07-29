#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
kind=${2:-live}
if [[ $kind == native:* ]]; then
  cache=${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-manager/native-sessions.tsv
  [[ -f $cache ]] || exit 0
  awk -F '\t' -v id="$run" '$1 == id {
    printf "\033[34;1m%s\033[0m\n\n  agent     %s\n  path      %s\n  state     saved session\n", $8, substr($2,8), $3
    exit
  }' "$cache"
  exit 0
fi

valid_id "$run" || exit 1
if [[ $kind == history ]]; then
  file="$(history_root)/$run.json"
  [[ -f $file ]] || exit 0
  jq -r '"\u001b[34;1m" + .label + "\u001b[0m\n\n" +
    "  agent     " + .harness + "\n" +
    "  branch    " + (.branch // "-") + "\n" +
    "  path      " + .cwd + "\n" +
    "  state     " + (.last_event.state // "unknown") + "\n" +
    "  finished  " + (.ended_at|todate)' "$file"
  exit 0
fi

dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
event=$(latest_event "$dir/events.jsonl")
jq -r --argjson event "$event" '"\u001b[34;1m" + .label + "\u001b[0m\n\n" +
  "  agent     " + .harness + (if .managed then "" else " (degraded)" end) + "\n" +
  "  state     " + $event.state + "\n" +
  "  branch    " + (if .branch == "" then "-" else .branch end) + "\n" +
  "  path      " + .cwd + "\n" +
  "  pane      " + .session_id + " / " + .window_id + " / " + .pane_id + "\n" +
  "  native    " + (if (.native_ids|length)==0 then "-" else (.native_ids|join(", ")) end)' "$dir/meta.json"
printf '\n\033[90mrecent events\033[0m\n\n'
jq -sr '.[-8:][] | "  " + (.at|todate) + "  " + .event + "  " + .state' "$dir/events.jsonl"
