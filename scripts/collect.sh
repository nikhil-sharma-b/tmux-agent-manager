#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

snapshot_dir=${1:?snapshot directory required}
mode=${2:-live}
refresh=${3:-full}
list_tmp="$snapshot_dir/list.tmp"
: >"$list_tmp"

dim=$(printf '\033[90m')
reset=$(printf '\033[0m')

if [[ $mode == history ]]; then
  ensure_state_dirs
  for entry in "$(history_root)"/*.json; do
    [[ -f $entry ]] || continue
    jq -r --arg dim "$dim" --arg reset "$reset" '
      def clean: gsub("[\\t\\r\\n]";" ");
      def fit: (if length > 26 then .[0:25] + "…" else . end)
        | (if length < 26 then . + (" " * (26 - length)) else . end);
      [.run_id,"history","-","-","-","0","9",(.label|clean),"history",
      ($dim + "·" + $reset + " " + (.label|clean|fit)),
      ($dim + ([.harness,((.branch // "")|clean),(.ended_at|todate|.[0:10])]
        | map(select(. != "")) | join(" · ")) + $reset)]|@tsv' "$entry" >>"$list_tmp"
  done
else
  if [[ $refresh == fast ]]; then
    merge_watch >/dev/null 2>&1 || true
  else
    reconcile_runs >/dev/null 2>&1 || true
  fi
  for dir in "$(runtime_root)"/runs/*; do
    [[ -f $dir/meta.json ]] || continue
    event=$(latest_event "$dir/events.jsonl")
    state=$(effective_state "$(jq -r '.state' <<<"$event")" "$(jq -r '.at' <<<"$event")")
    pane=$(jq -r '.pane_id' "$dir/meta.json")
    location=$(tmux display-message -p -t "$pane" $'#{session_id}\t#{window_id}' 2>/dev/null || true)
    [[ -n $location ]] || continue
    IFS=$'\t' read -r session window <<<"$location"
    size=$(wc -c <"$dir/events.jsonl")
    seen=$(<"$dir/seen")
    unseen=0
    [[ $size -gt $seen && $state != working && $state != starting ]] && unseen=1
    [[ $state == ready && $unseen == 0 ]] && state=idle
    case $state in
      attention|turn-failed) glyph='\033[33;1m!\033[0m'; priority=1 ;;
      ready) glyph='\033[32;1m◆\033[0m'; priority=2 ;;
      working) glyph='\033[34;1m●\033[0m'; priority=3 ;;
      stale) glyph='\033[33m?\033[0m'; priority=4 ;;
      crashed) glyph='\033[31;1m×\033[0m'; priority=5 ;;
      *) glyph='\033[90m·\033[0m'; priority=6 ;;
    esac
    label=$(jq -r '.label|gsub("[\\t\\r\\n]";" ")' "$dir/meta.json")
    harness=$(jq -r '.harness' "$dir/meta.json")
    branch=$(jq -r '.branch|gsub("[\\t\\r\\n]";" ")' "$dir/meta.json")
    row_meta="$state · $harness"
    [[ -n $branch ]] && row_meta="$row_meta · $branch"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%b %-26s\t\033[90m%s\033[0m\n' \
      "${dir##*/}" live "$session" "$window" "$pane" "$size" "$priority" "$label" "$state" \
      "$glyph" "$(truncate_text "$label" 26)" "$row_meta" >>"$list_tmp"
  done
fi

sort -t $'\t' -k7,7n -k8,8 "$list_tmp" >"$snapshot_dir/list"
cat "$snapshot_dir/list"
