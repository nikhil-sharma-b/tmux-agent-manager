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
# Same reason as rename: draw on a clean screen so a narrow sidebar stays legible.
printf '\033[2J\033[H\n  \033[1mstop\033[0m  \033[90m%s\033[0m\n\n  \033[90minterrupts the agent · y confirms\033[0m\n\n  › ' \
  "$(truncate_text "$label" 24)"
IFS= read -r answer || exit 0
[[ $answer == y || $answer == Y ]] || exit 0
tmux send-keys -t "$pane" C-c
