#!/usr/bin/env bash
# End-to-end scenarios against a real tmux server: the state machine, how runs
# end, and the pieces run.sh only covers in passing.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
tam_start scenarios

emit() {
  local run=$1 pane=$2 harness=$3 event=$4 payload=${5:-'{"session_id":"n1"}'}
  printf '%s' "$payload" |
    TMUX_AGENT_RUN_ID=$run TMUX_AGENT_PANE_ID=$pane TMUX_AGENT_HARNESS=$harness \
      "$root/scripts/adapters/$harness.sh" "$event"
}

idle_pane() { tmux split-window -d -P -F '#{pane_id}' -t test -c "$tmp/work" 'sleep 300'; }
register()  { IFS=$'\t' read -r _ "$1" < <("$root/bin/tmux-agent" register \
              --harness "$2" --label "$3" --pane "$4"); }

scen 'Every state the sidebar can show'
p1=$(idle_pane); register r1 claude st-machine "$p1"
emit "$r1" "$p1" claude PermissionRequest
check 'a permission request asks for attention' "$(live)" $'\tattention\t'
emit "$r1" "$p1" claude StopFailure
check 'a failed turn is reported' "$(live)" $'\tturn-failed\t'
emit "$r1" "$p1" claude UserPromptSubmit
check 'a submitted prompt is working' "$(live)" $'\tworking\t'
tmux set-option -g @agent-manager-stale-seconds 0
check 'work goes stale past the threshold' "$(live)" $'\tstale\t'
tmux set-option -gu @agent-manager-stale-seconds
emit "$r1" "$p1" claude Notification '{"session_id":"n1","notification_type":"permission_prompt"}'
check 'a permission notification asks for attention' "$(live)" $'\tattention\t'
emit "$r1" "$p1" claude Stop
check 'a finished turn is ready' "$(live)" $'\tready\t'

scen 'Codex, OpenCode and Antigravity adapters'
p2=$(idle_pane); register r2 codex cdx "$p2"
emit "$r2" "$p2" codex PreToolUse '{"thread_id":"t1"}'
check 'the Codex adapter reports work' "$(live)" $'\tworking\t'
if command -v node >/dev/null 2>&1; then
  p3=$(idle_pane); register r3 opencode oc "$p3"
  TMUX_AGENT_RUN_ID=$r3 TMUX_AGENT_PANE_ID=$p3 TMUX_AGENT_HARNESS=opencode \
    "$root/bin/tmux-agent" event attention permission.asked
  check 'an OpenCode permission asks for attention' "$(live)" 'oc'
fi

# The Antigravity adapter answers its hook first and reports afterwards, off the
# agent's critical path, so the state arrives a moment later than the call.
# Its own window: the test window has no room left to split.
ag_pane=$(tmux new-window -d -P -F '#{pane_id}' -t test 'sleep 300')
register ag_run antigravity agy "$ag_pane"
live_shows() { [[ $(live) == *"$1"* ]]; }
emit "$ag_run" "$ag_pane" antigravity PreInvocation '{"conversationId":"c1"}' >/dev/null
wait_for 5 live_shows $'\tworking\t'
check 'the Antigravity adapter reports work' "$(live)" $'\tworking\t'
emit "$ag_run" "$ag_pane" antigravity Stop '{"conversationId":"c1","terminationReason":"model_stop"}' >/dev/null
wait_for 5 live_shows $'\tready\t'
check 'a finished Antigravity turn is ready' "$(live)" $'\tready\t'
emit "$ag_run" "$ag_pane" antigravity Stop \
  '{"conversationId":"c1","terminationReason":"error","error":"boom"}' >/dev/null
wait_for 5 live_shows $'\tturn-failed\t'
check 'a failed Antigravity turn is reported' "$(live)" $'\tturn-failed\t'
check 'the conversation ID is remembered' \
  "$(jq -r '(.native_ids // [])|join(",")' "$(runtime_root)/runs/$ag_run/meta.json" 2>/dev/null)" 'c1'
# Stop ends a turn, not the process: the CLI is still sitting there.
check 'a stopped turn does not retire the run' "$(live)" 'agy'

scen 'How a run ends is what gets remembered'
start_run() { # start_run <label> <exit code>; prints run id and session name
  local label=$1 code=$2 id session harness
  harness=$(tam_fake_harness "harness-$code" "exit $code")
  id=$(new_uuid)
  session=$(agent_session_name "$label" "$id")
  TMUX_AGENT_NO_SWITCH=1 create_agent_session "$session" "$tmp/work" "$label" \
    "TMUX_AGENT_CLAUDE_COMMAND=$harness $(printf %q "$root/bin/tmux-agent") run --run $id --agent claude --label $label"
  printf '%s\t%s' "$id" "$session"
}
archived() { jq -r '.last_event.state' "$tmp/state/tmux-agent-manager/history/$1.json" 2>/dev/null; }

IFS=$'\t' read -r crash_run crash_session < <(start_run crashy 42)
wait_for 6 grep -q crashed "$(runtime_root)/runs/$crash_run/events.jsonl"
check 'a non-zero exit is a crash' \
  "$(jq -r '.state' <<<"$(latest_event "$(runtime_root)/runs/$crash_run/events.jsonl")")" 'crashed'
check 'a crashed run stays in the live list' "$(live)" 'crashy'
check 'a crashed pane is held open for its error' \
  "$(tmux has-session -t "=$crash_session" 2>/dev/null && echo alive)" 'alive'
tmux kill-session -t "=$crash_session" 2>/dev/null
"$root/bin/tmux-agent" reconcile
check 'a crash survives being archived' "$(archived "$crash_run")" 'crashed'

IFS=$'\t' read -r cancel_run cancel_session < <(start_run cancelly 130)
wait_for 6 test -f "$tmp/state/tmux-agent-manager/history/$cancel_run.json"
check 'an interrupted run is cancelled' "$(archived "$cancel_run")" 'cancelled'
tmux kill-session -t "=$cancel_session" 2>/dev/null

IFS=$'\t' read -r clean_run clean_session < <(start_run cleanly 0)
wait_for 6 test -f "$tmp/state/tmux-agent-manager/history/$clean_run.json"
check 'a clean exit is just an exit' "$(archived "$clean_run")" 'exited'
tmux kill-session -t "=$clean_session" 2>/dev/null

scen 'Rename, stop, and what they refuse to touch'
p4=$(idle_pane); register r4 claude oldname "$p4"
printf 'brand new name\n' | "$root/scripts/rename.sh" "$r4" >/dev/null
check 'a rename shows up in the list' "$(live)" 'brand new name'
check 'a rename pins the label' \
  "$(jq -r '.label_pinned' "$(runtime_root)/runs/$r4/meta.json")" 'true'
printf 'n\n' | "$root/scripts/stop.sh" "$r4" >/dev/null
check 'declining a stop keeps the run' "$(live)" 'brand new name'
check 'renaming an archived run does nothing at all' \
  "$("$root/scripts/rename.sh" "$crash_run" </dev/null 2>&1; echo "rc=$?")" 'rc=0'

scen 'Details and captured output'
check 'details name the run' "$("$root/scripts/preview.sh" "$r4" live 2>&1)" 'brand new name'
check 'details of an archived run say how it ended' \
  "$("$root/scripts/preview.sh" "$crash_run" history-only 2>&1)" 'crashed'
check 'pane output can be captured' \
  "$("$root/scripts/capture.sh" "$r4" 2>&1; echo "rc=$?")" 'rc=0'

scen 'Dependency check and the status line'
doctor=$("$root/scripts/doctor.sh" 2>&1; echo "rc=$?")
check 'doctor names the adapters it cannot find' "$doctor" 'miss'
check 'doctor fails while adapters are missing' "$doctor" 'rc=1'
check 'the status line counts the runs' "$("$root/bin/tmux-agent" status)" 'AI '

scen 'Window marks follow the most urgent run'
mark_pane=$(tmux new-window -d -P -F '#{pane_id}' -t test 'sleep 300')
register mark_run claude marky "$mark_pane"
mark_window=$(tmux display-message -p -t "$mark_pane" '#{window_id}')
emit "$mark_run" "$mark_pane" claude Stop
rebuild_cache
check 'a ready run marks its window' \
  "$(tmux show-option -wqv -t "$mark_window" @agent-manager-window-mark)" '◆'
before=$("$root/bin/tmux-agent" status | grep -o '[0-9]* unseen')
"$root/scripts/seen-current.sh" "$mark_pane" >/dev/null
after=$("$root/bin/tmux-agent" status | grep -o '[0-9]* unseen')
check 'looking at a run clears one unseen result' \
  "$((${before% unseen} - ${after% unseen}))" '1'
check 'a seen result reads as idle' "$(live | grep marky | cut -f9)" 'idle'

scen 'History is pruned to its limit'
tmux set-option -g @agent-manager-history-limit 2
for index in 1 2 3 4 5; do
  printf '{"run_id":"p%s","label":"p%s","harness":"claude","ended_at":%s,"last_event":{"state":"exited"}}' \
    "$index" "$index" "$((1000 + index))" >"$tmp/state/tmux-agent-manager/history/prune$index.json"
done
prune_history
check 'only the newest archives are kept' \
  "$(ls "$tmp/state/tmux-agent-manager/history" | wc -l)" '2'
tmux set-option -gu @agent-manager-history-limit

scen 'Reloading the plugin changes nothing twice'
tmux set-option -g @agent-manager-sidebar off
for _ in 1 2 3; do tmux run-shell "$root/tmux-agent-manager.tmux"; done
check 'the status line is added once' \
  "$(grep -o 'tmux-agent status' <<<"$(tmux show-option -gqv status-right)" | wc -l)" '1'
check 'the window mark is added once' \
  "$(grep -o 'window-mark' <<<"$(tmux show-option -gwqv window-status-format)" | wc -l)" '1'

tam_finish
