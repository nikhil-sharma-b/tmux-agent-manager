#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
session=${2:?session ID required}
window=${3:?window ID required}
pane=${4:?pane ID required}
snapshot_size=${5:?event offset required}
client=${TMUX_AGENT_CLIENT:-}

[[ $run =~ ^[[:alnum:]_-]+$ && $session =~ ^\$[0-9]+$ && $window =~ ^@[0-9]+$ && $pane =~ ^%[0-9]+$ ]] || exit 1
dir=$(run_dir "$run")
[[ -f $dir/meta.json ]] || exit 1
[[ $(tmux display-message -p -t "$pane" '#{@agent-manager-run}' 2>/dev/null) == "$run" ]] || exit 1

args=(switch-client)
[[ -n $client ]] && args+=(-c "$client")
tmux "${args[@]}" -t "$session" \; select-window -t "$window" \; select-pane -t "$pane"

exec 9>"$dir/.lock"
flock 9
current=$(<"$dir/seen")
if [[ $snapshot_size -gt $current ]]; then
  tmp="$dir/seen.tmp.$$"
  printf '%s\n' "$snapshot_size" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/seen"
fi
flock -u 9
rebuild_cache >/dev/null 2>&1 &
