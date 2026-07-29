#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
valid_id "$run" || exit 1
dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 0
label=$(jq -r '.label' "$dir/meta.json")
pane=$(jq -r '.pane_id' "$dir/meta.json")
[[ $(tmux display-message -p -t "$pane" '#{@agent-manager-run}' 2>/dev/null || true) == "$run" ]] || exit 1
printf 'Stop "%s"? [y/N] ' "$label"
IFS= read -r answer || exit 0
[[ $answer == y || $answer == Y ]] || exit 0
tmux send-keys -t "$pane" C-c
