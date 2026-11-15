#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

REAL_DIR="$(mktemp -d /tmp/ifocus-check.XXXXXX)"
LINK_PATH="/tmp/ifocus-check-link.$$"
cleanup() {
  rm -f "$LINK_PATH"
  rm -rf "$REAL_DIR"
}
trap cleanup EXIT

ln -s "$REAL_DIR" "$LINK_PATH"

check_rejects_symlink() {
  local label="$1"
  shift
  local status=0
  local output
  set +e
  output="$(IFOCUS_SBX_OUT="$LINK_PATH" "$@" 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 1 ]; then
    echo "FAIL [$label]: expected exit code 1 for symlinked IFOCUS_SBX_OUT, got $status" >&2
    echo "$output" >&2
    exit 1
  fi
  if [ -e "$REAL_DIR/modcache" ] || [ -e "$REAL_DIR/iFocusCore.o" ]; then
    echo "FAIL [$label]: compiled artefacts inside symlink target despite refusal" >&2
    exit 1
  fi
}

check_rejects_symlink "sbx.sh" ./scripts/sbx.sh build
check_rejects_symlink "bundle-app.sh" ./scripts/bundle-app.sh
echo "Script hardening checks passed."
