#!/bin/bash

# Every Barback test, in order of how much it needs from the machine.
#
#   model  — node only, hermetic
#   about  — node only, reads the repo (the About page's facts and privacy)
#   cli    — the real omarchy-shell-config against a scratch HOME, mocked reload
#   compat — the real widget hosting the real installed plugins, sandboxed,
#            and the About page in the real widget with a scratch HOME
#
# Nothing here installs Barback, writes to the live shell.json, or restarts
# the shell. Pass --no-compat to skip the run that needs quickshell, a
# compositor, and an unprivileged network namespace.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_COMPAT=1
[[ ${1:-} == --no-compat ]] && RUN_COMPAT=0

failed=()

stage() {
  local name="$1"; shift
  printf '\n==> %s\n' "$name"
  if "$@"; then
    printf '<== %s passed\n' "$name"
  else
    printf '<== %s FAILED\n' "$name"
    failed+=("$name")
  fi
}

stage "manifest validation" omarchy plugin validate "$ROOT"
stage "syntax" bash -c 'bash -n "$1/bin/barback" && bash -n "$1/install.sh"' _ "$ROOT"
stage "model (node)" node "$ROOT/tests/model_test.js"
stage "about (node)" node "$ROOT/tests/about_test.js"
stage "cli" bash "$ROOT/tests/cli_test.sh"
if [[ $RUN_COMPAT -eq 1 ]]; then
  stage "about page (qml)" bash "$ROOT/tests/about_qml_test.sh"
  stage "real-plugin compatibility (horizontal bar)" \
    env BARBACK_POSITION=top bash "$ROOT/tests/qml_compat_test.sh"
  # Vertical bars are the case where `vertical: true` has to reach every
  # resident's shim, so the residents pick their own compact forms.
  stage "real-plugin compatibility (vertical bar)" \
    env BARBACK_POSITION=left bash "$ROOT/tests/qml_compat_test.sh"
fi

printf '\n'
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "all stages passed"
  exit 0
fi
printf 'failed: %s\n' "${failed[*]}"
exit 1
