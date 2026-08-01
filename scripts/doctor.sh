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
for optional in claude codex opencode yazi gh; do
  check_optional "$optional"
done

claude_settings=${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}
codex_hooks=${CODEX_HOOKS_FILE:-$HOME/.codex/hooks.json}
opencode_plugin=${OPENCODE_PLUGIN_DIR:-$HOME/.config/opencode/plugin}/tmux-agent-manager.js

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

exit "$failed"
