#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

prepare_secure_dir() {
  local d="$1"
  if [ "$d" != "/" ]; then
    d="${d%/}"
  fi
  if [ -L "$d" ]; then echo "refusing symlink: $d" >&2; exit 1; fi
  if [ -e "$d" ] && [ ! -d "$d" ]; then echo "refusing non-directory: $d" >&2; exit 1; fi
  mkdir -p -m 0700 "$d"
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then echo "refusing unowned or replaced directory: $d" >&2; exit 1; fi
  chmod 0700 "$d"
}

UID_NUM="$(id -u)"
OUT="${IFOCUS_SBX_OUT:-/tmp/ifocus-sbx-$UID_NUM}"
prepare_secure_dir "$OUT"
MC="$OUT/modcache"
prepare_secure_dir "$MC"

export TMPDIR=/tmp
export CLANG_MODULE_CACHE_PATH="$MC"

DEV="$(xcode-select -p)"
first_dir_with() {  # first_dir_with <entry> <dir>...
  local entry="$1"; shift
  local d
  for d in "$@"; do
    if [ -e "$d/$entry" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

if [ -x "$DEV/usr/bin/swiftc" ]; then        # Command Line Tools: no xcrun, so nothing is written outside /tmp
  LAYOUT="Command Line Tools"
  SWIFTC="$DEV/usr/bin/swiftc"
  export SDKROOT="${SDKROOT:-$DEV/SDKs/MacOSX.sdk}"
else                                         # Xcode
  LAYOUT="Xcode"
  SWIFTC="$(xcrun --find swiftc)"
  export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
fi
echo "sbx.sh: $LAYOUT layout at $DEV"
FW_CANDIDATES=("$DEV/Library/Developer/Frameworks" "$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks")
PLUG_CANDIDATES=("$DEV/usr/lib/swift/host/plugins/testing" "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing")
RTLIB_CANDIDATES=("$DEV/Library/Developer/usr/lib" "$DEV/Platforms/MacOSX.platform/Developer/usr/lib")

COMMON=(-swift-version 6 -target "$(uname -m)-apple-macosx14.0" "${IFOCUS_SBX_OPT:--Onone}" -module-cache-path "$MC" -I "$OUT")

lib() {
  find "Sources/$1" -name '*.swift' -print0 | xargs -0 "$SWIFTC" "${COMMON[@]}" -enable-testing \
    -parse-as-library -wmo -module-name "$1" -emit-module -emit-module-path "$OUT/$1.swiftmodule" -c -o "$OUT/$1.o"
}

lib iFocusCore
lib iFocusMac

find Sources/iFocusApp -name '*.swift' -print0 | xargs -0 "$SWIFTC" "${COMMON[@]}" -parse-as-library -module-name iFocusApp \
  "$OUT/iFocusCore.o" "$OUT/iFocusMac.o" -o "$OUT/ifocus" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist

if [ "${1:-build}" = test ]; then
  FW="$(first_dir_with Testing.framework "${FW_CANDIDATES[@]}")" \
    || { echo "sbx.sh: Testing.framework not found; searched: ${FW_CANDIDATES[*]}" >&2; exit 2; }
  PLUG="$(first_dir_with libTestingMacros.dylib "${PLUG_CANDIDATES[@]}")" \
    || { echo "sbx.sh: libTestingMacros.dylib not found; searched: ${PLUG_CANDIDATES[*]}" >&2; exit 2; }
  RTLIB="$(first_dir_with . "${RTLIB_CANDIDATES[@]}")" || RTLIB="$FW"

  printf 'import Testing\n@main struct Runner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }\n' > "$OUT/Runner.swift"
  find Tests/iFocusCoreTests -name '*.swift' -print0 | xargs -0 "$SWIFTC" "${COMMON[@]}" -parse-as-library -module-name iFocusCoreTests \
    -F "$FW" -plugin-path "$PLUG" "$OUT/Runner.swift" "$OUT/iFocusCore.o" -o "$OUT/tests" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$RTLIB"
  "$OUT/tests"
fi
