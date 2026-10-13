#!/usr/bin/env bash
# Builds B.P into an .ipa. Needs macOS + Xcode 15+ (iOS 17 SDK) and XcodeGen (installed via Homebrew if missing).
#
#   Signed build (device testing / TestFlight / App Store):
#     DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID=com.yourname.bp METHOD=development ./scripts/build_ipa.sh
#   Unsigned build (re-sign later with AltStore / Sideloadly / your own tooling):
#     UNSIGNED=1 ./scripts/build_ipa.sh
#
# METHOD: development | ad-hoc | app-store-connect | enterprise      (default: development)
# Output: build/ipa/BP.ipa   (signed)   or   build/BP-unsigned.ipa   (unsigned)
# Everything is also written to build/xcodebuild.log.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
LOG=build/xcodebuild.log
: > "$LOG"

# On any failure: show the likely errors and the last lines of the log as GitHub annotations
# ("::error::" is plain text when run locally).
on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return 0
  echo "---- build failed (exit $rc); full log: $LOG ----"
  grep -iE "error:|fatal error|failed|not found|No such file" "$LOG" | sort -u | head -15 | cut -c1-300 \
    | while IFS= read -r l; do echo "::error::${l}"; done
  local tailmsg
  tailmsg="$(tail -n 25 "$LOG" | cut -c1-200 | sed 's/%/%25/g' | awk 'BEGIN{ORS="%0A"}{print}')"
  echo "::error title=Last lines of the build log::${tailmsg}"
}
trap on_exit EXIT

die() { echo "error: $*" | tee -a "$LOG" >&2; exit 1; }
run() { echo "+ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }   # pipefail makes a failing command fail the script

BUNDLE_ID="${BUNDLE_ID:-com.example.bp}"
METHOD="${METHOD:-development}"
UNSIGNED="${UNSIGNED:-0}"

[[ "$(uname)" == "Darwin" ]] || die "building an IPA needs macOS with Xcode."
command -v xcodebuild >/dev/null || die "xcodebuild not found; install Xcode."
run xcodebuild -version
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || die "install XcodeGen (brew install xcodegen)."
  run brew install xcodegen
fi

# Shader and catalog consistency checks (cheap; catches slot mismatches before a long build).
if command -v python3 >/dev/null; then run python3 tools/check_catalog.py; fi

run xcodegen generate
[[ -d BP.xcodeproj ]] || die "xcodegen did not create BP.xcodeproj"

if [[ "$UNSIGNED" == "1" ]]; then
  run xcodebuild -project BP.xcodeproj -scheme BP -configuration Release -sdk iphoneos \
    -derivedDataPath build/DerivedData \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build
  APP="build/DerivedData/Build/Products/Release-iphoneos/BP.app"
  if [[ ! -d "$APP" ]]; then
    run find build/DerivedData/Build/Products -maxdepth 2
    die "$APP not found"
  fi
  rm -rf build/Payload build/BP-unsigned.ipa
  mkdir -p build/Payload
  cp -R "$APP" build/Payload/
  (cd build && zip -qr BP-unsigned.ipa Payload)
  rm -rf build/Payload
  echo "Built build/BP-unsigned.ipa (unsigned: it will not install until it is signed)." | tee -a "$LOG"
  exit 0
fi

[[ -n "${DEVELOPMENT_TEAM:-}" ]] || die "set DEVELOPMENT_TEAM to your 10-character Apple Developer Team ID (or use UNSIGNED=1)"

run xcodebuild -project BP.xcodeproj -scheme BP -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/BP.xcarchive \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
  archive

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>${METHOD}</string>
  <key>teamID</key><string>${DEVELOPMENT_TEAM}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST

rm -rf build/ipa
run xcodebuild -exportArchive -archivePath build/BP.xcarchive \
  -exportPath build/ipa -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates

echo "Built $(ls build/ipa/*.ipa)" | tee -a "$LOG"
