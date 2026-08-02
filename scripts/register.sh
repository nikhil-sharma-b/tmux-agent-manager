#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

thread='' run='' harness='' label='' pane=${TMUX_PANE:-} managed=true
while [[ $# -gt 0 ]]; do
  case $1 in
    --thread) thread=$2; shift 2 ;;
    --run) run=$2; shift 2 ;;
    --harness) harness=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --pane) pane=$2; shift 2 ;;
    --degraded) managed=false; shift ;;
    *) printf 'tmux-agent register: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

thread=${thread:-$(new_uuid)}
run=${run:-$(new_uuid)}
[[ -n $harness ]] || { printf 'tmux-agent register: --harness required\n' >&2; exit 2; }
[[ -n $pane ]] || { printf 'tmux-agent register: must run inside tmux\n' >&2; exit 1; }
valid_id "$thread" && valid_id "$run" || { printf 'tmux-agent register: invalid ID\n' >&2; exit 2; }
[[ $harness == claude || $harness == codex || $harness == opencode || $harness == antigravity ]] \
  || { printf 'tmux-agent register: unsupported harness\n' >&2; exit 2; }
register_run "$thread" "$run" "$harness" "$label" "$managed" "$pane"
append_event "$run" starting registered '' ''
printf '%s\t%s\n' "$thread" "$run"
