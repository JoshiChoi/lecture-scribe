#!/bin/bash
# Builds 강의 받아쓰기 v2 — one native app for macOS 14.2+ (Apple's on-device speech recognition: SpeechAnalyzer on
# macOS 26+, the older SFSpeechRecognizer below; Whisper, Qwen3-ASR and Parakeet as optional engines whose models are
# downloaded in the app).
#
#   scripts/build_v2.sh                       # ad-hoc signed, sandboxed → build/v2/Arc 강의 받아쓰기.app
#                                             #   and dist/v2/LectureScribe-mac.zip
#   SIGN_ID="Developer ID Application: …" scripts/build_v2.sh     # signed for GitHub (then notarize)
#   OUT=/some/dir DIST=/some/dir scripts/build_v2.sh               # build elsewhere (a copy may be running from build/v2)
#
# Needs Xcode Command Line Tools (swiftc, codesign, iconutil) and, once, cmake for scripts/build_whisper.sh and
# scripts/build_transcribe.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-2.7.3}"
BUILD_NUMBER="${BUILD_NUMBER:-273}"
SIGN_ID="${SIGN_ID:--}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/app/LectureScribe.entitlements}"
OUT="${OUT:-$ROOT/build/v2}"
DIST="${DIST:-$ROOT/dist/v2}"
APP="$OUT/Arc 강의 받아쓰기.app"
RES="$APP/Contents/Resources"
mkdir -p "$OUT" "$ROOT/dist"
step() { printf '\n· %s\n' "$*"; }

step "whisper runtime (the optional engine; its model is downloaded in the app)"
[ -f "$ROOT/vendor/whisper/lib/libwhisper.a" ] || "$ROOT/scripts/build_whisper.sh"
step "transcribe runtime (Qwen3-ASR and Parakeet; one dylib with its own private ggml)"
[ -f "$ROOT/vendor/transcribe/lib/libtranscribe.dylib" ] || "$ROOT/scripts/build_transcribe.sh"
WHISPER=(-D WHISPER -import-objc-header "$ROOT/app/WhisperBridge.h" -Xcc "-I$ROOT/vendor/whisper/include"
         -L "$ROOT/vendor/whisper/lib" -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lc++
         -framework Accelerate -framework Metal -framework Foundation
         -Xcc "-I$ROOT/vendor/transcribe/include" -L "$ROOT/vendor/transcribe/lib" -ltranscribe
         -Xlinker -rpath -Xlinker @executable_path/../Frameworks)

step "compile"
if ! swiftc -O -swift-version 5 -target arm64-apple-macos14.2 -file-prefix-map "$ROOT/=./" "${WHISPER[@]}" \
       -o "$OUT/LectureScribe" "$ROOT"/app/Audio.swift "$ROOT"/app/Recognizer.swift "$ROOT"/app/ClassicRecognizer.swift "$ROOT"/app/Engine.swift \
       "$ROOT"/app/Library.swift "$ROOT"/app/Player.swift "$ROOT"/app/Bridge.swift "$ROOT"/app/Slides.swift "$ROOT"/app/CameraFinder.swift \
       "$ROOT"/app/ScreenSlides.swift "$ROOT"/app/Whisper.swift "$ROOT"/app/main.swift 2> "$OUT/swiftc.log"; then
  cat "$OUT/swiftc.log"; exit 1
fi
grep -E "warning:" "$OUT/swiftc.log" || true
# the bare binary (tests, no sandbox) finds the runtime where the bundle has it: $OUT/../Frameworks (build/Frameworks)
mkdir -p "$OUT/../Frameworks" && ln -sf "$ROOT/vendor/transcribe/lib/libtranscribe.dylib" "$OUT/../Frameworks/libtranscribe.dylib"

step "icon"
if [ ! -f "$OUT/AppIcon.icns" ] || [ "$ROOT/app/make_icon.swift" -nt "$OUT/AppIcon.icns" ]; then
  (cd "$OUT" && swift "$ROOT/app/make_icon.swift" icon_1024 >/dev/null)
  rm -rf "$OUT/AppIcon.iconset" && mkdir -p "$OUT/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$OUT/icon_1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$OUT/icon_1024.png" --out "$OUT/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi

step "bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$RES/ui" "$RES/licenses"
cp "$OUT/LectureScribe" "$APP/Contents/MacOS/LectureScribe"
cp "$ROOT/vendor/transcribe/lib/libtranscribe.dylib" "$APP/Contents/Frameworks/"
sed -e "s|\$(MARKETING_VERSION)|$VERSION|" -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD_NUMBER|" \
    -e "s|\$(EXECUTABLE_NAME)|LectureScribe|" -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|io.github.joshichoi.lecture-scribe|" \
    "$ROOT/app/Info.plist" > "$APP/Contents/Info.plist"
cp "$OUT/AppIcon.icns" "$RES/AppIcon.icns"
cmp -s "$OUT/AppIcon.icns" "$ROOT/app/Resources/AppIcon.icns" || cp "$OUT/AppIcon.icns" "$ROOT/app/Resources/AppIcon.icns"
cp "$ROOT/app/PrivacyInfo.xcprivacy" "$RES/"
cp -R "$ROOT"/app/Resources/*.lproj "$RES/"       # name and permission prompts per Mac language (the app's 12)
cp "$ROOT/ui/index.html" "$RES/ui/"
cp -R "$ROOT/ui/i18n" "$RES/ui/i18n"              # the other languages' words (page and app)
cp -R "$ROOT/ui/fonts" "$RES/ui/fonts"
cp -R "$ROOT/ui/icons" "$RES/ui/icons"
cp "$ROOT/LICENSE" "$ROOT/licenses/Pretendard-OFL.txt" "$ROOT/licenses/whisper.cpp-MIT.txt" \
   "$ROOT/licenses/openai-whisper-MIT.txt" "$ROOT/licenses/silero-vad-MIT.txt" "$ROOT/licenses/transcribe.cpp-MIT.txt" \
   "$ROOT/licenses/transcribe.cpp-third-party.md" "$ROOT/licenses/Qwen3-ASR-Apache-2.0.txt" \
   "$ROOT/licenses/Parakeet-NVIDIA-Open-Model-License.txt" "$ROOT/licenses/llamafile-sgemm-MIT.txt" "$RES/licenses/"

step "sign ($SIGN_ID)"
xattr -cr "$APP"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP/Contents/Frameworks/libtranscribe.dylib"          # inside out: the library first
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP/Contents/Frameworks/libtranscribe.dylib"
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --strict "$APP"
for f in "$APP/Contents/MacOS/LectureScribe" "$APP/Contents/Frameworks/libtranscribe.dylib"; do   # one app for 14.2+
  m=$(vtool -show-build "$f" | awk '/minos/ {print $2; exit}')
  [ "$m" = "14.2" ] || { echo "  $(basename "$f") needs macOS $m — everything must run on 14.2"; exit 1; }
done
for a in "$ROOT"/vendor/whisper/lib/*.a; do                     # the engine libraries linked in: every object file
  m=$(otool -l "$a" | awk '/minos/ {print $2}' | sort -uV | tail -1)
  [ "$m" = "14.2" ] || { echo "  $(basename "$a") needs macOS $m — rebuild it (scripts/build_whisper.sh)"; exit 1; }
done
echo "  minimum macOS: $(vtool -show-build "$APP/Contents/MacOS/LectureScribe" | awk '/minos/ {print $2; exit}')  ·  size: $(du -sh "$APP" | cut -f1)"

step "zip"
ZIP="$DIST/LectureScribe-mac.zip"      # the release asset name the installer expects
mkdir -p "$DIST"; rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "  → $ZIP ($(du -h "$ZIP" | cut -f1))"
