#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

thread='' run='' harness='' label=${TMUX_AGENT_LABEL:-} resume=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --thread) thread=$2; shift 2 ;;
    --run) run=$2; shift 2 ;;
    --harness|--agent) harness=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --resume) resume=$2; shift 2 ;;
    --) shift; break ;;
    *) printf 'tmux-agent run: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -n ${TMUX_PANE:-} ]] || { printf 'tmux-agent run: must run inside tmux\n' >&2; exit 1; }
thread=${thread:-$(new_uuid)}
run=${run:-$(new_uuid)}
[[ -n $harness ]] || { printf 'tmux-agent run: --harness required\n' >&2; exit 2; }
valid_id "$thread" && valid_id "$run" || { printf 'tmux-agent run: invalid ID\n' >&2; exit 2; }
case $harness in
  claude|codex|opencode) ;;
  *) printf 'tmux-agent run: unsupported harness: %s\n' "$harness" >&2; exit 2 ;;
esac

if [[ ! -f $(run_dir "$run")/meta.json ]]; then
  register_run "$thread" "$run" "$harness" "$label" true "$TMUX_PANE"
fi
append_event "$run" starting wrapper-start '' ''

export TMUX_AGENT_THREAD_ID=$thread
export TMUX_AGENT_RUN_ID=$run
export TMUX_AGENT_HARNESS=$harness
export TMUX_AGENT_PANE_ID=$TMUX_PANE
export TMUX_AGENT_BIN="$plugin_dir/bin/tmux-agent"

case $harness in
  claude)
    command=(claude)
    [[ -n $resume ]] && command+=(--resume "$resume")
    ;;
  codex)
    command=(codex)
    [[ -n $resume ]] && command+=(resume "$resume")
    ;;
  opencode)
    command=(opencode)
    [[ -n $resume ]] && command+=(--session "$resume")
    ;;
esac
command+=("$@")

set +e
"${command[@]}"
status=$?
set -e
if [[ $status -eq 0 ]]; then
  append_event "$run" exited process-exit '' 'process exited cleanly' || true
  archive_run "$run" exited
  rebuild_cache
elif [[ $status -eq 130 || $status -eq 143 ]]; then
  append_event "$run" cancelled process-exit '' "process cancelled with status $status" || true
  archive_run "$run" cancelled
  rebuild_cache
else
  append_event "$run" crashed process-exit '' "process exited with status $status" || true
fi
exit "$status"
