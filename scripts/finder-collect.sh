#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

snapshot_dir=${1:?snapshot directory required}
requested_mode=${2:-}
mode_file="$snapshot_dir/mode"

if [[ -n $requested_mode ]]; then
  case $requested_mode in
    live|history|sessions) ;;
    *) exit 2 ;;
  esac
  printf '%s\n' "$requested_mode" >"$mode_file"
fi

mode=$(<"$mode_file")
if [[ $mode == sessions ]]; then
  "$script_dir/native-sessions.sh" collect "$snapshot_dir"
else
  "$script_dir/collect.sh" "$snapshot_dir" "$mode"
fi
