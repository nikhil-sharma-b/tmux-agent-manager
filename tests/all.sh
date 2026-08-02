#!/usr/bin/env bash
# Every suite, in the order they get slower.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=()

for suite in run scenarios labels interactive; do
  printf '\n\033[1;34m### %s\033[0m\n' "$suite"
  if "$here/$suite.sh"; then
    printf '\033[32m%s passed\033[0m\n' "$suite"
  else
    printf '\033[31m%s failed\033[0m\n' "$suite"
    failed+=("$suite")
  fi
done

printf '\n'
if ((${#failed[@]} == 0)); then
  printf '\033[1;32mall suites passed\033[0m\n'
  exit 0
fi
printf '\033[1;31mfailed: %s\033[0m\n' "${failed[*]}"
exit 1
