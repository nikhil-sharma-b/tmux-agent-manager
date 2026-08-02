#!/usr/bin/env bash

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed=0
check_command() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$1"
  else
    printf 'miss  %s\n' "$1"
    failed=1
  fi
}

check_optional() {
  if command -v "$1" >/dev/null 2>&1; then
    printf 'ok    %s\n' "$1"
  else
    printf 'skip  %s (optional)\n' "$1"
  fi
}

for command in tmux fzf bash jq flock git sqlite3; do
  check_command "$command"
done
for optional in claude codex opencode agy yazi gh; do
  check_optional "$optional"
done

claude_settings=${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}
codex_hooks=${CODEX_HOOKS_FILE:-$HOME/.codex/hooks.json}
opencode_plugin=${OPENCODE_PLUGIN_DIR:-$HOME/.config/opencode/plugin}/tmux-agent-manager.js
antigravity_hooks=${ANTIGRAVITY_HOOKS_FILE:-$HOME/.gemini/config/hooks.json}

if grep -Fq "$script_dir/adapters/claude.sh" "$claude_settings" 2>/dev/null; then
  printf 'ok    Claude adapter\n'
else
  printf 'miss  Claude adapter (run setup --apply)\n'
  failed=1
fi
if grep -Fq "$script_dir/adapters/codex.sh" "$codex_hooks" 2>/dev/null; then
  printf 'ok    Codex adapter\n'
else
  printf 'miss  Codex adapter (run setup --apply)\n'
  failed=1
fi
if [[ -e $opencode_plugin ]]; then
  printf 'ok    OpenCode adapter\n'
else
  printf 'miss  OpenCode adapter (run setup --apply)\n'
  failed=1
fi
# The hooks file nests its commands two different ways, so this asks jq whether
# the adapter is actually wired up rather than whether its path appears
# somewhere in the file.
antigravity_state=missing
if [[ -f $antigravity_hooks ]] && command -v jq >/dev/null 2>&1; then
  if ! jq empty "$antigravity_hooks" 2>/dev/null; then
    antigravity_state=malformed
  elif jq -e --arg adapter "$script_dir/adapters/antigravity.sh" '
    (.["tmux-agent-manager"] // {}) as $hook |
    [$hook | to_entries[] | select(.key != "enabled") | .value[]? |
      (.hooks[]?, select(.hooks == null)) | .command // ""] as $commands |
    ($commands | length > 0) and ($commands | all(contains($adapter)))
  ' "$antigravity_hooks" >/dev/null 2>&1; then
    if [[ $(jq -r '(.["tmux-agent-manager"] // {}) |
      if has("enabled") then .enabled else true end' "$antigravity_hooks") == false ]]; then
      antigravity_state=disabled
    else
      antigravity_state=ok
    fi
  fi
fi
case $antigravity_state in
  ok) printf 'ok    Antigravity adapter\n' ;;
  disabled) printf 'warn  Antigravity adapter (hook present but disabled)\n' ;;
  malformed)
    printf 'miss  Antigravity adapter (%s is not valid JSON)\n' "$antigravity_hooks"
    failed=1
    ;;
  *)
    printf 'miss  Antigravity adapter (run setup --apply)\n'
    failed=1
    ;;
esac

exit "$failed"
