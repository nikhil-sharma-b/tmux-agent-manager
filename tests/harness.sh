#!/usr/bin/env bash
# Shared scaffolding for the scenario suites. Source it; do not run it.
#
# Unlike run.sh, these suites report every failure and keep going, because a
# scenario that breaks rarely invalidates the ones after it.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails + 1)); }
check() {
  if [[ $2 == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1 — got: $(printf '%s' "$2" | tr '\n' '|' | head -c 300)"
  fi
}
scen() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# These drive real processes with real start-up cost, so wait on the condition
# rather than on a guessed interval.
wait_for() {
  local seconds=$1 attempt
  shift
  for ((attempt = 0; attempt < seconds * 20; attempt++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.05
  done
  return 1
}

screen()   { tmux capture-pane -p -t "$1" 2>/dev/null; }
sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null; }
live()     { "$root/scripts/collect.sh" "$tmp/snap" live 2>/dev/null; }

# Everything lives under one temporary directory on a private tmux server. The
# environment goes to the server as well as to this shell: whatever the server
# spawns inherits the server's environment, not ours, and would otherwise write
# its runs into the real runtime directory.
tam_start() {
  local name=$1 variable
  shift
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-$name.XXXXXX")
  socket="tmux-agent-$name-$$"
  trap 'tmux -L "$socket" kill-server 2>/dev/null || true; rm -rf "$tmp"' EXIT INT TERM
  mkdir -p "$tmp/work" "$tmp/runtime" "$tmp/state" "$tmp/cache" "$tmp/home" \
    "$tmp/bin" "$tmp/snap"
  tmux -L "$socket" -f /dev/null new-session -d -s test "$@" -c "$tmp/work"
  server_pid=$(tmux -L "$socket" display-message -p '#{pid}')
  pane=$(tmux -L "$socket" list-panes -t test -F '#{pane_id}')
  export TMUX="/tmp/tmux-$UID/$socket,$server_pid,0"
  export TMUX_PANE=$pane
  export XDG_RUNTIME_DIR="$tmp/runtime" XDG_STATE_HOME="$tmp/state"
  export XDG_CACHE_HOME="$tmp/cache" HOME="$tmp/home"
  for variable in XDG_RUNTIME_DIR XDG_STATE_HOME XDG_CACHE_HOME HOME PATH; do
    tmux set-environment -g "$variable" "${!variable}"
  done
  # shellcheck source=../scripts/lib.sh
  source "$root/scripts/lib.sh"
  # lib.sh turns on errexit for whoever sources it.
  set +e
}

# A stand-in harness, so a scenario decides how the process ends.
tam_fake_harness() {
  local name=$1 body=$2
  printf '%s\n' '#!/usr/bin/env bash' "$body" >"$tmp/bin/$name"
  chmod +x "$tmp/bin/$name"
  printf '%s' "$tmp/bin/$name"
}

tam_finish() {
  printf '\n\033[1mfailures: %s\033[0m\n' "$fails"
  exit $((fails > 0))
}
