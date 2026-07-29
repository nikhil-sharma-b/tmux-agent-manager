#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
valid_id "$run" || exit 1
dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
pane=$(jq -r '.pane_id' "$dir/meta.json")
tmux capture-pane -p -S -40 -t "$pane" 2>/dev/null | tr -d '\000-\010\013\014\016-\037'
