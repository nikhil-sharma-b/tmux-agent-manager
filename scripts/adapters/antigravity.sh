#!/usr/bin/env bash

set -uo pipefail

event=${1:-}
# Antigravity runs hooks synchronously and reads one JSON object back from
# stdout. A hook that prints nothing, prints twice, or exits before printing
# stalls or breaks the agent loop, so the response is chosen up front and
# printed no matter what the rest of this script finds.
case $event in
  PreInvocation|PostInvocation) response='{"injectSteps":[]}' ;;
  # Any value other than "continue" lets the turn end normally.
  Stop) response='{"decision":"stop"}' ;;
  *) response='{}' ;;
esac
respond() {
  # Clearing the trap first keeps the exit below from re-entering this function
  # and printing a second object.
  trap - EXIT
  printf '%s\n' "$response"
  exit 0
}
trap respond EXIT

# Hook runners may provide fd 0 as a socket, which cannot be reopened through /dev/stdin.
payload=$(cat)
[[ -n $payload ]] || respond
jq -e . >/dev/null 2>&1 <<<"$payload" || respond
bin=${TMUX_AGENT_BIN:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/tmux-agent"}
native_id=$(jq -r '.conversationId // ""' <<<"$payload")
message=$(jq -r '.error // .reason // ""' <<<"$payload")

case $event in
  PreInvocation|PostInvocation|PostToolUse) state=working ;;
  Stop)
    # Stop ends a turn, not the process: the CLI is still alive and waiting, so
    # this never reports exited. terminationReason distinguishes a finished turn
    # from one that ran out of steps or died.
    reason=$(jq -r '.terminationReason // ""' <<<"$payload")
    if [[ -n $message || $reason == error || $reason == max_steps_exceeded ]]; then
      state=turn-failed
    else
      state=ready
    fi
    ;;
  *) respond ;;
esac

# Detached with every descriptor closed: an inherited stdout would keep
# Antigravity waiting on this hook until the manager finished writing.
launcher=()
command -v setsid >/dev/null 2>&1 && launcher=(setsid)
TMUX_AGENT_HARNESS=antigravity \
TMUX_AGENT_NATIVE_ID=$native_id \
TMUX_AGENT_MESSAGE=$message \
  "${launcher[@]}" "$bin" event "$state" "$event" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
respond
