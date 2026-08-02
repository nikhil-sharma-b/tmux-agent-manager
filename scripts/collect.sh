#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

snapshot_dir=${1:?snapshot directory required}
mode=${2:-live}
refresh=${3:-full}
list_tmp="$snapshot_dir/list.tmp"
: >"$list_tmp"

# Ended runs are folded into the saved list that native-sessions.sh builds, so
# this only ever produces the live one.
[[ $mode == live ]] || exit 0

if [[ $refresh == fast ]]; then
  merge_watch >/dev/null 2>&1 || true
else
  reconcile_runs >/dev/null 2>&1 || true
fi
unnamed=0
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
    # One read for every field this row needs, including whether the run is
    # still waiting to be named by its harness. Tab counts as IFS whitespace,
    # so a tab-separated read would swallow the empty fields and shift the
    # rest along; a line per value keeps them.
    mapfile -t fields < <(jq -r '
      def clean: gsub("[\\t\\r\\n]";" ");
      (.label|clean), .harness, (.branch|clean), ((.adopted_title // "")|clean),
      ((.label_pinned // false)|tostring), ((.native_ids // [])|last // "")
    ' "$dir/meta.json")
    label=${fields[0]:-} harness=${fields[1]:-} branch=${fields[2]:-}
    adopted=${fields[3]:-} pinned=${fields[4]:-} native=${fields[5]:-}
    if [[ $pinned != true && -z $adopted && -n $native ]]; then
      adopt_saved_title "${dir##*/}" || true
      label=$(jq -r '.label|gsub("[\\t\\r\\n]";" ")' "$dir/meta.json")
      unnamed=1
    fi
    row_meta="$state · $harness"
    [[ -n $branch ]] && row_meta="$row_meta · $branch"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%b %-26s\t\033[90m%s\033[0m\n' \
      "${dir##*/}" live "$session" "$window" "$pane" "$size" "$priority" "$label" "$state" \
      "$glyph" "$(truncate_text "$label" 26)" "$row_meta" >>"$list_tmp"
done
# A run still waiting for its name is the only reason to rebuild the catalog
# off the back of a live refresh, and the TTL still governs how often.
((unnamed == 0)) || native_catalog_watch >/dev/null 2>&1 || true

sort -t $'\t' -k7,7n -k8,8 "$list_tmp" >"$snapshot_dir/list"
cat "$snapshot_dir/list"
