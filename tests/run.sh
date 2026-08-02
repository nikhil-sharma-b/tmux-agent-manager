#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-manager-tests.XXXXXX")
socket="agent-manager-test-$$"
cleanup() {
  tmux -L "$socket" kill-server 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  [[ $1 == *"$2"* ]] || fail "expected '$2' in '$1'"
}

mkdir -p "$tmp/work" "$tmp/runtime" "$tmp/state" "$tmp/home/.claude" \
  "$tmp/home/.codex" "$tmp/home/.config/opencode"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"existing"}]}]}}\n' \
  >"$tmp/home/.claude/settings.json"
printf '{"hooks":{}}\n' >"$tmp/home/.codex/hooks.json"

tmux -L "$socket" -f /dev/null new-session -d -s test -c "$tmp/work"
tmux -L "$socket" split-window -d -t test -c "$tmp/work"
server_pid=$(tmux -L "$socket" display-message -p '#{pid}')
pane=$(tmux -L "$socket" list-panes -t test -F '#{pane_id}' | sort | tail -n 1)
export TMUX="/tmp/tmux-$UID/$socket,$server_pid,0"
export TMUX_PANE=$pane
export XDG_RUNTIME_DIR="$tmp/runtime"
export XDG_STATE_HOME="$tmp/state"
export HOME="$tmp/home"

source "$root/scripts/lib.sh"
[[ $(truncate_text 'short label' 20) == 'short label' ]] || fail 'short label was truncated'
[[ $(truncate_text 'long agent session label' 12) == 'long agent…' ]] || fail 'long label ellipsis incorrect'
mkdir -p "$tmp/work/nested" "$tmp/home/project"
[[ $(resolve_directory nested "$tmp/work") == "$tmp/work/nested" ]] \
  || fail 'relative directory was not resolved from source cwd'
[[ $(resolve_directory '~/project' "$tmp/work") == "$tmp/home/project" ]] \
  || fail 'home directory was not expanded'
[[ -z $(resolve_directory missing "$tmp/work" || true) ]] \
  || fail 'missing directory was accepted'
mkdir -p "$tmp/commands" "$tmp/no-aliases"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '[[ $2 == "test (type -t cc) = function" || $2 == "test (type -t oc) = function" ]]' \
  >"$tmp/commands/fish"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$tmp/no-aliases/fish"
chmod +x "$tmp/commands/fish" "$tmp/no-aliases/fish"
[[ $(SHELL="$tmp/commands/fish" agent_alias claude) == cc ]] \
  || fail 'Claude alias not preferred'
[[ $(SHELL="$tmp/commands/fish" agent_alias opencode) == oc ]] \
  || fail 'OpenCode resume alias not preferred'
[[ -z $(SHELL="$tmp/no-aliases/fish" agent_alias claude || true) ]] \
  || fail 'Claude missing alias not ignored'
[[ -z $(SHELL="$tmp/no-aliases/fish" agent_alias opencode || true) ]] \
  || fail 'OpenCode missing alias not ignored'
[[ -z $(SHELL="$tmp/commands/fish" TMUX_AGENT_CLAUDE_COMMAND=/custom/claude \
  agent_alias claude || true) ]] || fail 'Claude configured command not preserved'
[[ -z $(SHELL="$tmp/commands/fish" TMUX_AGENT_OPENCODE_COMMAND=/custom/opencode \
  agent_alias opencode || true) ]] || fail 'OpenCode configured command not preserved'
if command -v fish >/dev/null 2>&1; then
  mkdir -p "$tmp/fish/functions"
  printf '%s\n' \
    'function claude' \
    '    printf "%s\n" $argv >$REAL_FISH_LOG' \
    'end' >"$tmp/fish/functions/claude.fish"
  printf '%s\n' \
    'function cc' \
    '    claude --dangerously-skip-permissions $argv' \
    'end' >"$tmp/fish/functions/cc.fish"
  [[ $(XDG_CONFIG_HOME="$tmp" SHELL="$(command -v fish)" agent_alias claude) == cc ]] \
    || fail 'real Fish Claude alias not detected'
  XDG_CONFIG_HOME="$tmp" REAL_FISH_LOG="$tmp/fish-args" \
    fish -ic 'cc --resume test-session'
  fish_args=$(<"$tmp/fish-args")
  assert_contains "$fish_args" '--dangerously-skip-permissions'
  assert_contains "$fish_args" '--resume'
fi
dedicated_run=$(new_uuid)
dedicated_session=$(agent_session_name 'Review API' "$dedicated_run")
TMUX_AGENT_NO_SWITCH=1 create_agent_session "$dedicated_session" "$tmp/work" 'Review API' 'sleep 60'
tmux has-session -t "=$dedicated_session" || fail 'dedicated agent session not created'
[[ $(tmux list-panes -t "=$dedicated_session" -F '#{pane_id}' | wc -l) == 1 ]] \
  || fail 'dedicated agent session should start with one pane'

# tmux exits 0 with empty output for a stale pane target, so registering against
# one must be rejected on the fields rather than on the exit status.
stale_run=$(new_uuid)
register_run "$(new_uuid)" "$stale_run" claude stale true '%99999' 2>/dev/null \
  && fail 'registration accepted a pane that does not exist'
[[ ! -e $(run_dir "$stale_run") ]] || fail 'rejected registration left a run directory'

registration=$("$root/bin/tmux-agent" register --harness claude --label 'fix auth' --pane "$pane")
IFS=$'\t' read -r thread run <<<"$registration"
[[ -n $thread && -n $run ]] || fail 'registration IDs absent'

export TMUX_AGENT_THREAD_ID=$thread
export TMUX_AGENT_RUN_ID=$run
export TMUX_AGENT_HARNESS=claude
export TMUX_AGENT_PANE_ID=$pane
printf '{"session_id":"native-1"}\n' | "$root/scripts/adapters/claude.sh" UserPromptSubmit
if command -v socat >/dev/null 2>&1; then
  printf '{"session_id":"socket-native"}\n' | TMUX_AGENT_BIN=/bin/true \
    socat - EXEC:"$root/scripts/adapters/claude.sh PreToolUse" \
    || fail 'Claude adapter could not read socket-backed stdin'
  printf '{"thread_id":"socket-native"}\n' | TMUX_AGENT_BIN=/bin/true \
    socat - EXEC:"$root/scripts/adapters/codex.sh PreToolUse" \
    || fail 'Codex adapter could not read socket-backed stdin'
fi

snapshot="$tmp/snapshot"
mkdir -p "$snapshot"
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" 'fix auth'
assert_contains "$list" 'working'

printf '{"session_id":"native-1"}\n' | "$root/scripts/adapters/claude.sh" Stop
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" $'\tready\t'
"$root/bin/tmux-agent" seen "$run"
status=$("$root/bin/tmux-agent" status)
[[ $status != *'1 unseen'* ]] || fail 'seen event remained unseen'
assert_contains "$status" 'AI 1'
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" 'idle'

# Reusing a pane must invalidate delayed events from its previous process.
run_paths=("$tmp/runtime"/tmux-agent-manager/*/runs/"$run")
events_file=${run_paths[0]}/events.jsonl
old_size=$(wc -c <"$events_file")
second_registration=$("$root/bin/tmux-agent" register --harness claude --label second --pane "$pane")
IFS=$'\t' read -r second_thread second_run <<<"$second_registration"
export TMUX_AGENT_RUN_ID=$run
printf '{"session_id":"native-1"}\n' | "$root/scripts/adapters/claude.sh" UserPromptSubmit
new_size=$(wc -c <"$events_file")
[[ $new_size == "$old_size" ]] || fail 'delayed event mutated superseded run'
"$root/bin/tmux-agent" reconcile
[[ -f "$tmp/state/tmux-agent-manager/history/$run.json" ]] || fail 'superseded run not archived'

export TMUX_AGENT_RUN_ID=$second_run
printf '' | "$root/scripts/adapters/claude.sh" Stop
tmux kill-pane -t "$pane"
"$root/bin/tmux-agent" reconcile
[[ -f "$tmp/state/tmux-agent-manager/history/$second_run.json" ]] || fail 'dead pane not archived'

# A harness started outside the plugin must leave the list when it exits,
# even though its pane survives.
tmux -L "$socket" split-window -d -t test -c "$tmp/work"
direct_pane=$(tmux -L "$socket" list-panes -t test -F '#{pane_id}' | sort | tail -n 1)
export TMUX_PANE=$direct_pane
export TMUX_AGENT_PANE_ID=$direct_pane
unset TMUX_AGENT_RUN_ID
printf '{"session_id":"direct-1"}\n' | "$root/scripts/adapters/claude.sh" SessionStart
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" "$direct_pane"
direct_run=$(tmux -L "$socket" display-message -p -t "$direct_pane" '#{@agent-manager-run}')
[[ -n $direct_run ]] || fail 'unmanaged run not registered on pane'
printf '{"session_id":"direct-1"}\n' | "$root/scripts/adapters/claude.sh" SessionEnd
list=$("$root/scripts/collect.sh" "$snapshot" live)
[[ $list != *"$direct_pane"* ]] || fail 'exited unmanaged run stayed in list'
[[ -f "$tmp/state/tmux-agent-manager/history/$direct_run.json" ]] \
  || fail 'exited unmanaged run not archived'
# A repeated terminal event for a gone run must stay harmless.
printf '{"session_id":"direct-1"}\n' | "$root/scripts/adapters/claude.sh" SessionEnd
list=$("$root/scripts/collect.sh" "$snapshot" live)
[[ $list != *"$direct_pane"* ]] || fail 'duplicate SessionEnd re-registered run'

# A harness that reported how it failed keeps that verdict through archiving;
# only a run that vanished without a word is recorded as a plain exit.
crash_pane=$(tmux split-window -d -P -F '#{pane_id}' -t test -c "$tmp/work" 'sleep 60')
crash_registration=$("$root/bin/tmux-agent" register --harness claude --label crashy --pane "$crash_pane")
IFS=$'\t' read -r _ crash_run <<<"$crash_registration"
append_event "$crash_run" crashed process-exit '' 'process exited with status 42'
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" $'\tcrashed\t'
tmux kill-pane -t "$crash_pane"
"$root/bin/tmux-agent" reconcile
[[ $(jq -r '.last_event.state' "$tmp/state/tmux-agent-manager/history/$crash_run.json") == crashed ]] \
  || fail 'archived crash was overwritten with a plain exit'
[[ $(jq -r '.last_event.message' "$tmp/state/tmux-agent-manager/history/$crash_run.json") \
  == 'process exited with status 42' ]] || fail 'archived crash lost its message'

# A dead harness is the most urgent thing in its window, so it must win the mark.
mark_window=$(tmux new-window -d -P -F '#{window_id}' -t test 'sleep 60')
mark_a=$(tmux list-panes -t "$mark_window" -F '#{pane_id}')
mark_b=$(tmux split-window -d -P -F '#{pane_id}' -t "$mark_a" 'sleep 60')
IFS=$'\t' read -r _ mark_run_a <<<"$("$root/bin/tmux-agent" register --harness claude --label boom --pane "$mark_a")"
IFS=$'\t' read -r _ mark_run_b <<<"$("$root/bin/tmux-agent" register --harness claude --label busy --pane "$mark_b")"
append_event "$mark_run_a" crashed process-exit '' 'died'
append_event "$mark_run_b" working tool-use '' ''
rebuild_cache
assert_contains "$(tmux show-option -wqv -t "$mark_window" @agent-manager-window-mark)" 'red'
tmux kill-window -t "$mark_window"

# A run that simply lost its pane still archives as exited.
quiet_pane=$(tmux split-window -d -P -F '#{pane_id}' -t test -c "$tmp/work" 'sleep 60')
quiet_registration=$("$root/bin/tmux-agent" register --harness claude --label quiet --pane "$quiet_pane")
IFS=$'\t' read -r _ quiet_run <<<"$quiet_registration"
tmux kill-pane -t "$quiet_pane"
"$root/bin/tmux-agent" reconcile
[[ $(jq -r '.last_event.state' "$tmp/state/tmux-agent-manager/history/$quiet_run.json") == exited ]] \
  || fail 'silently lost pane was not archived as exited'

CLAUDE_SETTINGS_FILE="$tmp/home/.claude/settings.json" \
CODEX_HOOKS_FILE="$tmp/home/.codex/hooks.json" \
OPENCODE_PLUGIN_DIR="$tmp/home/.config/opencode/plugin" \
  "$root/bin/tmux-agent" setup --apply >/dev/null
jq -e '.hooks.SessionStart | length == 2' "$tmp/home/.claude/settings.json" >/dev/null \
  || fail 'Claude setup replaced existing hook'
jq -e '.hooks.StopFailure | length == 1' "$tmp/home/.claude/settings.json" >/dev/null \
  || fail 'Claude StopFailure hook absent'
OPENCODE_PLUGIN_DIR="$tmp/home/.config/opencode/plugin" \
  "$root/bin/tmux-agent" setup --apply >/dev/null
jq -e '.hooks.SessionStart | length == 2' "$tmp/home/.claude/settings.json" >/dev/null \
  || fail 'setup was not idempotent'
[[ -L "$tmp/home/.config/opencode/plugin/tmux-agent-manager.js" ]] \
  || fail 'OpenCode adapter symlink absent'

native="$tmp/native"
mkdir -p "$native/claude/projects/project" "$native/cache"
printf '{"sessionId":"claude-native","project":"%s","timestamp":3000}\n' "$tmp/work" \
  >"$native/claude/history.jsonl"
printf '{"type":"ai-title","sessionId":"claude-native","aiTitle":"Claude saved"}\n' \
  >"$native/claude/projects/project/claude-native.jsonl"
sqlite3 "$native/codex.db" "
  CREATE TABLE threads (
    id TEXT, name TEXT, title TEXT, cwd TEXT, source TEXT,
    recency_at_ms INTEGER, updated_at_ms INTEGER, updated_at INTEGER, archived INTEGER
  );
  INSERT INTO threads VALUES ('codex-native', 'Codex saved', '', '/tmp/codex', 'cli', 2000, 2000, 2, 0);
"
sqlite3 "$native/opencode.db" "
  CREATE TABLE session (
    id TEXT, title TEXT, directory TEXT, time_updated INTEGER,
    parent_id TEXT, time_archived INTEGER
  );
  INSERT INTO session VALUES ('opencode-native', 'OpenCode saved', '/tmp/opencode', 1000, NULL, NULL);
"
CLAUDE_PROJECTS_DIR="$native/claude/projects" \
CLAUDE_HISTORY_FILE="$native/claude/history.jsonl" \
CODEX_DB="$native/codex.db" \
OPENCODE_DB="$native/opencode.db" \
XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/native-sessions.sh" refresh
native_catalog=$(<"$native/cache/tmux-agent-manager/native-sessions.tsv")
assert_contains "$native_catalog" 'Claude saved'
assert_contains "$native_catalog" 'Codex saved'
assert_contains "$native_catalog" 'OpenCode saved'

mkdir -p "$native/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [[ $2 == test* ]]; then exit 0; fi' \
  'printf "%s\n" "$2" >"$NATIVE_RESUME_LOG"' \
  'if [[ $2 == *--resume* || $2 == *--session* ]]; then sleep 60; fi' >"$native/bin/fish"
chmod +x "$native/bin/fish"
TMUX_AGENT_SHELL="$native/bin/fish" NATIVE_RESUME_LOG="$native/new.log" \
  "$root/scripts/run.sh" --thread "$(new_uuid)" --run "$(new_uuid)" \
  --agent claude --label new
assert_contains "$(<"$native/new.log")" 'cc'
tmux set-environment -g PATH "$native/bin:$PATH"
tmux set-environment -g TMUX_AGENT_SHELL "$native/bin/fish"
tmux set-environment -g NATIVE_RESUME_LOG "$native/resume.log"
TMUX_AGENT_NO_SWITCH=1 "$root/scripts/open.sh" \
  claude-native native:claude "$tmp/work" 3000 - 0 'Claude saved'
for _ in {1..30}; do
  [[ -f $native/resume.log ]] && break
  sleep 0.1
done
if [[ ! -f $native/resume.log ]]; then
  native_debug=$(tmux list-panes -a -F '#{session_name}:#{window_name}.#{pane_index} #{pane_dead} #{pane_current_command}')
  resume_debug_session=$(tmux list-sessions -F '#{session_name}' | awk '/^ai-Claude-saved-/ { print; exit }')
  resume_debug=$(tmux capture-pane -p -t "=$resume_debug_session:agent" 2>/dev/null || true)
  fail "native Claude resume command did not start: $native_debug / $resume_debug"
fi
assert_contains "$(<"$native/resume.log")" 'cc'
assert_contains "$(<"$native/resume.log")" 'claude-native'
resume_session=$(tmux list-sessions -F '#{session_name}' | awk '/^ai-Claude-saved-/ { print; exit }')
[[ -n $resume_session ]] || fail 'native resume did not create dedicated session'
tmux kill-session -t "=$resume_session"

rm -f "$native/resume.log"
TMUX_AGENT_NO_SWITCH=1 "$root/scripts/open.sh" \
  opencode-native native:opencode "$tmp/work" 1000 - 0 'OpenCode saved'
for _ in {1..30}; do
  [[ -f $native/resume.log ]] && break
  sleep 0.1
done
[[ -f $native/resume.log ]] || fail 'native OpenCode resume alias did not start'
assert_contains "$(<"$native/resume.log")" 'oc'
assert_contains "$(<"$native/resume.log")" 'opencode-native'
resume_session=$(tmux list-sessions -F '#{session_name}' | awk '/^ai-OpenCode-saved-/ { print; exit }')
[[ -n $resume_session ]] || fail 'native OpenCode resume did not create dedicated session'
tmux kill-session -t "=$resume_session"
"$root/bin/tmux-agent" reconcile

# A merged pull request retires its run without waiting for the pane to die.
merge_repo="$tmp/merge-repo"
mkdir -p "$merge_repo" "$native/bin"
git -C "$merge_repo" init -q -b main
git -C "$merge_repo" -c user.email=test@example.com -c user.name=test \
  commit -q --allow-empty -m init
git -C "$merge_repo" checkout -q -b feat/merged
merge_pane=$(tmux split-window -d -P -F '#{pane_id}' -t test -c "$merge_repo" 'sleep 60')
merge_registration=$("$root/bin/tmux-agent" register --harness claude --label merged-work --pane "$merge_pane")
IFS=$'\t' read -r _ merge_run <<<"$merge_registration"
list=$("$root/scripts/collect.sh" "$snapshot" live)
assert_contains "$list" 'merged-work'
printf '%s\n' '#!/usr/bin/env bash' 'printf "OPEN\n"' >"$native/bin/gh"
chmod +x "$native/bin/gh"
PATH="$native/bin:$PATH" "$root/bin/tmux-agent" check-merges
merge_paths=("$tmp/runtime"/tmux-agent-manager/*/runs/"$merge_run")
[[ -f ${merge_paths[0]}/meta.json ]] || fail 'open pull request archived its run'
printf '%s\n' '#!/usr/bin/env bash' 'printf "MERGED\n"' >"$native/bin/gh"
PATH="$native/bin:$PATH" "$root/bin/tmux-agent" check-merges
[[ -f "$tmp/state/tmux-agent-manager/history/$merge_run.json" ]] \
  || fail 'merged pull request did not archive its run'
[[ $(jq -r '.last_event.state' "$tmp/state/tmux-agent-manager/history/$merge_run.json") == merged ]] \
  || fail 'archived merge run lost its merged state'
list=$("$root/scripts/collect.sh" "$snapshot" live)
[[ $list != *'merged-work'* ]] || fail 'merged run stayed in the live list'
[[ -z $(tmux display-message -p -t "$merge_pane" '#{@agent-manager-run}') ]] \
  || fail 'merged run left its pane registered'
tmux display-message -p -t "$merge_pane" '#{pane_id}' >/dev/null \
  || fail 'merged run killed a session it did not own'
tmux kill-pane -t "$merge_pane"

# A managed run owns its ai-* session, so the merge closes the whole session.
merge_run_id=$(new_uuid)
merge_session=$(agent_session_name 'merged thread' "$merge_run_id")
TMUX_AGENT_NO_SWITCH=1 create_agent_session "$merge_session" "$merge_repo" 'merged thread' 'sleep 60'
merge_session_pane=$(tmux list-panes -t "=$merge_session" -F '#{pane_id}')
register_run "$(new_uuid)" "$merge_run_id" claude 'merged thread' true "$merge_session_pane"
PATH="$native/bin:$PATH" "$root/bin/tmux-agent" check-merges
[[ -f "$tmp/state/tmux-agent-manager/history/$merge_run_id.json" ]] \
  || fail 'managed merged run not archived'
if tmux has-session -t "=$merge_session" 2>/dev/null; then
  fail 'merged run left its session alive'
fi

# Killing sessions must stay switchable.
merge_kept_id=$(new_uuid)
merge_kept_session=$(agent_session_name 'kept thread' "$merge_kept_id")
TMUX_AGENT_NO_SWITCH=1 create_agent_session "$merge_kept_session" "$merge_repo" 'kept thread' 'sleep 60'
merge_kept_pane=$(tmux list-panes -t "=$merge_kept_session" -F '#{pane_id}')
register_run "$(new_uuid)" "$merge_kept_id" claude 'kept thread' true "$merge_kept_pane"
tmux set-option -g @agent-manager-merge-kill-session off
PATH="$native/bin:$PATH" "$root/bin/tmux-agent" check-merges
tmux set-option -gu @agent-manager-merge-kill-session
tmux has-session -t "=$merge_kept_session" 2>/dev/null \
  || fail 'merge kill option was not honoured'
tmux kill-session -t "=$merge_kept_session"

nav_a=$(tmux list-panes -t test -F '#{pane_id}' | sort | tail -n 1)
nav_b=$(tmux split-window -d -P -F '#{pane_id}' -t "$nav_a" 'sleep 60')
nav_a_registration=$("$root/bin/tmux-agent" register --harness claude --label nav-a --pane "$nav_a")
IFS=$'\t' read -r _ nav_a_run <<<"$nav_a_registration"
nav_b_registration=$("$root/bin/tmux-agent" register --harness claude --label nav-b --pane "$nav_b")
IFS=$'\t' read -r _ nav_b_run <<<"$nav_b_registration"
finder_snapshot="$tmp/finder"
mkdir -p "$finder_snapshot"
finder_live=$("$root/scripts/finder-collect.sh" "$finder_snapshot" live)
assert_contains "$finder_live" 'nav-a'
# Ended runs and the harnesses' own conversations share one saved scope, so the
# old history and sessions names must land there too.
saved_rows=$(XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot" saved)
assert_contains "$saved_rows" 'Claude saved'
assert_contains "$saved_rows" 'OpenCode saved'
assert_contains "$saved_rows" 'fix auth'
[[ $(<"$finder_snapshot/mode") == saved ]] || fail 'saved scope was not persisted'
XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot" history >/dev/null
[[ $(<"$finder_snapshot/mode") == saved ]] || fail 'the history scope did not map to saved'
XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot" sessions >/dev/null
[[ $(<"$finder_snapshot/mode") == saved ]] || fail 'the sessions scope did not map to saved'
saved_rows=$(XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot")
[[ $(awk -F '\t' '{print NF}' <<<"$saved_rows" | sort -u) == 11 ]] \
  || fail 'saved rows broke the eleven-field row contract'
# How a run ended survives into the merged list, and the newest work leads.
assert_contains "$saved_rows" $'\tcrashed\t'
newest=$(jq -r '.ended_at' "$tmp/state/tmux-agent-manager/history"/*.json | sort -rn | head -n 1)
[[ $(head -n 1 <<<"$saved_rows" | cut -f4) -ge $newest ]] \
  || fail 'saved list is not ordered newest first'
# A run whose conversation the harness never recorded still opens.
assert_contains "$saved_rows" 'history-only'
orphan_row=$(grep -m1 $'\thistory-only\t' <<<"$saved_rows")
[[ -n $(cut -f3 <<<"$orphan_row") ]] || fail 'a non-resumable row lost its directory'
[[ -z $("$root/scripts/collect.sh" "$snapshot" history) ]] \
  || fail 'collect.sh still builds a separate history list'
tmux set-environment -g XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"
tmux set-environment -g XDG_STATE_HOME "$XDG_STATE_HOME"
tmux set-environment -g XDG_CACHE_HOME "$native/cache"
tmux set-environment -g HOME "$HOME"

tmux run-shell "$root/tmux-agent-manager.tmux"
tmux run-shell "$root/tmux-agent-manager.tmux"
hook_count=$(tmux show-hooks -g after-select-pane | awk '/seen-current/ { count++ } END { print count + 0 }')
[[ $hook_count == 1 ]] || fail 'plugin reload duplicated hooks'
follow_hook_count=$(tmux show-hooks -g after-select-pane | awk '/sidebar-follow/ { count++ } END { print count + 0 }')
[[ $follow_hook_count == 1 ]] || fail 'plugin reload duplicated sidebar hook'

sidebar=''
for _ in 1 2 3 4 5; do
  sidebar=$(tmux show-option -gqv @agent-manager-sidebar-pane)
  [[ -n $sidebar ]] && break
  sleep 0.1
done
[[ $sidebar =~ ^%[0-9]+$ ]] || fail 'sidebar was not created'
tmux display-message -p -t "$sidebar" '#{pane_id}' >/dev/null || fail 'sidebar pane absent'

for _ in 1 2 3 4 5; do
  selected_run=$(tmux show-option -pqv -t "$sidebar" @agent-manager-sidebar-selected)
  [[ $selected_run == "$nav_a_run" ]] && break
  sleep 0.5
done
[[ $selected_run == "$nav_a_run" ]] || fail 'sidebar initial selection incorrect'
navigation_started=$(date +%s%3N)
tmux send-keys -t "$sidebar" j
for _ in {1..50}; do
  selected_run=$(tmux show-option -pqv -t "$sidebar" @agent-manager-sidebar-selected)
  [[ $selected_run == "$nav_b_run" ]] && break
  sleep 0.01
done
navigation_elapsed=$(($(date +%s%3N) - navigation_started))
[[ $selected_run == "$nav_b_run" ]] || fail 'sidebar j navigation failed'
[[ $navigation_elapsed -lt 500 ]] || fail "sidebar navigation took ${navigation_elapsed}ms"
tmux send-keys -t "$sidebar" k
for _ in {1..50}; do
  selected_run=$(tmux show-option -pqv -t "$sidebar" @agent-manager-sidebar-selected)
  [[ $selected_run == "$nav_a_run" ]] && break
  sleep 0.01
done
[[ $selected_run == "$nav_a_run" ]] || fail 'sidebar k navigation failed'
tmux display-message -p -t "$sidebar" '#{pane_id}' >/dev/null || fail 'sidebar exited during navigation'
assert_contains "$(<"$root/scripts/sidebar.sh")" 'r) prompt_for_selected rename; break ;;'
assert_contains "$(<"$root/scripts/sidebar.sh")" 'x) prompt_for_selected stop; break ;;'
assert_contains "$(<"$root/scripts/sidebar.sh")" 'R) force_redraw=1; break ;;'
sidebar_source=$(<"$root/scripts/sidebar.sh")
[[ $sidebar_source != *'\033[2J'* ]] || fail 'sidebar redraw clears pane before rendering'
assert_contains "$sidebar_source" "frame=\$(render_frame)"

target=$(tmux new-window -d -P -F '#{pane_id}' -t test -n other 'sleep 60')
"$root/scripts/sidebar-follow.sh" "$target" ''
sidebar_window=$(tmux display-message -p -t "$sidebar" '#{window_id}')
target_window=$(tmux display-message -p -t "$target" '#{window_id}')
[[ $sidebar_window == "$target_window" ]] || fail 'sidebar did not follow target window'

binding=$(tmux list-keys -T prefix | awk '$4 == "A"')
assert_contains "$binding" 'sidebar-toggle.sh toggle'
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
[[ $(tmux show-option -gqv @agent-manager-sidebar-hidden) == 1 ]] || fail 'sidebar hide state absent'
[[ -z $(tmux show-option -gqv @agent-manager-sidebar-pane) ]] || fail 'sidebar pane option remained after hide'

# tmux may return success with empty output for a stale pane target.
tmux set-option -g @agent-manager-sidebar-pane '%99999'
"$root/scripts/sidebar-toggle.sh" focus "$target" ''
replacement=$(tmux show-option -gqv @agent-manager-sidebar-pane)
[[ $replacement =~ ^%[0-9]+$ && $replacement != %99999 ]] || fail 'stale sidebar was not recreated'
tmux display-message -p -t "$replacement" '#{pane_id}' >/dev/null || fail 'replacement sidebar absent'
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
[[ $(tmux show-option -gqv @agent-manager-sidebar-hidden) == 1 ]] || fail 'sidebar toggle did not hide'
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
replacement=$(tmux show-option -gqv @agent-manager-sidebar-pane)
[[ $replacement =~ ^%[0-9]+$ ]] || fail 'sidebar toggle did not reopen'
tmux display-message -p -t "$replacement" '#{pane_id}' >/dev/null || fail 'reopened sidebar absent'
tmux send-keys -t "$replacement" s
for _ in {1..50}; do
  mode=$(tmux show-option -gqv @agent-manager-sidebar-mode)
  [[ $mode == saved ]] && break
  sleep 0.01
done
[[ $mode == saved ]] || fail 'sidebar did not persist saved mode'
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
replacement=$(tmux show-option -gqv @agent-manager-sidebar-pane)
for _ in {1..50}; do
  mode=$(tmux show-option -pqv -t "$replacement" @agent-manager-sidebar-mode)
  [[ $mode == saved ]] && break
  sleep 0.01
done
[[ $mode == saved ]] || fail 'sidebar did not restore the saved mode'
# A prompt appended to the drawn frame wraps through the footer and scrolls the
# header away, so rename and stop must own the screen while they ask.
tmux send-keys -t "$replacement" s
for _ in {1..50}; do
  mode=$(tmux show-option -gqv @agent-manager-sidebar-mode)
  [[ $mode == live ]] && break
  sleep 0.01
done
tmux send-keys -t "$replacement" r
prompt_screen=''
for _ in {1..100}; do
  prompt_screen=$(tmux capture-pane -p -t "$replacement" 2>/dev/null || true)
  [[ $prompt_screen == *rename* ]] && break
  sleep 0.02
done
assert_contains "$prompt_screen" 'rename'
[[ $prompt_screen != *'open · n new'* ]] || fail 'rename prompt drew over the sidebar footer'
[[ $prompt_screen != *'AI agents'* ]] || fail 'rename prompt left the sidebar frame on screen'
tmux send-keys -t "$replacement" Enter
for _ in {1..100}; do
  sidebar_screen=$(tmux capture-pane -p -t "$replacement" 2>/dev/null || true)
  [[ $sidebar_screen == *'AI agents'* ]] && break
  sleep 0.02
done
assert_contains "$sidebar_screen" 'AI agents'
tmux send-keys -t "$replacement" /
for _ in {1..100}; do
  finder_screen=$(tmux capture-pane -p -t "$replacement" 2>/dev/null || true)
  [[ $finder_screen == *'›'* ]] && break
  sleep 0.02
done
[[ $finder_screen == *'›'* ]] || fail 'sidebar fuzzy search did not open in place'
tmux send-keys -t "$replacement" Escape
for _ in {1..50}; do
  sidebar_screen=$(tmux capture-pane -p -t "$replacement" 2>/dev/null || true)
  [[ $sidebar_screen == *'AI agents'* ]] && break
  sleep 0.01
done
tmux display-message -p -t "$replacement" '#{pane_id}' >/dev/null 2>&1 \
  || fail 'cancelled fuzzy search closed sidebar'
"$root/scripts/sidebar-toggle.sh" hide "$target" ''

for file in "$root/bin/tmux-agent" "$root"/scripts/*.sh "$root"/scripts/adapters/*.sh \
  "$root/tmux-agent-manager.tmux"; do
  bash -n "$file"
done
# The adapter is an ES module loaded by OpenCode, but `node --check` treats a
# bare .js file as CommonJS. A .mjs copy gets it parsed as the module it is.
cp "$root/scripts/adapters/opencode.js" "$tmp/opencode-adapter.mjs"
node --check "$tmp/opencode-adapter.mjs"

printf 'PASS\n'
