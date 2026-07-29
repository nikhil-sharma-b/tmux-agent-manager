#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

pane=${1:-${TMUX_PANE:-}}
[[ -n $pane ]] || exit 0
run=$(tmux display-message -p -t "$pane" '#{@agent-manager-run}' 2>/dev/null || true)
[[ -n $run ]] || exit 0
mark_seen "$run" 2>/dev/null || true
