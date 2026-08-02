#!/usr/bin/env bash
# Drives the real interactive surfaces the way a person does: keys go in with
# send-keys, and what the pane actually renders is what gets asserted.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
tam_start interactive -x 200 -y 50

mkdir -p "$tmp/work/subdir"
# The agent has to stay up for the session to be worth inspecting.
tmux set-environment -g TMUX_AGENT_CLAUDE_COMMAND \
  "$(tam_fake_harness claude 'sleep 300')"

wizard() { # wizard [trailing shell]; prints the pane running it
  tmux new-window -d -P -F '#{pane_id}' -t test -c "$tmp/work" \
    "TMUX_AGENT_SOURCE_PANE=$pane $root/scripts/new.sh${1:-}"
}
showing() { [[ $(screen "$1") == *"$2"* ]]; }

scen 'Creating an agent in the current directory'
wiz=$(wizard)
wait_for 5 showing "$wiz" 'step 1 of 2'
check 'it opens on the agent step' "$(screen "$wiz")" 'step 1 of 2'
check 'every harness is offered' "$(screen "$wiz")" 'opencode'
tmux send-keys -t "$wiz" Enter
wait_for 5 showing "$wiz" 'step 2 of 2'
check 'there is no label step' "$(screen "$wiz")" 'step 2 of 2'
check 'the workspace step comes second' "$(screen "$wiz")" 'new worktree'
check 'a directory can be browsed' "$(screen "$wiz")" 'browse with yazi'
tmux send-keys -t "$wiz" Enter
wait_for 8 bash -c "tmux list-sessions -F '#{session_name}' | grep -q '^ai-work-'"
check 'the run is named after its workspace' "$(sessions)" 'ai-work-'
created=$(sessions | grep '^ai-work-' | head -n 1)
check 'the agent gets the session to itself' \
  "$(tmux list-panes -t "=$created" -F '#{pane_id}' | wc -l)" '1'
check 'it starts in the chosen directory' \
  "$(tmux list-panes -t "=$created" -F '#{pane_current_path}')" "$tmp/work"

scen 'Typing a directory path'
wiz=$(wizard)
wait_for 5 showing "$wiz" 'step 1 of 2'
tmux send-keys -t "$wiz" Enter
wait_for 5 showing "$wiz" 'step 2 of 2'
tmux send-keys -t "$wiz" Down Enter
wait_for 5 showing "$wiz" 'relative to'
check 'the prompt says what the path is relative to' "$(screen "$wiz")" 'relative to'
tmux send-keys -t "$wiz" 'nope-not-here' Enter
wait_for 3 showing "$wiz" 'not a directory'
check 'a bad path is refused' "$(screen "$wiz")" 'not a directory'
sleep 1.5
check 'the refusal survives the redraw' "$(screen "$wiz")" 'not a directory'
tmux send-keys -t "$wiz" 'subdir' Enter
wait_for 8 bash -c "tmux list-sessions -F '#{session_name}' | grep -q '^ai-subdir-'"
typed=$(sessions | grep '^ai-subdir-' | head -n 1)
check 'a relative path resolves against the source pane' \
  "$(tmux list-panes -t "=$typed" -F '#{pane_current_path}')" "$tmp/work/subdir"

scen 'Backing out of the wizard'
before=$(sessions | grep -c '^ai-')
wiz=$(wizard '; echo WIZARD_DONE; sleep 30')
wait_for 5 showing "$wiz" 'step 1 of 2'
tmux send-keys -t "$wiz" Escape
wait_for 5 showing "$wiz" 'WIZARD_DONE'
check 'escape leaves cleanly' "$(screen "$wiz")" 'WIZARD_DONE'
check 'escape starts nothing' "$(sessions | grep -c '^ai-')" "$before"

scen 'Sidebar keys'
tmux run-shell "$root/tmux-agent-manager.tmux"
wait_for 5 bash -c '[[ -n $(tmux show-option -gqv @agent-manager-sidebar-pane) ]]'
sb=$(tmux show-option -gqv @agent-manager-sidebar-pane)
wait_for 5 showing "$sb" 'AI agents'
check 'the sidebar draws its header' "$(screen "$sb")" 'AI agents'
check 'the footer keeps the main keys visible' "$(screen "$sb")" 'n new'
check 'the scope tabs are live and saved' "$(screen "$sb")" 'saved'
if [[ $(screen "$sb") == *history* ]]; then
  bad 'the history tab is still drawn'
else
  ok 'there is no separate history tab'
fi
tmux send-keys -t "$sb" '?'; wait_for 3 showing "$sb" 'hide sidebar'
check 'the key help opens' "$(screen "$sb")" 'hide sidebar'
check 'the help lists stopping a run' "$(screen "$sb")" 'stop agent'
tmux send-keys -t "$sb" q; wait_for 3 showing "$sb" 'AI agents'
check 'any key closes the help' "$(screen "$sb")" 'AI agents'
for key in h s; do
  tmux send-keys -t "$sb" "$key"
  wait_for 3 bash -c '[[ $(tmux show-option -gqv @agent-manager-sidebar-mode) == saved ]]'
  check "$key switches to saved" "$(tmux show-option -gqv @agent-manager-sidebar-mode)" 'saved'
  tmux send-keys -t "$sb" "$key"
  wait_for 3 bash -c '[[ $(tmux show-option -gqv @agent-manager-sidebar-mode) == live ]]'
  check "$key switches back to live" "$(tmux show-option -gqv @agent-manager-sidebar-mode)" 'live'
done
tmux send-keys -t "$sb" q
wait_for 3 bash -c '[[ $(tmux show-option -gqv @agent-manager-sidebar-hidden) == 1 ]]'
check 'q hides the sidebar' "$(tmux show-option -gqv @agent-manager-sidebar-hidden)" '1'

scen 'Renaming from the sidebar'
tmux run-shell "$root/scripts/sidebar-toggle.sh show $pane ''"
wait_for 5 bash -c '[[ -n $(tmux show-option -gqv @agent-manager-sidebar-pane) ]]'
sb=$(tmux show-option -gqv @agent-manager-sidebar-pane)
wait_for 5 showing "$sb" 'work'
check 'the created agent is listed' "$(screen "$sb")" 'work'
tmux send-keys -t "$sb" r
wait_for 3 showing "$sb" 'rename'
prompt=$(screen "$sb")
check 'r asks for the new name' "$prompt" 'rename'
# A prompt drawn onto the frame wraps through the footer and scrolls the
# header away, so it has to own the screen while it asks.
if [[ $prompt == *'open · n new'* || $prompt == *'AI agents'* ]]; then
  bad 'the rename prompt drew over the sidebar frame'
else
  ok 'the rename prompt owns the screen'
fi
tmux send-keys -t "$sb" 'renamed here' Enter
wait_for 5 showing "$sb" 'renamed'
check 'the new name appears in the list' "$(screen "$sb")" 'renamed'

scen 'Searching and stopping from the sidebar'
tmux send-keys -t "$sb" /
wait_for 5 showing "$sb" '›'
check 'search opens in the sidebar pane' "$(screen "$sb")" '›'
tmux send-keys -t "$sb" Escape
wait_for 5 showing "$sb" 'AI agents'
check 'cancelling search returns the sidebar' "$(screen "$sb")" 'AI agents'
# The sidebar redraws before the search process has finished letting go of the
# terminal, and a keystroke sent into that gap goes to the wrong reader.
sleep 0.5
tmux send-keys -t "$sb" x
wait_for 3 showing "$sb" 'stop'
stop_prompt=$(screen "$sb")
check 'x asks before stopping' "$stop_prompt" 'stop'
if [[ $stop_prompt == *'open · n new'* ]]; then
  bad 'the stop prompt drew over the sidebar footer'
else
  ok 'the stop prompt owns the screen'
fi
tmux send-keys -t "$sb" Enter
wait_for 5 showing "$sb" 'AI agents'
check 'declining a stop returns the sidebar' "$(screen "$sb")" 'AI agents'

tam_finish
