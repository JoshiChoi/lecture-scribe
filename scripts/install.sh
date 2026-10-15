#!/bin/bash
# Arc 강의 받아쓰기 (Arc Lecture Transcriber) installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/WeldingArc/arc-lecture-transcriber/main/scripts/install.sh | bash
#
# One line that picks the right version for this Mac (v2 on macOS 26+, v1 on 14.2–15) and puts it in
# Applications. v1 isn't notarized, so a v1 zip opened from a browser download is blocked by
# Gatekeeper; downloaded with curl it isn't quarantined and opens normally.
# It speaks Korean when the Mac's first language is Korean, English otherwise.
set -euo pipefail
REPO="WeldingArc/arc-lecture-transcriber"
URL_V2="https://github.com/$REPO/releases/latest/download/LectureScribe-mac.zip"
URL_V1="https://github.com/$REPO/releases/download/v1.0.0/LectureScribe-mac.zip"       # Whisper version (its app is still "강의 받아쓰기.app")
APP_NAME="Arc 강의 받아쓰기.app"
OLD_NAME="강의 받아쓰기.app"                 # before 2.5.1 (v1 too)

first="$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",' || true)"    # ko-KR, en-US …
case "$first" in ko*) KO=1 ;; *) KO= ;; esac
say() { if [ -n "$KO" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }        # say "한국어" "English"

if [ "$(uname -m)" != "arm64" ]; then
  say "죄송해요. Apple Silicon(M1 이상) Mac에서만 동작해요." "Sorry — Arc Lecture Transcriber runs only on Apple Silicon Macs (M1 or later)."; exit 1
fi
ver="$(sw_vers -productVersion)"
major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 2 ]; }; then
  say "macOS 14.2 이상이 필요해요. (지금: $ver)" "Arc Lecture Transcriber needs macOS 14.2 or later. (This Mac: $ver)"; exit 1
fi
# macOS 26+: v2 (Apple's on-device speech recognition). 14.2–15: v1 (Whisper) — and how to get the current version.
if [ "$major" -ge 26 ]; then URL="$URL_V2"; else
  URL="$URL_V1"
  say "이 Mac의 macOS: $ver. 최신 버전은 macOS 26 이상이 필요해서, 예전 Whisper 버전(v1)을 설치해요." \
      "This Mac has macOS $ver. The current version needs macOS 26 or later, so this installs the older Whisper version (v1)."
  say "최신 버전을 쓰려면 시스템 설정 › 일반 › 소프트웨어 업데이트에서 macOS를 업데이트(무료)한 뒤 이 명령을 다시 실행해 주세요." \
      "To get the current version, update macOS (free) in System Settings › General › Software Update, then run this command again."
fi
URL="${LECTURE_ZIP_URL:-$URL}"     # override: tests

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
say "Arc 강의 받아쓰기 내려받는 중…" "Downloading Arc Lecture Transcriber…"
curl -fL --progress-bar "$URL" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || APP_NAME="$OLD_NAME"      # v1 keeps the old name
[ -d "$tmp/unzipped/$APP_NAME" ] || { say "내려받은 파일이 올바르지 않아요. 잠시 후 다시 시도해 주세요." "The download doesn't look right. Please try again in a moment."; exit 1; }

dest="${LECTURE_INSTALL_DIR:-/Applications}"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
for old in "$APP_NAME" "$OLD_NAME"; do                 # update: replace the previous version of this app only
  [ -d "$dest/$old" ] || continue
  if pgrep -fl "Contents/MacOS/LectureScribe" 2>/dev/null | grep -q " $dest/"; then   # (a Korean path in pgrep's pattern can miss: NFD)
    say "Arc 강의 받아쓰기가 실행 중이에요. 앱을 종료(⌘Q)한 뒤 이 명령을 다시 실행해 주세요." "Arc Lecture Transcriber is running. Quit it (⌘Q), then run this command again."; exit 1
  fi
  rm -rf "$dest/$old"
done
ditto "$tmp/unzipped/$APP_NAME" "$dest/$APP_NAME"
xattr -dr com.apple.quarantine "$dest/$APP_NAME" 2>/dev/null || true
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$dest/$APP_NAME/Contents/Info.plist" 2>/dev/null || true)"

say "설치 완료 (버전 ${version:-?}): $dest/$APP_NAME" "Installed version ${version:-?}: $dest/$APP_NAME"
if [ "$major" -ge 26 ]; then
  [ -d "$HOME/Library/Application Support/LectureScribe/models" ] && \
    say "참고: v1의 AI 모델(570MB)은 이제 필요 없어요. 지우려면: rm -rf ~/Library/Application\\ Support/LectureScribe/models" \
        "Note: v1's AI model (570 MB) isn't needed any more. To delete it: rm -rf ~/Library/Application\\ Support/LectureScribe/models"
else
  say "처음 실행하면 AI 모델(약 570MB)을 한 번 내려받아요." "On first launch it downloads its AI model once (about 570 MB)."
fi
[ -n "${LECTURE_NO_OPEN:-}" ] || open "$dest/$APP_NAME"
