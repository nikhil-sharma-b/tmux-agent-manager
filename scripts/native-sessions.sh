#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agent-manager
cache_file=$cache_dir/native-sessions.tsv
claude_projects=${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}
claude_history=${CLAUDE_HISTORY_FILE:-$HOME/.claude/history.jsonl}
codex_db=${CODEX_DB:-$HOME/.codex/state_5.sqlite}
opencode_db=${OPENCODE_DB:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}

emit_row() {
  local harness=$1 id=$2 title=$3 cwd=$4 updated=$5 state
  title=$(clean_text "$title")
  cwd=$(clean_text "$cwd")
  state="$harness · saved"
  printf '%s\tnative:%s\t%s\t%s\t-\t0\t8\t%s\t%s\t\033[90m·\033[0m %-26s\t\033[90m%s · %s\033[0m\n' \
    "$id" "$harness" "$cwd" "$updated" "$title" "$state" "$title" "$harness" "${cwd##*/}"
}

refresh() {
  local tmp title_file file id cwd updated title source
  declare -A claude_titles=()
  mkdir -p "$cache_dir"
  chmod 700 "$cache_dir"
  tmp="$cache_file.tmp.$$"
  title_file="$cache_dir/claude-titles.tmp.$$"
  : >"$tmp"
  : >"$title_file"

  if [[ -d $claude_projects ]]; then
    # Title records are small metadata events; transcript messages are never read or cached.
    grep -h -E '"type":"(ai-title|agent-name)"' "$claude_projects"/*/*.jsonl 2>/dev/null \
      | jq -Rr 'fromjson? | select(.sessionId != null) |
        [.sessionId, (.agentName // .aiTitle // "")]|@tsv' >"$title_file" || true
    while IFS=$'\t' read -r id title; do
      [[ -n $id && -n $title ]] && claude_titles[$id]=$title
    done <"$title_file"
  fi

  if [[ -f $claude_history ]]; then
    while IFS=$'\t' read -r id cwd updated; do
      [[ -n $id && -n $cwd ]] || continue
      title=${claude_titles[$id]:-${cwd##*/}}
      emit_row claude "$id" "$title" "$cwd" "$updated" >>"$tmp"
    done < <(jq -sr '
      group_by(.sessionId) | map(max_by(.timestamp)) | .[] |
      select(.sessionId != null and .project != null) |
      [.sessionId,.project,(.timestamp // 0)]|@tsv
    ' "$claude_history")
  fi

  if [[ -f $codex_db ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS=$'\t' read -r id title cwd source updated; do
      [[ -n $id && -n $cwd ]] || continue
      [[ -n $title ]] || title=${cwd##*/}
      emit_row codex "$id" "$title" "$cwd" "$updated" >>"$tmp"
    done < <(sqlite3 -readonly -json "$codex_db" "
      SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), 'Codex session') AS title,
        cwd, source,
        COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) AS updated
      FROM threads WHERE archived = 0 ORDER BY updated DESC
    " | jq -r '.[] | [.id,.title,.cwd,.source,(.updated // 0)]|@tsv')
  fi

  if [[ -f $opencode_db ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS=$'\t' read -r id title cwd updated; do
      [[ -n $id && -n $cwd ]] || continue
      [[ -n $title ]] || title=${cwd##*/}
      emit_row opencode "$id" "$title" "$cwd" "$updated" >>"$tmp"
    done < <(sqlite3 -readonly -json "$opencode_db" '
      SELECT id, title, directory AS cwd, time_updated AS updated
      FROM session
      WHERE parent_id IS NULL AND time_archived IS NULL
      ORDER BY time_updated DESC
    ' | jq -r '.[] | [.id,.title,.cwd,(.updated // 0)]|@tsv')
  fi

  sort -t $'\t' -k4,4nr "$tmp" >"$cache_file"
  chmod 600 "$cache_file"
  rm -f "$tmp" "$title_file"
}

ensure_fresh() {
  local ttl modified now
  ttl=$(agent_option '@agent-manager-native-cache-seconds' '60')
  [[ $ttl =~ ^[0-9]+$ ]] || ttl=60
  if [[ -f $cache_file ]]; then
    modified=$(stat -c %Y "$cache_file" 2>/dev/null || printf '0')
    now=$(date +%s)
    ((now - modified < ttl)) && return 0
  fi
  refresh
}

case ${1:-list} in
  refresh) refresh ;;
  collect)
    snapshot_dir=${2:?snapshot directory required}
    ensure_fresh
    cp "$cache_file" "$snapshot_dir/list"
    cat "$snapshot_dir/list"
    ;;
  list)
    ensure_fresh
    awk -F '\t' '{ printf "%-10s  %-32s  %s\n", substr($2,8), $8, $3 }' "$cache_file"
    ;;
  *) printf 'tmux-agent sessions: unknown action: %s\n' "$1" >&2; exit 2 ;;
esac
