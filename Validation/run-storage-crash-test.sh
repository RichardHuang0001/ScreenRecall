#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
zsh Validation/run-storage-tests.sh
test_root="$(mktemp -d "${TMPDIR:-/tmp}/ScreenRecall-CrashTest.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
set +e
.build/storage-tests --kill-after-move "$test_root" >/dev/null 2>&1
crash_code=$?
set -e
if [[ "$crash_code" -ne 137 ]]; then
  echo "FAIL: expected SIGKILL exit 137, got $crash_code" >&2
  exit 1
fi
.build/storage-tests --recover-after-kill "$test_root"
