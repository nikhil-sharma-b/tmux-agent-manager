#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

snapshot_dir=${1:?snapshot directory required}
requested_mode=${2:-}
mode_file="$snapshot_dir/mode"

# history and sessions were separate scopes before they merged into saved;
# both names still arrive from older callers and persisted tmux options.
if [[ -n $requested_mode ]]; then
  case $requested_mode in
    live) ;;
    saved|history|sessions) requested_mode=saved ;;
    *) exit 2 ;;
  esac
  printf '%s\n' "$requested_mode" >"$mode_file"
fi

mode=live
[[ -f $mode_file ]] && mode=$(<"$mode_file")
[[ $mode == live ]] || mode=saved
if [[ $mode == saved ]]; then
  "$script_dir/native-sessions.sh" collect "$snapshot_dir"
else
  "$script_dir/collect.sh" "$snapshot_dir" "$mode"
fi
