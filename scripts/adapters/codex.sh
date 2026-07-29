#!/usr/bin/env bash

set -euo pipefail

event=${1:-}
# Hook runners may provide fd 0 as a socket, which cannot be reopened through /dev/stdin.
payload=$(cat)
[[ -n $payload ]] || exit 0
jq -e . >/dev/null <<<"$payload" || exit 0
bin=${TMUX_AGENT_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/tmux-agent"}
native_id=$(jq -r '.session_id // .thread_id // ""' <<<"$payload")
message=$(jq -r '.message // .error // ""' <<<"$payload")

export TMUX_AGENT_NATIVE_ID=$native_id
export TMUX_AGENT_MESSAGE=$message
export TMUX_AGENT_HARNESS=codex

case $event in
  SessionStart) exec "$bin" event idle "$event" ;;
  UserPromptSubmit|PreToolUse|PostToolUse|PostToolUseFailure)
    exec "$bin" event working "$event"
    ;;
  PermissionRequest) exec "$bin" event attention "$event" ;;
  Stop) exec "$bin" event ready "$event" ;;
  SessionEnd) exec "$bin" event exited "$event" ;;
esac
