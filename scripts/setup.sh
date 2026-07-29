#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib.sh"

apply=false
[[ ${1:-} == --apply ]] && apply=true
claude_settings=${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}
codex_hooks=${CODEX_HOOKS_FILE:-$HOME/.codex/hooks.json}
opencode_plugin_dir=${OPENCODE_PLUGIN_DIR:-$HOME/.config/opencode/plugin}
claude_adapter="$script_dir/adapters/claude.sh"
codex_adapter="$script_dir/adapters/codex.sh"
opencode_adapter="$script_dir/adapters/opencode.js"

events=(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure SessionEnd)
codex_events=(SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Stop SessionEnd)

merge_hooks() {
  local file=$1 adapter=$2 array_name=$3 tmp backup event command quoted_adapter quoted_event original_sig
  local -n selected_events=$array_name
  mkdir -p "$(dirname "$file")"
  [[ -f $file ]] || printf '{"hooks":{}}\n' >"$file"
  jq empty "$file"
  original_sig=$(cksum <"$file")
  tmp="$file.tmp.$$"
  cp "$file" "$tmp"
  quoted_adapter=$(jq -rn --arg value "$adapter" '$value|@sh')
  for event in "${selected_events[@]}"; do
    quoted_event=$(jq -rn --arg value "$event" '$value|@sh')
    command="bash $quoted_adapter $quoted_event"
    jq --arg event "$event" --arg command "$command" '
      .hooks = (.hooks // {}) |
      .hooks[$event] = (.hooks[$event] // []) |
      if any(.hooks[$event][]?; any(.hooks[]?; .command == $command)) then .
      else .hooks[$event] += [{hooks:[{type:"command",command:$command,timeout:3}]}] end
    ' "$tmp" >"$tmp.next"
    mv "$tmp.next" "$tmp"
  done
  jq empty "$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    printf 'already configured %s\n' "$file"
    return 0
  fi
  [[ $(cksum <"$file") == "$original_sig" ]] || {
    rm -f "$tmp"
    printf 'tmux-agent-manager: %s changed during setup; retry\n' "$file" >&2
    return 1
  }
  backup="$file.tmux-agent-manager.$(date +%Y%m%d%H%M%S).bak"
  cp "$file" "$backup"
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
  printf 'updated %s (backup: %s)\n' "$file" "$backup"
}

printf 'tmux-agent-manager adapter setup\n\n'
printf '  Claude Code  %s\n' "$claude_settings"
printf '  Codex        %s\n' "$codex_hooks"
printf '  OpenCode     %s/tmux-agent-manager.js\n' "$opencode_plugin_dir"
printf '\nAdds lifecycle hooks only; existing entries remain unchanged.\n'

if ! $apply; then
  printf '\nRun `tmux-agent setup --apply` to back up and apply these changes.\n'
  exit 0
fi

require_command jq
merge_hooks "$claude_settings" "$claude_adapter" events
merge_hooks "$codex_hooks" "$codex_adapter" codex_events
mkdir -p "$opencode_plugin_dir"
if [[ -L $opencode_plugin_dir/tmux-agent-manager.js && \
      $(readlink "$opencode_plugin_dir/tmux-agent-manager.js") != "$opencode_adapter" ]]; then
  backup="$opencode_plugin_dir/tmux-agent-manager.js.$(date +%Y%m%d%H%M%S).bak"
  mv "$opencode_plugin_dir/tmux-agent-manager.js" "$backup"
  printf 'backed up %s\n' "$backup"
elif [[ -e $opencode_plugin_dir/tmux-agent-manager.js && ! -L $opencode_plugin_dir/tmux-agent-manager.js ]]; then
  backup="$opencode_plugin_dir/tmux-agent-manager.js.$(date +%Y%m%d%H%M%S).bak"
  mv "$opencode_plugin_dir/tmux-agent-manager.js" "$backup"
  printf 'backed up %s\n' "$backup"
fi
ln -sfn "$opencode_adapter" "$opencode_plugin_dir/tmux-agent-manager.js"
printf 'linked %s\n' "$opencode_plugin_dir/tmux-agent-manager.js"
