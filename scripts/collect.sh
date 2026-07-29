#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

snapshot_dir=${1:?snapshot directory required}
mode=${2:-live}
refresh=${3:-full}
list_tmp="$snapshot_dir/list.tmp"
: >"$list_tmp"

if [[ $mode == history ]]; then
  ensure_state_dirs
  for meta in "$(history_root)"/*.json; do
    [[ -f $meta ]] || continue
    jq -r '[.run_id,"history","-","-","-","0","9",(.label|gsub("[\\t\\r\\n]";" ")),"history",
      ("\u001b[90m·\u001b[0m " + (.label|gsub("[\\t\\r\\n]";" "))),
      ("\u001b[90m" + .harness + " · " + ((.branch // "")|gsub("[\\t\\r\\n]";" ")) + " · history\u001b[0m")]|@tsv' "$meta" >>"$list_tmp"
  done
else
  [[ $refresh == fast ]] || reconcile_runs >/dev/null 2>&1 || true
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
    suffix=''
    [[ $unseen == 1 ]] && suffix=' · unseen'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%b %-26s\t\033[90m%s · %s · %s%s\033[0m\n' \
      "${dir##*/}" live "$session" "$window" "$pane" "$size" "$priority" "$label" "$state" "$glyph" "$label" \
      "$harness" "${branch:--}" "$state" "$suffix" >>"$list_tmp"
  done
fi

sort -t $'\t' -k7,7n -k8,8 "$list_tmp" >"$snapshot_dir/list"
cat "$snapshot_dir/list"
