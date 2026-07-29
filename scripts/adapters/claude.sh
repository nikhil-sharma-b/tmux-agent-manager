#!/usr/bin/env bash

set -euo pipefail

event=${1:-}
payload=$(</dev/stdin)
[[ -n $payload ]] || exit 0
jq -e . >/dev/null <<<"$payload" || exit 0
bin=${TMUX_AGENT_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/tmux-agent"}
native_id=$(jq -r '.session_id // ""' <<<"$payload")
message=$(jq -r '.message // .error // .notification_type // ""' <<<"$payload")

export TMUX_AGENT_NATIVE_ID=$native_id
export TMUX_AGENT_MESSAGE=$message
export TMUX_AGENT_HARNESS=claude

case $event in
  SessionStart) exec "$bin" event idle "$event" ;;
  UserPromptSubmit|PreToolUse|PostToolUse|PostToolUseFailure)
    exec "$bin" event working "$event"
    ;;
  PermissionRequest) exec "$bin" event attention "$event" ;;
  Notification)
    case $(jq -r '.notification_type // ""' <<<"$payload") in
      permission_prompt|idle_prompt) exec "$bin" event attention "$event" ;;
      *) exit 0 ;;
    esac
    ;;
  Stop) exec "$bin" event ready "$event" ;;
  StopFailure) exec "$bin" event turn-failed "$event" ;;
  SessionEnd) exec "$bin" event exited "$event" ;;
esac
