#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
valid_id "$run" || exit 1
dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
current=$(jq -r '.label' "$dir/meta.json")
# The sidebar is a narrow pane with a frame already on screen. Owning the whole
# screen keeps the prompt off the footer instead of wrapping through it.
printf '\033[2J\033[H\n  \033[1mrename\033[0m  \033[90m%s · empty cancels\033[0m\n\n  › ' \
  "$(truncate_text "$current" 24)"
IFS= read -r label || exit 0
label=$(clean_text "$label")
[[ -n $label ]] || exit 0
exec 9>"$dir/.lock"
flock 9
[[ -f $dir/meta.json ]] || exit 0
tmp="$dir/meta.json.tmp.$$"
jq --arg label "$label" '.label=$label' "$dir/meta.json" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$dir/meta.json"
flock -u 9
rebuild_cache
