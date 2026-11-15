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

USE_SWIFTPM=0
if [ "${1:-}" = "--swiftpm" ]; then
  USE_SWIFTPM=1
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--swiftpm]" >&2
  exit 64
fi

UID_NUM="$(id -u)"
export TMPDIR=/tmp

if [ "$USE_SWIFTPM" -eq 1 ]; then
  CLANG_CACHE="/tmp/clang-cache-$UID_NUM"
  SWIFTPM_CACHE="/tmp/swiftpm-cache-$UID_NUM"
  SCRATCH_DIR="/tmp/ifocus-build-$UID_NUM"
  SWIFT_MODCACHE="/tmp/swift-modcache-$UID_NUM"
  prepare_secure_dir "$CLANG_CACHE"
  prepare_secure_dir "$SWIFTPM_CACHE"
  prepare_secure_dir "$SCRATCH_DIR"
  prepare_secure_dir "$SWIFT_MODCACHE"
  plutil -lint Resources/Info.plist >/dev/null
  export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE"
  export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE"
  swift build -c release --disable-sandbox --scratch-path "$SCRATCH_DIR" \
    -Xswiftc -module-cache-path -Xswiftc "$SWIFT_MODCACHE"
  BIN_DIR="$(swift build -c release --disable-sandbox --scratch-path "$SCRATCH_DIR" --show-bin-path)"
  BIN_PATH="$BIN_DIR/ifocus"
else
  OUT_DIR="${IFOCUS_SBX_OUT:-/tmp/ifocus-sbx-$UID_NUM}"
  prepare_secure_dir "$OUT_DIR"
  plutil -lint Resources/Info.plist >/dev/null
  IFOCUS_SBX_OPT="-O" IFOCUS_SBX_OUT="$OUT_DIR" ./scripts/sbx.sh build
  BIN_PATH="$OUT_DIR/ifocus"
fi

APP_DIR="dist/iFocus.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/ifocus"
chmod +x "$APP_DIR/Contents/MacOS/ifocus"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --sign "${IFOCUS_SIGN_IDENTITY:--}" \
  --identifier dev.ifocus.app \
  --options runtime \
  --entitlements Resources/iFocus.entitlements \
  "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "Bundled and signed $APP_DIR"
