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
  # A stray tab or newline in an ID would shift every later column of the row.
  [[ $id =~ ^[[:alnum:]_.:-]+$ ]] || return 0
  cwd=$(clean_text "$cwd")
  # Codex has no title of its own and falls back to the raw first prompt, which
  # arrives with escape sequences still in it and is often just a slash command.
  # Anything that is not a usable name defers to the directory.
  title=${title//\\n/ }
  title=${title//\\t/ }
  title=$(clean_text "$title")
  title=$(printf '%s' "$title" | tr -s ' ')
  title=${title# }
  title=${title#<task>}
  title=${title# }
  case $title in
    /*|-|'') title=${cwd##*/} ;;
  esac
  [[ -n $title ]] || title=$harness
  # A first prompt can run to thousands of characters. Keeping the whole thing
  # bloats every row and gives the fuzzy matcher a haystack instead of a name.
  title=$(truncate_text "$title" 72)
  state="$harness · saved"
  printf '%s\tnative:%s\t%s\t%s\t-\t0\t8\t%s\t%s\t\033[90m·\033[0m %-26s\t\033[90m%s · %s\033[0m\n' \
    "$id" "$harness" "$cwd" "$updated" "$title" "$state" "$(truncate_text "$title" 26)" \
    "$harness" "${cwd##*/}"
}

refresh() {
  local tmp title_file file id cwd updated title source
  declare -A claude_titles=()
  mkdir -p "$cache_dir"
  chmod 700 "$cache_dir"
  tmp="$cache_file.tmp.$$"
  title_file="$cache_dir/claude-titles.tmp.$$"
  # A refresh that is interrupted mid-scan would otherwise leave its scratch
  # files behind for good: the names carry a pid that never comes back. The
  # paths are expanded now because the trap runs after these locals are gone.
  # A signal has to end the run rather than fall through to the sort, which
  # would publish a catalog built from a half-written scan.
  trap "rm -f '$tmp' '$tmp.sorted' '$title_file'" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  find "$cache_dir" -maxdepth 1 -name '*.tmp.*' -mmin +60 -delete 2>/dev/null || true
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
        cwd, COALESCE(NULLIF(source, ''), '-') AS source,
        COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) AS updated
      FROM threads WHERE archived = 0 ORDER BY updated DESC
    " | jq -r '.[] | [.id,(.title // "-"),(.cwd // ""),(.source // "-"),(.updated // 0)]|@tsv')
  fi

  if [[ -f $opencode_db ]] && command -v sqlite3 >/dev/null 2>&1; then
    while IFS=$'\t' read -r id title cwd updated; do
      [[ -n $id && -n $cwd ]] || continue
      [[ -n $title ]] || title=${cwd##*/}
      emit_row opencode "$id" "$title" "$cwd" "$updated" >>"$tmp"
    done < <(sqlite3 -readonly -json "$opencode_db" "
      SELECT id, COALESCE(NULLIF(title, ''), '-') AS title,
        directory AS cwd, time_updated AS updated
      FROM session
      WHERE parent_id IS NULL AND time_archived IS NULL
      ORDER BY time_updated DESC
    " | jq -r '.[] | [.id,(.title // "-"),(.cwd // ""),(.updated // 0)]|@tsv')
  fi

  # Written through a rename so an interrupted refresh cannot leave readers
  # looking at a half-sorted catalog.
  sort -t $'\t' -k4,4nr "$tmp" >"$tmp.sorted"
  chmod 600 "$tmp.sorted"
  mv "$tmp.sorted" "$cache_file"
  rm -f "$tmp" "$title_file"
}

# Saved is the harnesses' own catalog of resumable conversations, enriched with
# whatever this plugin remembers about runs that used them. An archived run
# whose conversation is gone still shows up: it can be reopened in its old
# directory, just not resumed.
collect_saved() {
  local snapshot_dir=$1 tmp history_tsv dim reset
  tmp="$snapshot_dir/list.tmp"
  history_tsv="$snapshot_dir/history.tsv"
  dim=$(printf '\033[90m')
  reset=$(printf '\033[0m')
  : >"$tmp"
  : >"$history_tsv"

  # harness, native id, run, label, pinned, branch, state, ended_at, cwd
  local history_dir
  history_dir=$(history_root)
  if compgen -G "$history_dir/*.json" >/dev/null; then
    jq -r 'def clean: gsub("[\t\r\n]";" ");
      [.harness, ((.native_ids // [])|last // ""), .run_id, (.label|clean),
       ((.label_pinned // false)|tostring), ((.branch // "")|clean),
       (.last_event.state // "exited"), (.ended_at // 0), (.cwd // "")]|@tsv' \
      "$history_dir"/*.json 2>/dev/null | sort -t $'\t' -k8,8nr >"$history_tsv" || true
  fi

  awk -F '\t' -v OFS='\t' -v dim="$dim" -v reset="$reset" '
    function fit(s,   out) {
      out = s
      if (length(out) > 26) out = substr(out, 1, 25) "…"
      while (length(out) < 26) out = out " "
      return out
    }
    function join(a, b, c, d,   parts) {
      parts = a
      if (b != "") parts = parts " · " b
      if (c != "") parts = parts " · " c
      if (d != "") parts = parts " · " d
      return parts
    }
    function emit(id, kind, cwd, when, label, state, meta,   glyph) {
      glyph = (state == "crashed") ? "\033[31;1m×\033[0m" : dim "·" reset
      print id, kind, cwd, when, "-", "0", (9999999999 - when), label, state,
        glyph " " fit(label), dim meta reset
    }
    # Pass 1: the plugin history, keyed by harness and native id.
    NR == FNR {
      if ($2 != "") {
        key = $1 SUBSEP $2
        if (!(key in seen_key)) {
          seen_key[key] = 1
          h_run[key] = $3; h_label[key] = $4; h_pinned[key] = $5
          h_branch[key] = $6; h_state[key] = $7; h_ended[key] = $8
          h_cwd[key] = $9
        }
      } else {
        orphan_run[++orphans] = $3; orphan_label[orphans] = $4
        orphan_branch[orphans] = $6; orphan_state[orphans] = $7
        orphan_ended[orphans] = $8; orphan_cwd[orphans] = $9
        orphan_harness[orphans] = $1
      }
      next
    }
    # Pass 2: the harness catalog, enriched where a run used the conversation.
    {
      harness = substr($2, 8)
      key = harness SUBSEP $1
      label = $8
      state = "saved"
      branch = ""
      if (key in seen_key) {
        matched[key] = 1
        if (h_pinned[key] == "true" && h_label[key] != "") label = h_label[key]
        state = h_state[key]
        branch = h_branch[key]
      }
      emit($1, $2, $3, $4 + 0, label, state, join(harness, branch, state, ""))
    }
    END {
      # Archived runs whose conversation the harness no longer offers.
      for (i = 1; i <= orphans; i++)
        emit(orphan_run[i], "history-only", orphan_cwd[i], orphan_ended[i],
          orphan_label[i], orphan_state[i],
          join(orphan_harness[i], orphan_branch[i], orphan_state[i], "no resume"))
      for (key in seen_key) {
        if (key in matched) continue
        split(key, part, SUBSEP)
        emit(h_run[key], "history-only", h_cwd[key], h_ended[key], h_label[key],
          h_state[key], join(part[1], h_branch[key], h_state[key], "no resume"))
      }
    }
  ' "$history_tsv" "$cache_file" >>"$tmp"

  sort -t $'\t' -k7,7n "$tmp" >"$snapshot_dir/list"
  rm -f "$tmp" "$history_tsv"
  cat "$snapshot_dir/list"
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
    collect_saved "$snapshot_dir"
    ;;
  list)
    ensure_fresh
    awk -F '\t' '{ printf "%-10s  %-32s  %s\n", substr($2,8), $8, $3 }' "$cache_file"
    ;;
  *) printf 'tmux-agent sessions: unknown action: %s\n' "$1" >&2; exit 2 ;;
esac
