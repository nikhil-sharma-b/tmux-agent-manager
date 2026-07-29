#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
valid_id "$run" || exit 1
dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
printf 'New label: '
IFS= read -r label || exit 0
label=$(clean_text "$label")
[[ -n $label ]] || exit 0
exec 9>"$dir/.lock"
flock 9
tmp="$dir/meta.json.tmp.$$"
jq --arg label "$label" '.label=$label' "$dir/meta.json" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$dir/meta.json"
flock -u 9
