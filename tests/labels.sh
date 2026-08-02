#!/usr/bin/env bash
# A run names itself: the workspace stands in until the harness writes a title,
# and a name the user chose is never replaced.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
tam_start labels

catalog="$tmp/cache/tmux-agent-manager/native-sessions.tsv"
mkdir -p "$(dirname "$catalog")"
publish_title() { # publish_title <native id> <title> <cwd>
  printf '%s\tnative:claude\t%s\t900\t-\t0\t8\t%s\tclaude\tx\ty\n' "$1" "$3" "$2" >"$catalog"
}

scen 'What a run is called before the harness says anything'
mkdir -p "$tmp/plain"
check 'a plain directory lends its name' "$(default_run_label "$tmp/plain")" 'plain'
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b feat/my-branch
check 'a checkout lends its branch instead' "$(default_run_label "$repo")" 'feat/my-branch'

scen 'A run adopts the title its harness writes'
work_pane=$(tmux split-window -d -P -F '#{pane_id}' -t test -c "$repo" 'sleep 300')
IFS=$'\t' read -r _ run < <("$root/bin/tmux-agent" register \
  --harness claude --label '' --pane "$work_pane")
meta="$(runtime_root)/runs/$run/meta.json"
check 'it starts named after its branch' "$(live)" 'feat/my-branch'
check 'the run records the current schema' "$(jq -r '.schema' "$meta")" '2'
check 'a run that named itself is not pinned' "$(jq -r '.label_pinned' "$meta")" 'false'

# The harness reports which conversation it is, but has not titled it yet.
printf '{"session_id":"sess-abc"}' |
  TMUX_AGENT_RUN_ID=$run TMUX_AGENT_PANE_ID=$work_pane TMUX_AGENT_HARNESS=claude \
    "$root/scripts/adapters/claude.sh" UserPromptSubmit
check 'the fallback holds while there is no title' "$(live)" 'feat/my-branch'

publish_title sess-abc 'Refactor the auth middleware' "$repo"
check 'the title is adopted once it exists' "$(live)" 'Refactor the auth middleware'
check 'the adoption is recorded' "$(jq -r '.adopted_title' "$meta")" 'Refactor'

scen 'A name you chose is never taken away'
printf 'my chosen name\n' | "$root/scripts/rename.sh" "$run" >/dev/null
check 'the rename applies' "$(live)" 'my chosen name'
check 'the rename pins the label' "$(jq -r '.label_pinned' "$meta")" 'true'
publish_title sess-abc 'A completely different title' "$repo"
adopt_saved_title "$run"
check 'a later harness title is ignored' "$(live)" 'my chosen name'
if [[ $(live) == *'completely different'* ]]; then
  bad 'the pinned label was overwritten'
else
  ok 'the pin held'
fi

scen 'Saved rows keep the row contract'
saved=$("$root/scripts/native-sessions.sh" collect "$tmp/snap" 2>/dev/null)
check 'every saved row has eleven fields' \
  "$(awk -F '\t' '{print NF}' <<<"$saved" | sort -u)" '11'

tam_finish
