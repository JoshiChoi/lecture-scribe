#!/bin/bash
# Certificate-signed builds of 강의 받아쓰기 v2, made with Xcode (Xcode must be signed in to the
# Apple Developer account: Xcode → Settings → Accounts).
#
#   scripts/xcode_release.sh github     # Developer ID → notarized by Apple → dist/v2/LectureScribe-mac.zip
#   scripts/xcode_release.sh appstore   # Mac App Store build → uploaded to App Store Connect
#
# Signing is automatic (Xcode's cloud-managed certificates): no passwords or API keys are used here.
# Env: TEAM_ID (default: the paid team Xcode knows), BUILD_NUMBER (App Store uploads need a new one).
set -euo pipefail
MODE="${1:-}"
[ "$MODE" = github ] || [ "$MODE" = appstore ] || { echo "usage: $0 github|appstore" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="$ROOT/build/xc-$MODE"
ARCHIVE="$OUT/LectureScribe.xcarchive"
APP_NAME="Arc 강의 받아쓰기.app"
step() { printf '\n· %s\n' "$*"; }

if [ -z "${TEAM_ID:-}" ]; then
  TEAM_ID="$(defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
d = plistlib.loads(sys.stdin.buffer.read())
teams = [t for ts in d.get("IDEProvisioningTeamByIdentifier", {}).values() for t in ts
         if not t.get("isFreeProvisioningTeam")]
print(teams[0]["teamID"] if teams else "")' || true)"
fi
[ -n "$TEAM_ID" ] || { echo "No paid Apple Developer team found in Xcode. Sign in: Xcode → Settings → Accounts." >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT" "$ROOT/dist/v2"
step "Xcode project"
[ -f vendor/whisper/lib/libwhisper.a ] || scripts/build_whisper.sh     # the optional Whisper engine's runtime
[ -f vendor/transcribe/lib/libtranscribe.dylib ] || scripts/build_transcribe.sh   # Qwen3-ASR and Parakeet
xcodegen generate --quiet

step "archive (team $TEAM_ID)"
xcodebuild archive -project LectureScribe.xcodeproj -scheme LectureScribe -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER} \
  -allowProvisioningUpdates -quiet
for f in "$ARCHIVE"/Products/Applications/*.app/Contents/MacOS/* "$ARCHIVE"/Products/Applications/*.app/Contents/Frameworks/*.dylib; do
  m=$(vtool -show-build "$f" | awk '/minos/ {print $2; exit}')            # one app for macOS 14.2+
  [ "$m" = "14.2" ] || { echo "  $(basename "$f") needs macOS $m — everything must run on 14.2"; exit 1; }
done

options() {   # export options: $1 = method
  cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$1</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
}

if [ "$MODE" = appstore ]; then
  step "upload to App Store Connect"
  options app-store-connect
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates
  echo "  → uploaded. It appears in App Store Connect (TestFlight tab) after Apple processes it (5–30 min)."
  exit 0
fi

step "send to Apple for notarization"
options developer-id
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates

step "wait for notarization (usually 1–10 min)"
for i in $(seq 1 90); do
  if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" >"$OUT/notarized.log" 2>&1; then
    break
  fi
  [ "$i" = 90 ] && { echo "Notarization did not finish in 45 min:"; tail -5 "$OUT/notarized.log"; exit 1; }
  sleep 30
done
APP="$OUT/notarized/$APP_NAME"

step "verify"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" 2>&1
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp)' | head -4

step "zip"
ZIP="$ROOT/dist/v2/LectureScribe-mac.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "  → $ZIP ($(du -h "$ZIP" | cut -f1))"
