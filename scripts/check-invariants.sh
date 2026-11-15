#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0

fail_msg() {
  echo "INVARIANT VIOLATION: $1" >&2
  failed=1
}

check_forbidden() {
  local scope="$1"
  local label="$2"
  shift 2
  local pattern
  for pattern in "$@"; do
    local hits
    hits="$(grep -rnF "$pattern" "$scope" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      fail_msg "[$label] forbidden pattern '$pattern' in $scope:"
      echo "$hits" >&2
    fi
  done
}

# I1: Forbidden UI/input/title APIs anywhere in Sources/
check_forbidden "Sources" "I1" \
  "CGWarpMouseCursorPosition" \
  "CGEventPost" \
  "CGEvent(mouseEventSource" \
  "CGEvent(keyboardEventSource" \
  "CGEventTapCreate" \
  "CGEvent.tapCreate" \
  "addGlobalMonitorForEvents" \
  "AXUIElementPostKeyboardEvent" \
  "kAXPressAction" \
  "kCGWindowName" \
  "kAXTitleAttribute" \
  "activateAllWindows" \
  "activateIgnoringOtherApps"

# I2: Forbidden XCTest / atomic writes / temporaryDirectory in Sources/ and Tests/
check_forbidden "Sources" "I2" \
  "import XCTest" \
  ".atomic" \
  "temporaryDirectory" \
  "NSTemporaryDirectory"

if [ -d "Tests" ]; then
  check_forbidden "Tests" "I2" \
    "import XCTest" \
    ".atomic" \
    "temporaryDirectory" \
    "NSTemporaryDirectory"
fi

# I3: Sources/iFocusCore may import only Foundation and CoreGraphics
if [ -d "Sources/iFocusCore" ]; then
  imports="$(grep -rnE '^[[:space:]]*(@[[:alpha:]]+[[:space:]]+)?import[[:space:]]+' Sources/iFocusCore 2>/dev/null || true)"
  if [ -n "$imports" ]; then
    bad_imports="$(echo "$imports" | grep -vE ':[[:space:]]*import[[:space:]]+(Foundation|CoreGraphics)[[:space:]]*(//.*)?$' || true)"
    if [ -n "$bad_imports" ]; then
      fail_msg "[I3] disallowed import in Sources/iFocusCore:"
      echo "$bad_imports" >&2
    fi
  fi
fi

# I4: @unchecked Sendable at most twice (only inside Sources/iFocusMac/Gaze/)
# and nonisolated(unsafe) exact once (only inside Sources/iFocusCore/Simulation/SimServices.swift)
unchecked_all="$(grep -rnE '@unchecked[[:space:]]+Sendable' Sources 2>/dev/null || true)"
if [ -n "$unchecked_all" ]; then
  unchecked_outside="$(echo "$unchecked_all" | grep -v '^Sources/iFocusMac/Gaze/' || true)"
  if [ -n "$unchecked_outside" ]; then
    fail_msg "[I4] @unchecked Sendable outside Sources/iFocusMac/Gaze/:"
    echo "$unchecked_outside" >&2
  fi
  unchecked_count="$(echo "$unchecked_all" | wc -l | tr -d ' ')"
  if [ "$unchecked_count" -gt 2 ]; then
    fail_msg "[I4] @unchecked Sendable appears $unchecked_count times (limit 2):"
    echo "$unchecked_all" >&2
  fi
fi

nonisolated_unsafe_all="$(grep -rnF 'nonisolated(unsafe)' Sources 2>/dev/null || true)"
if [ -z "$nonisolated_unsafe_all" ]; then
  fail_msg "[I4] nonisolated(unsafe) missing (expected exact 1 occurrence in SimServices.swift)"
else
  nonisolated_unsafe_outside="$(echo "$nonisolated_unsafe_all" | grep -v '^Sources/iFocusCore/Simulation/SimServices.swift:' || true)"
  if [ -n "$nonisolated_unsafe_outside" ]; then
    fail_msg "[I4] nonisolated(unsafe) outside Sources/iFocusCore/Simulation/SimServices.swift:"
    echo "$nonisolated_unsafe_outside" >&2
  fi
  nonisolated_unsafe_count="$(echo "$nonisolated_unsafe_all" | wc -l | tr -d ' ')"
  if [ "$nonisolated_unsafe_count" -ne 1 ]; then
    fail_msg "[I4] nonisolated(unsafe) appears $nonisolated_unsafe_count times (expected exact 1):"
    echo "$nonisolated_unsafe_all" >&2
  fi
fi

# I5: _AXUIElementGetWindow confined to Sources/iFocusMac/Focus/AXWindowID.swift
ax_priv="$(grep -rnF "_AXUIElementGetWindow" Sources 2>/dev/null || true)"
if [ -n "$ax_priv" ]; then
  ax_outside="$(echo "$ax_priv" | grep -v '^Sources/iFocusMac/Focus/AXWindowID.swift:' || true)"
  if [ -n "$ax_outside" ]; then
    fail_msg "[I5] _AXUIElementGetWindow outside Sources/iFocusMac/Focus/AXWindowID.swift:"
    echo "$ax_outside" >&2
  fi
fi

# I6: No try!, fatalError(, or main.swift in Sources/
check_forbidden "Sources" "I6" "try!" "fatalError("
main_files="$(find Sources -name 'main.swift' 2>/dev/null || true)"
if [ -n "$main_files" ]; then
  fail_msg "[I6] main.swift found in Sources/:"
  echo "$main_files" >&2
fi

# I7: scripts/ must use set -euo pipefail and avoid dynamic execution, network, or privilege escalation commands
for script in scripts/*.sh; do
  if ! grep -qF "set -euo pipefail" "$script"; then
    fail_msg "[I7] missing 'set -euo pipefail' in $script"
  fi
  bad_cmds="$(grep -nE "(^|[^A-Za-z0-9_])(e""val|c""url|s""udo)([^A-Za-z0-9_]|$)" "$script" || true)"
  if [ -n "$bad_cmds" ]; then
    fail_msg "[I7] forbidden command in $script:"
    echo "$bad_cmds" >&2
  fi
done

# I8: No host home paths or local file URLs in tracked or non-ignored files
i8_pat1="/Us""ers/[A-Za-z0-9._-]+"
i8_pat2="/ho""me/[A-Za-z0-9._-]+/"
i8_pat3="fi""le:///"
i8_regex="($i8_pat1|$i8_pat2|$i8_pat3)"
check_i8_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  local hits
  hits="$(grep -nIE "$i8_regex" "$f" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    fail_msg "[I8] host path or local file URL in $f:"
    echo "$hits" >&2
  fi
}

if TMPDIR=/tmp /Library/Developer/CommandLineTools/usr/bin/git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_BIN="$(command -v git)"
  if [ -x /Library/Developer/CommandLineTools/usr/bin/git ]; then
    GIT_BIN="/Library/Developer/CommandLineTools/usr/bin/git"
  fi
  while IFS= read -r -d '' f; do
    check_i8_file "$f"
  done < <((TMPDIR=/tmp "$GIT_BIN" ls-files -z; TMPDIR=/tmp "$GIT_BIN" ls-files --others --exclude-standard -z) 2>/dev/null)
else
  while IFS= read -r -d '' f; do
    check_i8_file "$f"
  done < <(find . -not -path './.git/*' -not -path './dist/*' -type f -print0)
fi

# I9: No networking APIs in Sources/
check_forbidden "Sources" "I9" \
  "URLSession" \
  "URLRequest" \
  "NWConnection" \
  "NWListener" \
  "import Network" \
  "CFSocket" \
  "NSURLConnection"

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "All invariants passed."
