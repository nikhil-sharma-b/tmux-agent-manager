#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

state=${1:?state required}
event=${2:-$state}
harness=${TMUX_AGENT_HARNESS:-${3:-unknown}}
native_id=${TMUX_AGENT_NATIVE_ID:-${4:-}}
message=${TMUX_AGENT_MESSAGE:-${5:-}}
pane=${TMUX_AGENT_PANE_ID:-${TMUX_PANE:-}}
run=${TMUX_AGENT_RUN_ID:-}

[[ -n $pane ]] || exit 0
if [[ -z $run ]]; then
  run=$(find_run_for_pane "$pane" "$harness" 2>/dev/null || true)
fi
if [[ -z $run ]]; then
  run=$(register_degraded_run "$harness" "$native_id" "$pane")
fi
append_event "$run" "$state" "$event" "$native_id" "$message"
