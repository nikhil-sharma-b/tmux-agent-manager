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
mkdir -p "$tmp/commands" "$tmp/no-aliases"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$tmp/commands/fish"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$tmp/no-aliases/fish"
chmod +x "$tmp/commands/fish" "$tmp/no-aliases/fish"
[[ $(SHELL="$tmp/commands/fish" resume_agent_alias claude) == cc ]] \
  || fail 'Claude resume alias not preferred'
[[ $(SHELL="$tmp/commands/fish" resume_agent_alias opencode) == oc ]] \
  || fail 'OpenCode resume alias not preferred'
[[ -z $(SHELL="$tmp/no-aliases/fish" resume_agent_alias claude || true) ]] \
  || fail 'Claude missing alias not ignored'
[[ -z $(SHELL="$tmp/no-aliases/fish" resume_agent_alias opencode || true) ]] \
  || fail 'OpenCode missing alias not ignored'
[[ -z $(SHELL="$tmp/commands/fish" TMUX_AGENT_CLAUDE_COMMAND=/custom/claude \
  resume_agent_alias claude || true) ]] || fail 'Claude configured command not preserved'
[[ -z $(SHELL="$tmp/commands/fish" TMUX_AGENT_OPENCODE_COMMAND=/custom/opencode \
  resume_agent_alias opencode || true) ]] || fail 'OpenCode configured command not preserved'
dedicated_run=$(new_uuid)
dedicated_session=$(agent_session_name 'Review API' "$dedicated_run")
TMUX_AGENT_NO_SWITCH=1 create_agent_session "$dedicated_session" "$tmp/work" 'Review API' 'sleep 60'
tmux has-session -t "=$dedicated_session" || fail 'dedicated agent session not created'
[[ $(tmux list-panes -t "=$dedicated_session" -F '#{pane_id}' | wc -l) == 1 ]] \
  || fail 'dedicated agent session should start with one pane'

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
  'sleep 60' >"$native/bin/fish"
chmod +x "$native/bin/fish"
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
finder_history=$("$root/scripts/finder-collect.sh" "$finder_snapshot" history)
assert_contains "$finder_history" 'fix auth'
finder_saved=$(XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot" sessions)
assert_contains "$finder_saved" 'Claude saved'
finder_saved=$(XDG_CACHE_HOME="$native/cache" \
  "$root/scripts/finder-collect.sh" "$finder_snapshot")
assert_contains "$finder_saved" 'OpenCode saved'
[[ $(<"$finder_snapshot/mode") == sessions ]] || fail 'finder refresh lost current scope'
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

target=$(tmux new-window -d -P -F '#{pane_id}' -t test -n other 'sleep 60')
"$root/scripts/sidebar-follow.sh" "$target" ''
sidebar_window=$(tmux display-message -p -t "$sidebar" '#{window_id}')
target_window=$(tmux display-message -p -t "$target" '#{window_id}')
[[ $sidebar_window == "$target_window" ]] || fail 'sidebar did not follow target window'

binding=$(tmux list-keys -T prefix A)
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
  [[ $mode == sessions ]] && break
  sleep 0.01
done
[[ $mode == sessions ]] || fail 'sidebar did not persist sessions mode'
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
"$root/scripts/sidebar-toggle.sh" toggle "$target" ''
replacement=$(tmux show-option -gqv @agent-manager-sidebar-pane)
for _ in {1..50}; do
  mode=$(tmux show-option -pqv -t "$replacement" @agent-manager-sidebar-mode)
  [[ $mode == sessions ]] && break
  sleep 0.01
done
[[ $mode == sessions ]] || fail 'sidebar did not restore sessions mode'
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
