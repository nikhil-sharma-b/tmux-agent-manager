#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

run=${1:?run ID required}
kind=${2:?entry kind required}
if [[ $kind == native:* ]]; then
  harness=${kind#native:}
  native_id=$run
  cwd=${3:?native cwd required}
  label=${7:-${cwd##*/}}
  [[ $harness == claude || $harness == codex || $harness == opencode ]] || exit 1
  [[ $native_id =~ ^[[:alnum:]_.:-]+$ ]] || exit 1
  [[ -d $cwd ]] || cwd=$HOME
  thread=$(new_uuid)
  new_run=$(new_uuid)
  session=$(agent_session_name "$label" "$new_run")
  command="$(shell_quote "$plugin_dir/bin/tmux-agent") run --thread $(shell_quote "$thread") --run $(shell_quote "$new_run") --agent $(shell_quote "$harness") --label $(shell_quote "$label") --resume $(shell_quote "$native_id")"
  create_agent_session "$session" "$cwd" "$label" "$command"
  exit 0
fi

valid_id "$run" || exit 1
if [[ $kind == live ]]; then
  exec "$script_dir/jump.sh" "$run" "${3:?session ID required}" \
    "${4:?window ID required}" "${5:?pane ID required}" "${6:?event offset required}"
fi

# An archived run whose conversation the harness no longer offers still opens:
# a fresh agent in the directory the work happened in, with nothing resumed.
file="$(history_root)/$run.json"
[[ -f $file ]] || exit 1
thread=$(jq -r '.thread_id' "$file")
harness=$(jq -r '.harness' "$file")
label=$(jq -r '.label' "$file")
cwd=$(jq -r '.cwd' "$file")
[[ -d $cwd ]] || cwd=$HOME
native_id=$(jq -r '.native_ids[-1] // ""' "$file")
[[ $native_id =~ ^[[:alnum:]_.:-]+$ ]] || native_id=''
new_run=$(new_uuid)
session=$(agent_session_name "$label" "$new_run")
command="$(shell_quote "$plugin_dir/bin/tmux-agent") run --thread $(shell_quote "$thread") --run $(shell_quote "$new_run") --agent $(shell_quote "$harness") --label $(shell_quote "$label")"
[[ -n $native_id ]] && command+=" --resume $(shell_quote "$native_id")"
create_agent_session "$session" "$cwd" "$label" "$command"
