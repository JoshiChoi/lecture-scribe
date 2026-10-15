#!/bin/bash
# Arc 강의 받아쓰기 (Arc Lecture Transcriber) installer — downloads the latest release and puts it in your Applications folder.
#
#   curl -fsSL https://raw.githubusercontent.com/WeldingArc/arc-lecture-transcriber/main/scripts/install.sh | bash
#
# One version for every Mac: the latest release (Apple Silicon, macOS 14.2 or later). Below macOS 26 the app transcribes
# with Apple's older speech recognition — the installer and the app say so and recommend the latest macOS. It speaks
# Korean when the Mac's first language is Korean, English otherwise.
set -euo pipefail
REPO="WeldingArc/arc-lecture-transcriber"
URL="${LECTURE_ZIP_URL:-https://github.com/$REPO/releases/latest/download/LectureScribe-mac.zip}"     # override: tests
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
if [ "$major" -ge 13 ]; then where_ko="시스템 설정 › 일반 › 소프트웨어 업데이트"; where_en="System Settings › General › Software Update"
else where_ko="시스템 환경설정 › 소프트웨어 업데이트"; where_en="System Preferences › Software Update"; fi
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "${minor:-0}" -lt 2 ]; }; then   # the system-audio capture needs 14.2
  say "Arc 강의 받아쓰기는 macOS 14.2 이상이 필요해요. (이 Mac: macOS $ver)" "Arc Lecture Transcriber needs macOS 14.2 or later. (This Mac: macOS $ver)"
  say "${where_ko}에서 macOS를 업데이트(무료)한 뒤 이 명령을 다시 실행해 주세요." "Update macOS (free) in $where_en, then run this command again."
  exit 1
fi
if [ "$major" -lt 26 ]; then                    # every Apple Silicon Mac can update to the latest macOS, free
  say "이 Mac의 macOS($ver)에서는 예전 Apple 음성 인식으로 받아 적어서 잘 동작하지 않을 수 있어요. 더 정확하게 받아 적으려면 ${where_ko}에서 최신 macOS로 업데이트(무료)하세요." \
      "On this Mac's macOS ($ver), the app transcribes with Apple's older speech recognition, which may not work well. For better transcripts, update to the latest macOS (free) in $where_en."
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
say "Arc 강의 받아쓰기 내려받는 중…" "Downloading Arc Lecture Transcriber…"
curl -fL --progress-bar "$URL" -o "$tmp/app.zip"
ditto -x -k "$tmp/app.zip" "$tmp/unzipped"
[ -d "$tmp/unzipped/$APP_NAME" ] || APP_NAME="$OLD_NAME"      # releases before 2.5.1 use the old name
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
[ -d "$HOME/Library/Application Support/LectureScribe/models" ] && \
  say "참고: v1의 AI 모델(570MB)은 이제 필요 없어요. 지우려면: rm -rf ~/Library/Application\\ Support/LectureScribe/models" \
      "Note: v1's AI model (570 MB) isn't needed any more. To delete it: rm -rf ~/Library/Application\\ Support/LectureScribe/models"
[ -n "${LECTURE_NO_OPEN:-}" ] || open "$dest/$APP_NAME"
