#!/usr/bin/env bash

set -euo pipefail

plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

agent_option() {
  local option=$1 fallback=$2 value=''
  if command -v tmux >/dev/null 2>&1; then
    value=$(tmux show-option -gqv "$option" 2>/dev/null || true)
  fi
  printf '%s' "${value:-$fallback}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'tmux-agent-manager requires %s.\n' "$1" >&2
    exit 1
  }
}

agent_alias() {
  local harness=$1 configured alias shell=${TMUX_AGENT_SHELL:-${SHELL:-}} check
  case $harness in
    claude)
      configured=${TMUX_AGENT_CLAUDE_COMMAND:-}
      alias=cc
      ;;
    opencode)
      configured=${TMUX_AGENT_OPENCODE_COMMAND:-}
      alias=oc
      ;;
    *) return 1 ;;
  esac

  [[ -z $configured && -x $shell ]] || return 1
  case ${shell##*/} in
    fish) check="test \"(type -t $alias)\" = function" ;;
    bash) check="kind=\$(type -t $alias); [[ \$kind == alias || \$kind == function ]]" ;;
    zsh) check="kind=\$(whence -w $alias); [[ \$kind == *': alias' || \$kind == *': function' ]]" ;;
    *) return 1 ;;
  esac
  "$shell" -ic "$check" </dev/null >/dev/null 2>&1 || return 1
  printf '%s' "$alias"
}

new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    IFS= read -r uuid </proc/sys/kernel/random/uuid
    printf '%s' "$uuid"
  else
    printf '%s-%s-%s' "$(date +%s)" "$$" "$RANDOM"
  fi
}

clean_text() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | tr -d '\000-\010\013\014\016-\037\177'
}

truncate_text() {
  local text=$1 width=$2
  if ((${#text} <= width)); then
    printf '%s' "$text"
  elif ((width > 1)); then
    local cut=${text:0:width-1}
    printf '%s…' "${cut%"${cut##*[! ]}"}"
  else
    printf '%s' "${text:0:width}"
  fi
}

valid_id() {
  [[ $1 =~ ^[[:alnum:]_-]+$ ]]
}

pane_exists() {
  [[ $1 =~ ^%[0-9]+$ ]] || return 1
  [[ $(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null || true) == "$1" ]]
}

shell_quote() {
  jq -rn --arg value "$1" '$value|@sh'
}

expand_home() {
  case $1 in
    '~') printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_directory() {
  local path base
  path=$(expand_home "$1")
  base=$2
  [[ -n $path ]] || return 1
  [[ $path == /* ]] || path="$base/$path"
  (cd -P -- "$path" 2>/dev/null && pwd -P)
}

agent_session_name() {
  local label=$1 run=$2 name
  name=$(printf '%s' "$label" | tr ' /.:@' '------' | tr -cd '[:alnum:]_-')
  name=${name:-thread}
  printf 'ai-%s-%s' "${name:0:32}" "${run:0:8}"
}

switch_to_agent_session() {
  local session=$1 client=${TMUX_AGENT_CLIENT:-}
  if [[ -n $client ]]; then
    tmux switch-client -c "$client" -t "=$session"
  else
    tmux switch-client -t "=$session"
  fi
}

create_agent_session() {
  local session=$1 cwd=$2 label=$3 command=$4
  tmux new-session -d -s "$session" -c "$cwd" -n agent \
    -e "TMUX_AGENT_LABEL=$label" "$command"
  [[ ${TMUX_AGENT_NO_SWITCH:-0} == 1 ]] || switch_to_agent_session "$session"
}

server_key() {
  local socket pid
  socket=${TMUX%%,*}
  pid=$(tmux display-message -p '#{pid}' 2>/dev/null || printf 'unknown')
  printf '%s' "$socket:$pid" | cksum | cut -d ' ' -f 1
}

runtime_base() {
  if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
    printf '%s/tmux-agent-manager' "$XDG_RUNTIME_DIR"
  else
    printf '%s/tmux-agent-manager-%s' "${TMPDIR:-/tmp}" "$UID"
  fi
}

runtime_root() {
  printf '%s/%s' "$(runtime_base)" "$(server_key)"
}

history_root() {
  printf '%s/tmux-agent-manager/history' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

ensure_state_dirs() {
  local base runtime history
  base=$(runtime_base)
  runtime=$(runtime_root)
  history=$(history_root)
  if [[ -e $base ]]; then
    [[ ! -L $base && -O $base ]] || {
      printf 'tmux-agent-manager: unsafe runtime directory: %s\n' "$base" >&2
      return 1
    }
  else
    mkdir -m 700 "$base"
  fi
  mkdir -p "$runtime/runs" "$history"
  chmod 700 "$base" "$runtime" "$runtime/runs" "$history" 2>/dev/null || true
}

run_dir() {
  valid_id "$1" || return 1
  printf '%s/runs/%s' "$(runtime_root)" "$1"
}

pane_metadata() {
  local pane=$1
  tmux display-message -p -t "$pane" \
    $'#{pane_id}\t#{window_id}\t#{session_id}\t#{pane_current_path}'
}

register_run() {
  local thread=$1 run=$2 harness=$3 label=$4 managed=$5 pane=$6
  local dir metadata pane_id window_id session_id cwd repo='' branch='' now tmp

  ensure_state_dirs
  valid_id "$thread" && valid_id "$run" || return 1
  dir=$(run_dir "$run")
  [[ ! -e $dir ]] || {
    printf 'tmux-agent-manager: run already exists: %s\n' "$run" >&2
    return 1
  }
  mkdir "$dir" 2>/dev/null || {
    printf 'tmux-agent-manager: run already exists: %s\n' "$run" >&2
    return 1
  }
  chmod 700 "$dir"

  metadata=$(pane_metadata "$pane") || {
    printf 'tmux-agent-manager: pane %s no longer exists\n' "$pane" >&2
    return 1
  }
  IFS=$'\t' read -r pane_id window_id session_id cwd <<<"$metadata"
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)
  fi
  now=$(date +%s)
  label=$(clean_text "${label:-${cwd##*/}}")
  tmp="$dir/meta.json.tmp.$$"
  jq -n \
    --arg thread_id "$thread" \
    --arg run_id "$run" \
    --arg harness "$harness" \
    --arg label "$label" \
    --arg pane_id "$pane_id" \
    --arg window_id "$window_id" \
    --arg session_id "$session_id" \
    --arg cwd "$cwd" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --argjson managed "$managed" \
    --argjson started_at "$now" \
    '{schema:1, thread_id:$thread_id, run_id:$run_id, harness:$harness,
      label:$label, pane_id:$pane_id, window_id:$window_id,
      session_id:$session_id, cwd:$cwd, repo:$repo, branch:$branch,
      managed:$managed, started_at:$started_at, native_ids:[]}' >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/meta.json"
  : >"$dir/events.jsonl"
  printf '0\n' >"$dir/seen"
  chmod 600 "$dir/events.jsonl" "$dir/seen"

  tmux set-option -p -t "$pane_id" @agent-manager-thread "$thread" 2>/dev/null || true
  tmux set-option -p -t "$pane_id" @agent-manager-run "$run" 2>/dev/null || true
  tmux set-option -p -t "$pane_id" @agent-manager-harness "$harness" 2>/dev/null || true
}

find_run_for_pane() {
  local pane=$1 harness=$2 dir state
  ensure_state_dirs
  for dir in "$(runtime_root)"/runs/*; do
    [[ -f $dir/meta.json ]] || continue
    if [[ $(jq -r '.pane_id' "$dir/meta.json") == "$pane" && \
          $(jq -r '.harness' "$dir/meta.json") == "$harness" ]]; then
      state=$(jq -sr 'last.state // "starting"' "$dir/events.jsonl")
      [[ $state == exited || $state == crashed ]] && continue
      basename "$dir"
      return 0
    fi
  done
  return 1
}

register_degraded_run() {
  local harness=$1 native_id=$2 pane=$3 run thread
  run=$(new_uuid)
  thread=$(new_uuid)
  register_run "$thread" "$run" "$harness" "$harness" false "$pane"
  printf '%s' "$run"
}

append_event() {
  local run=$1 state=$2 event=$3 native_id=${4:-} message=${5:-}
  local dir now payload tmp pane
  dir=$(run_dir "$run")
  [[ -f $dir/meta.json ]] || return 1
  pane=$(jq -r '.pane_id' "$dir/meta.json")
  [[ $(tmux display-message -p -t "$pane" '#{@agent-manager-run}' 2>/dev/null || true) == "$run" ]] || return 0
  now=$(date +%s)
  message=$(clean_text "$message")
  payload=$(jq -cn \
    --arg state "$state" --arg event "$event" --arg native_id "$native_id" \
    --arg message "$message" --argjson at "$now" \
    '{state:$state,event:$event,native_id:$native_id,message:$message,at:$at}')

  { exec 9>"$dir/.lock"; } 2>/dev/null || return 0
  flock 9
  if [[ ! -f $dir/meta.json ]]; then
    flock -u 9
    exec 9>&-
    return 0
  fi
  printf '%s\n' "$payload" >>"$dir/events.jsonl"
  if [[ -n $native_id ]] && ! jq -e --arg id "$native_id" '.native_ids | index($id)' "$dir/meta.json" >/dev/null; then
    tmp="$dir/meta.json.tmp.$$"
    jq --arg id "$native_id" '.native_ids += [$id]' "$dir/meta.json" >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$dir/meta.json"
  fi
  flock -u 9
  exec 9>&-

  tmux set-option -p -t "$(jq -r '.pane_id' "$dir/meta.json")" \
    @agent-manager-state "$state" 2>/dev/null || true
  rebuild_cache
}

latest_event() {
  local file=$1
  jq -sc 'last // {state:"starting",event:"registered",at:0,message:""}' "$file"
}

effective_state() {
  local state=$1 updated=$2 now threshold
  threshold=$(agent_option '@agent-manager-stale-seconds' '1800')
  now=$(date +%s)
  if [[ $state == working && $updated -gt 0 && $((now - updated)) -ge $threshold ]]; then
    printf 'stale'
  else
    printf '%s' "$state"
  fi
}

mark_seen() {
  local run=$1 dir size tmp
  dir=$(run_dir "$run")
  [[ -f $dir/events.jsonl ]] || return 1
  { exec 9>"$dir/.lock"; } 2>/dev/null || return 0
  flock 9
  if [[ ! -f $dir/events.jsonl ]]; then
    flock -u 9
    exec 9>&-
    return 0
  fi
  size=$(wc -c <"$dir/events.jsonl")
  tmp="$dir/seen.tmp.$$"
  printf '%s\n' "$size" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/seen"
  flock -u 9
  exec 9>&-
  rebuild_cache
}

archive_run() {
  local run=$1 terminal_state=${2:-} dir last target tmp ended
  dir=$(run_dir "$run")
  [[ -f $dir/meta.json ]] || return 0
  { exec 8>"$dir/.lock"; } 2>/dev/null || return 0
  flock 8
  ensure_state_dirs
  last=$(latest_event "$dir/events.jsonl")
  if [[ -n $terminal_state ]]; then
    last=$(jq -cn --arg state "$terminal_state" --argjson at "$(date +%s)" \
      '{state:$state,event:"pane-gone",at:$at,message:"pane no longer exists",native_id:""}')
  fi
  ended=$(date +%s)
  target="$(history_root)/$run.json"
  tmp="$target.tmp.$$"
  jq --argjson last "$last" --argjson ended_at "$ended" \
    '. + {last_event:$last, ended_at:$ended_at}' "$dir/meta.json" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
  rm -rf "$dir"
  flock -u 8
  exec 8>&-
  prune_history
}

prune_history() {
  local limit root file count=0
  limit=$(agent_option '@agent-manager-history-limit' '100')
  [[ $limit =~ ^[0-9]+$ ]] || limit=100
  root=$(history_root)
  while IFS=$'\t' read -r _ file; do
    ((count += 1))
    [[ $count -le $limit ]] || rm -f -- "$file"
  done < <(jq -r '[.ended_at,input_filename]|@tsv' "$root"/*.json 2>/dev/null | sort -rn)
}

clear_pane_run() {
  local pane=$1 run=$2
  [[ $(tmux display-message -p -t "$pane" '#{@agent-manager-run}' 2>/dev/null || true) == "$run" ]] || return 0
  tmux set-option -pu -t "$pane" @agent-manager-run 2>/dev/null || true
  tmux set-option -pu -t "$pane" @agent-manager-thread 2>/dev/null || true
  tmux set-option -pu -t "$pane" @agent-manager-harness 2>/dev/null || true
  tmux set-option -pu -t "$pane" @agent-manager-state 2>/dev/null || true
}

branch_pr_merged() {
  local repo=$1 branch=$2 state
  [[ -n $repo && -n $branch && -d $repo ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  state=$(cd "$repo" && gh pr view "$branch" --json state --jq '.state' 2>/dev/null) || return 1
  [[ $state == MERGED ]]
}

# Only sessions this plugin created for a managed run are killed. A degraded run
# shares whatever session the user launched the harness in, and that session is
# never the plugin's to close.
kill_run_session() {
  local session=$1 managed=$2 name
  [[ $(agent_option '@agent-manager-merge-kill-session' 'on') == on ]] || return 0
  [[ $managed == true && -n $session ]] || return 0
  name=$(tmux display-message -p -t "$session" '#{session_name}' 2>/dev/null || true)
  [[ $name == ai-* ]] || return 0
  tmux kill-session -t "$session" 2>/dev/null || true
}

# Merged work is finished work: the run leaves the live list and keeps its
# metadata in history. A dedicated session for the run is closed with it.
check_merged_runs() {
  local dir run pane repo branch root dir_session managed
  ensure_state_dirs
  root=$(runtime_root)
  { exec 7>"$root/.merge.lock"; } 2>/dev/null || return 0
  flock -n 7 || { exec 7>&-; return 0; }
  for dir in "$root"/runs/*; do
    [[ -f $dir/meta.json ]] || continue
    run=${dir##*/}
    IFS=$'\t' read -r pane repo branch dir_session managed \
      < <(jq -r '[.pane_id,.repo,.branch,.session_id,(.managed|tostring)]|@tsv' "$dir/meta.json")
    [[ -n $repo && -n $branch ]] || continue
    branch_pr_merged "$repo" "$branch" || continue
    append_event "$run" merged pr-merged '' "pull request for $branch merged" || true
    clear_pane_run "$pane" "$run"
    archive_run "$run"
    kill_run_session "$dir_session" "$managed"
  done
  flock -u 7
  exec 7>&-
  rebuild_cache
}

# Polling GitHub is slow, so the check runs detached and no more often than
# the configured interval.
merge_watch() {
  local ttl root stamp now modified
  ttl=$(agent_option '@agent-manager-merge-poll-seconds' '120')
  [[ $ttl =~ ^[0-9]+$ ]] || ttl=120
  ((ttl > 0)) || return 0
  command -v gh >/dev/null 2>&1 || return 0
  root=$(runtime_root)
  [[ -d $root ]] || return 0
  stamp="$root/merge-poll"
  now=$(date +%s)
  modified=$(stat -c %Y "$stamp" 2>/dev/null || printf '0')
  ((now - modified >= ttl)) || return 0
  : >"$stamp" 2>/dev/null || return 0
  chmod 600 "$stamp" 2>/dev/null || true
  ("$plugin_dir/bin/tmux-agent" check-merges >/dev/null 2>&1 &) 2>/dev/null || true
}

reconcile_runs() {
  local dir run pane expected snapshot line
  declare -A live_runs=()
  ensure_state_dirs
  merge_watch
  snapshot=$(tmux list-panes -a -F $'#{pane_id}\t#{@agent-manager-run}' 2>/dev/null) || return 0
  while IFS=$'\t' read -r pane run; do
    [[ -n $pane ]] && live_runs[$pane]=$run
  done <<<"$snapshot"
  for dir in "$(runtime_root)"/runs/*; do
    [[ -f $dir/meta.json ]] || continue
    run=${dir##*/}
    pane=$(jq -r '.pane_id' "$dir/meta.json")
    expected=$(jq -r '.run_id' "$dir/meta.json")
    if [[ ${live_runs[$pane]:-} != "$expected" ]]; then
      append_event "$run" exited pane-gone '' 'pane no longer exists' 2>/dev/null || true
      archive_run "$run" exited
    fi
  done
  rebuild_cache
}

state_rank() {
  case $1 in
    attention|turn-failed) printf '6' ;;
    ready) printf '5' ;;
    working) printf '4' ;;
    stale) printf '3' ;;
    starting) printf '2' ;;
    *) printf '1' ;;
  esac
}

state_mark() {
  case $1 in
    attention|turn-failed) printf '#[fg=yellow,bold]!#[default]' ;;
    ready) printf '#[fg=green,bold]◆#[default]' ;;
    working) printf '#[fg=blue,bold]●#[default]' ;;
    stale) printf '#[fg=yellow]?#[default]' ;;
    crashed) printf '#[fg=red,bold]×#[default]' ;;
    starting) printf '#[fg=brightblack]·#[default]' ;;
    *) printf '' ;;
  esac
}

rebuild_cache() {
  local root cache tmp dir event state updated seen size window rank mark
  local total=0 working=0 attention=0 unseen=0 failed=0
  declare -A window_rank=() window_state=()
  root=$(runtime_root)
  mkdir -p "$root"
  cache="$root/status"

  while IFS= read -r window; do
    tmux set-option -w -t "$window" @agent-manager-window-mark '' 2>/dev/null || true
  done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null || true)

  for dir in "$root"/runs/*; do
    [[ -f $dir/meta.json ]] || continue
    event=$(latest_event "$dir/events.jsonl")
    state=$(jq -r '.state' <<<"$event")
    updated=$(jq -r '.at' <<<"$event")
    state=$(effective_state "$state" "$updated")
    seen=$(<"$dir/seen")
    size=$(wc -c <"$dir/events.jsonl")
    [[ $state == ready && $size -le $seen ]] && state=idle
    window=$(jq -r '.window_id' "$dir/meta.json")
    rank=$(state_rank "$state")
    ((total += 1))
    [[ $state == working ]] && ((working += 1))
    [[ $state == attention || $state == turn-failed ]] && ((attention += 1))
    [[ $state == turn-failed || $state == crashed ]] && ((failed += 1))
    [[ $size -gt $seen && $state != working && $state != starting ]] && ((unseen += 1))
    if [[ $rank -gt ${window_rank[$window]:-0} ]]; then
      window_rank[$window]=$rank
      window_state[$window]=$state
    fi
  done

  for window in "${!window_state[@]}"; do
    mark=$(state_mark "${window_state[$window]}")
    tmux set-option -w -t "$window" @agent-manager-window-mark "$mark" 2>/dev/null || true
  done

  tmp="$cache.tmp.$$"
  printf '%s %s %s %s %s\n' "$total" "$working" "$attention" "$unseen" "$failed" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$cache"
  tmux refresh-client -S 2>/dev/null || true
}
