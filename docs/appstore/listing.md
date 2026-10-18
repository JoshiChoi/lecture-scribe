# App Store Connect — Arc 강의 받아쓰기 (copy & paste)

| Field | Value |
|---|---|
| Name | Arc 강의 받아쓰기 |
| Subtitle | 한 마디도 놓치지 않는 실시간 받아쓰기 |
| Name (English localization) | Arc Lecture Transcriber |
| Subtitle (English) | Every word, live and on-device |
| Bundle ID | io.github.joshichoi.lecture-scribe |
| SKU | lecture-scribe-mac |
| Primary language | Korean |
| Category | Productivity (secondary: Education) |
| Price | Free |
| Age rating | 4+ (answer "No/None" to every question) |
| Copyright | 2026 Jun Hyuk Choi |
| Support URL | https://github.com/WeldingArc/arc-lecture-transcriber/issues |
| Marketing URL | https://github.com/WeldingArc/arc-lecture-transcriber |
| Privacy Policy URL | https://github.com/WeldingArc/arc-lecture-transcriber/blob/main/PRIVACY.md |
| App Privacy | Data Not Collected |
| Encryption | No (ITSAppUsesNonExemptEncryption = NO in Info.plist) |
| Marketing screenshots (2880×1800, upload these) | Korean store: docs/appstore/marketing/ko/01-live.jpg, 02-key-sentences.jpg, 03-slides.jpg, 04-library.jpg, 05-find.jpg, 06-privacy.jpg, 07-languages.jpg, 08-lecture-languages.jpg · English store: the same names in docs/appstore/marketing/en/ (the English screens; a headline and a line of pitch over each; re-render with `tools/make_marketing.sh`) |
| Screenshots (2880×1800), plain app screens | docs/appstore/screenshots/2.6.0/ko/ (Korean store) and docs/appstore/screenshots/2.6.0/en/ (English store): 01-start, 02-live, 03-library, 04-playback, 05-saved, 06-slide-pdf, 07-settings, 08-language, 09-lecture-languages (render: tools/shot.swift; demo data only) |

## Promotional text
강의를 틀고 시작만 누르면 됩니다. Mac 안에서 바로 받아 적고, 강의마다 녹음과 글을 ‘기록’에 모아 줍니다. 소리와 글은 Mac 밖으로 나가지 않습니다.

## Keywords
받아쓰기,강의,녹취,음성인식,필기,녹음,슬라이드,STT,강의노트,다국어,자막

## Description
Arc 강의 받아쓰기는 Mac에서 재생되는 온라인 강의의 내용을 실시간으로 받아 적어 주는 앱입니다. 강의 자료가 없어도 괜찮습니다 — 슬라이드가 넘어갈 때마다 화면을 담아, 그때 한 말과 함께 PDF 노트로 만들어 줍니다.

■ 사용 방법
학교 강의 영상·유튜브·줌 등으로 강의를 틀고 [시작]만 누르면, Mac에서 나오는 소리를 그대로 받아 문장 단위로 받아 적습니다. 마이크를 사용하지 않으므로 이어폰을 껴도, 주변이 시끄러워도 괜찮습니다.

■ 슬라이드 PDF — 강의 노트를 자동으로
• 슬라이드가 바뀔 때마다 한 장씩 담아, 그동안 한 말과 함께 PDF로 정리합니다 (담을 강의 창은 직접 선택합니다)
• 깔끔하게 담기 — 주소창·플레이어·검은 여백은 빼고 슬라이드만 담습니다
• 강의자 카메라는 스스로 찾아 테두리로 표시하고 슬라이드 인식에서 제외합니다
• 슬라이드마다 화면에서 읽은 제목과 책갈피가 붙어, 원하는 장으로 바로 이동할 수 있습니다
• 슬라이드에 적힌 글자도 PDF에 담겨, 검색하고 복사할 수 있습니다
• PDF 형식은 가로 · 두 파일 · A4 한 쪽 중에서 고릅니다
• 받아 적는 동안 PDF에 담기는 부분을 빨간 테두리로 바로 보여 줍니다

■ 주요 기능
• 실시간 받아쓰기
• 기록 — 강의마다 녹음과 받아 적은 글이 한곳에. 문장을 누르면 그 부분부터 다시 들려줍니다
• ‘중요 문장’은 기록 맨 위에 모아 보여 주고, 기록마다 보이는 버튼으로 이름 변경·삭제를 바로 할 수 있습니다
• ⌘F로 기록 안에서 단어를 찾고, 잘못 들린 단어는 [글 편집]으로 바로 고칩니다
• 쉬는 시간에는 [일시정지] — 그동안의 소리는 녹음하지 않고, [계속]을 누르면 이어서 받아 적습니다
• 텍스트(.txt)와 녹음(.m4a)은 다운로드 폴더의 ‘강의기록’에도 그대로 저장됩니다
• 1.5배·2배속 재생도 따라갑니다
• [전체 복사] 한 번으로 받아 적은 글 전체를 복사
• 영어로 말하는 부분은 영어 그대로 적습니다 (일부러 번역하지 않습니다)
• 여러 강의 언어 — 한국어 · English 외에도 日本語 · 中文 · 粵語 · Español · Français · Deutsch · Italiano · Português · Русский · Tiếng Việt 등 Apple 음성 인식이 이 Mac에서 지원하는 언어의 강의를 받아 적습니다 (‘다른 언어’에서 검색해 고르고, 모델이 Mac에 없는 언어는 크기를 먼저 알려 준 뒤 Apple의 음성 인식 모델을 내려받습니다)
• Mac에 들어 있는 Apple 음성 인식으로 받아 적습니다 (원하면 설정에서 다른 받아쓰기 엔진을 추가로 고를 수도 있습니다)
• 중요 문장 표시 — ‘출석’, ‘시험’, ‘과제’ 같은 단어가 나온 문장에 밑줄을 긋고 파일 끝에 따로 모아 줍니다. 단어는 직접 바꿀 수 있습니다
• 녹음·영상 파일을 끌어다 놓아도 받아 적습니다 (재생 시간보다 훨씬 빨리)
• 12개 언어 화면 — 한국어 · English · 简体中文 · 繁體中文 · 日本語 · Español · Français · Deutsch · Português (Brasil) · Italiano · Tiếng Việt · Русский (Mac의 언어를 따르며 — 지원하지 않는 언어이면 영어 — 첫 화면의 지구본이나 설정에서 바꿉니다)

■ 개인정보
음성 인식은 Apple의 온디바이스 음성 인식으로 Mac 안에서만 처리됩니다. 소리와 글은 어디에도 전송되지 않고, 계정도 필요 없습니다.

■ 참고 사항
• macOS 14.2 이상, Apple Silicon(M1 이상) Mac — macOS 26 이상 권장(그 이전 macOS에서는 Apple의 예전 음성 인식으로 받아 적습니다)
• 처음 [시작]을 누를 때 ‘시스템 오디오 녹음’ 권한을 허용하십시오(macOS 26 이전에서는 ‘음성 인식’ 권한도)

■ 이용 안내 및 면책
Arc 강의 받아쓰기는 개인 학습을 돕기 위한 도구입니다.
• 녹음하거나 받아 적은 강의, 슬라이드, 녹취록의 저작권은 강의자와 학교 등 원저작권자에게 있습니다.
• 녹음 파일, 녹취록, 슬라이드 PDF는 본인의 학습 용도로만 사용하십시오. 다른 사람에게 공유·배포하거나 인터넷에 게시하면 저작권 침해가 될 수 있습니다.
• 녹음하기 전에 해당 수업의 녹음·녹화 규정과 강의자의 방침을 확인하십시오.
• 앱 사용으로 발생하는 모든 법적 책임은 사용자 본인에게 있으며, 개발자는 이에 대해 책임지지 않습니다.
• 음성 인식 결과에는 오류가 있을 수 있습니다. 중요한 내용은 원래 강의에서 확인하십시오.
• 처음 실행할 때 이 내용에 동의해야 사용할 수 있으며, 설정에서 다시 볼 수 있습니다.

오픈소스(MIT)입니다: https://github.com/WeldingArc/arc-lecture-transcriber

## Promotional text (English localization)
Play a lecture and press Start. Arc Lecture Transcriber writes it down live, right on your Mac, and keeps each lecture's recording and transcript in your Library. Nothing leaves your Mac.

## Keywords (English localization)
transcribe,lecture,notes,speech to text,captions,student,recording,dictation,class,study,STT

## Description (English localization)
Arc Lecture Transcriber writes down the speech of the online lectures your Mac plays, in real time.

■ How it works
Play a lecture in LearnUs, YouTube, Zoom or any other app and press Start. The app takes the sound your Mac is playing and writes it down sentence by sentence. It doesn't use the microphone, so earphones and a noisy room are fine.

■ Features
• Live transcription — words appear as they are spoken
• Library — each lecture's recording and transcript in one place; click a sentence to hear it again from there
• Key Sentences — sentences with words such as "attendance", "exam" or "assignment" are underlined and collected at the top; choose your own key words
• Find words in a recording with ⌘F, and fix misheard words in place with Edit Text
• Pause during breaks — nothing is recorded meanwhile, and Resume carries on
• The text (.txt) and the recording (.m4a) are also saved in a folder in your Downloads
• Keeps up with lectures played at 1.5× or 2×
• Copy All copies the whole transcript in one click
• Nothing is translated on purpose — in a Korean lecture English stays English, and in an English lecture Korean stays Korean once the Korean model is on your Mac
• Many lecture languages — besides Korean and English, lectures in Japanese, Chinese, Cantonese, Spanish, French, German, Italian, Portuguese, Russian, Vietnamese and every other language Apple's speech recognition offers on your Mac (search the list under Other; for a language whose model isn't on your Mac, the app shows the size first, then downloads Apple's speech model)
• Transcribes with the speech recognition built into macOS (other on-device engines can be added in Settings, if you like)
• Drop an audio or video file onto the window to transcribe it, much faster than real time
• Slide PDF — when there are no lecture notes, the slides are collected each time they change, with what was said, into a PDF (you choose the lecture window). The lecturer's camera is found and left out of slide detection, and Clean Capture keeps only the slide — no browser bar, player or black borders. Choose a Landscape, Two Files or A4 layout; every slide gets the title read from the screen and a bookmark, and the slides' text goes into the PDF too, so you can search and copy it
• 12 interface languages — 한국어 · English · 简体中文 · 繁體中文 · 日本語 · Español · Français · Deutsch · Português (Brasil) · Italiano · Tiếng Việt · Русский; it follows your Mac's language and the globe on the start screen switches it

■ Privacy
Speech recognition runs on your Mac with Apple's on-device speech recognition. Sound and text are never sent anywhere, and no account is needed.

■ Notes
• macOS 14.2 or later, Mac with Apple silicon (M1 or later) — macOS 26 or later recommended (before it, the app uses Apple's older speech recognition)
• The first time you press Start, allow "System Audio Recording" (before macOS 26, "Speech Recognition" too)

■ Usage notice and disclaimer
Arc Lecture Transcriber is a tool to support personal study.
• Recorded lectures, slides and transcripts remain the copyright of the lecturer, the school and other rights holders.
• Use recordings, transcripts and slide PDFs only for your own study. Sharing or distributing them, or posting them online, may infringe copyright.
• Before recording, check the course's rules on recording and the lecturer's policy.
• You bear all legal responsibility for your use of the app; the developer accepts no liability.
• Speech recognition can make mistakes. Check important points against the lecture itself.
• You agree to this notice the first time you open the app, and can read it again in Settings.

Open source (MIT): https://github.com/WeldingArc/arc-lecture-transcriber

## What's New (2.7)
• 슬라이드 PDF에 슬라이드의 글자도 담깁니다 — Mac 안에서 읽어 넣으므로 PDF에서 검색하고 복사할 수 있습니다(슬라이드 모양은 그대로)
• 이제 macOS 14.2 이상의 모든 Apple Silicon Mac에서 쓸 수 있습니다. macOS 26 이전에서는 Apple의 예전 음성 인식으로 받아 적어서 잘 동작하지 않을 수 있어, 앱이 최신 macOS로 업데이트하도록 안내합니다. 받아 적을 수 없을 때도 강의는 녹음되며, 그 이유와 방법을 알려 줍니다
• 강의가 재생되는데도 Mac의 소리가 무음으로만 들어와 받아쓰기가 도중에 멈추던 문제를 고쳤습니다(macOS 26, AirPods 등) — 이제 앱이 알아차리고 소리를 다시 받아 옵니다
• 슬라이드 PDF를 켜고 녹음하는 중 창을 가렸다가 다시 볼 때 미리 보기가 깨져 보이던 문제를 고쳤습니다

## What's New (2.7, English localization)
• The Slide PDF now carries the slides' text too — read on your Mac, so you can search and copy it in the PDF (the slides look the same)
• Now runs on every Apple silicon Mac with macOS 14.2 or later. Before macOS 26 it transcribes with Apple's older speech recognition, which may not work as well, so the app recommends updating to the latest macOS. When it can't transcribe, the lecture is still recorded and the app says why and what to do
• Fixed transcripts that stopped partway because the Mac's sound came in as silence while the lecture played on (macOS 26, e.g. with AirPods) — the app now notices and gets the sound back
• Fixed the live preview looking broken after hiding the window during a Slide PDF recording

## What's New (2.6)
• 여러 강의 언어 — 시작 버튼 아래의 강의 언어에 ‘다른 언어’가 생겼습니다. 日本語 · 简体中文 · 繁體中文 · 粵語 · Español · Français · Deutsch · Italiano · Português · Русский · Tiếng Việt · हिन्दी · العربية 등 Apple 음성 인식이 이 Mac에서 지원하는 언어(macOS 27에서는 49개)를 검색해 고를 수 있습니다
• 모델이 Mac에 없는 언어는 크기를 먼저 알려 주고(약 350MB~1.1GB), 허락하면 Apple 음성 인식 모델을 내려받습니다. 진행 상황은 첫 화면에 보이며, 녹음 중에 바꾸면 다음 녹음부터 적용됩니다
• Apple 받아쓰기 모델이 받아 적는 언어(러시아어 · 베트남어 등)는 문장 부호가 빠질 수 있습니다 — 고를 때 알려 줍니다
• 중국어 · 일본어 강의는 그 언어의 글꼴과 줄바꿈 규칙으로 보여 주고(슬라이드 PDF도 같은 글꼴), 아랍어 · 히브리어 등은 오른쪽에서 왼쪽으로 보여 줍니다
• 한국어 강의는 지금처럼 영어로 하는 말도 영어로 적고, 영어 강의는 Mac에 한국어 모델이 있으면 한국어로 하는 말도 한국어로 적습니다. 이미 고른 강의 언어는 그대로 유지됩니다

## What's New (2.6, English localization)
• Many lecture languages — the lecture-language switch under the start button now has Other: search and choose any language Apple's speech recognition offers on your Mac (49 on macOS 27), such as Japanese, Chinese, Cantonese, Spanish, French, German, Italian, Portuguese, Russian, Vietnamese, Hindi and Arabic
• For a language whose model isn't on your Mac, the app shows the size first (about 350 MB to 1.1 GB) and downloads Apple's speech model if you agree; the start screen shows the progress, and a change made while recording applies from the next recording
• Languages written by Apple's dictation model (Russian, Vietnamese and others) may lack punctuation — the app says so when you choose one
• Chinese and Japanese lectures use their own fonts and line breaking (the Slide PDF uses the same fonts), and Arabic, Hebrew and others read right to left
• A Korean lecture still keeps English in English, and an English lecture keeps Korean in Korean once the Korean model is on your Mac; a lecture language you chose before stays

## What's New (2.5.1)
• 새 이름 — Arc 강의 받아쓰기 (Arc Lecture Transcriber). 기능은 2.5와 같습니다

## What's New (2.5.1, English localization)
• New name — Arc Lecture Transcriber (Arc 강의 받아쓰기). Same features as 2.5

## What's New (2.5)
• 12개 언어 화면 — 한국어 · English에 简体中文 · 繁體中文 · 日本語 · Español · Français · Deutsch · Português (Brasil) · Italiano · Tiếng Việt · Русский가 더해졌습니다. 화면·메뉴·알림·PDF가 그 언어로 바뀌고, 권한 안내도 12개 언어로 준비되어 있습니다(macOS가 표시하므로 Mac의 언어 설정을 따릅니다). 강의 언어는 지금처럼 한국어 · English입니다
• 처음에는 Mac의 언어를 따릅니다 (지원하지 않는 언어이면 영어). 첫 화면 왼쪽 위의 지구본이나 설정 › 언어에서 고른 언어는 그대로 유지됩니다 (2.4에서 고른 언어는 이어지지 않으니 필요하면 다시 고르십시오)
• 2.4에서는 이전 버전을 쓰던 Mac이면 화면이 한국어로 고정되었습니다 — 이제 직접 고르기 전까지는 Mac의 언어를 따릅니다

## What's New (2.5, English localization)
• 12 interface languages — Simplified Chinese, Traditional Chinese, Japanese, Spanish, French, German, Portuguese (Brazil), Italian, Vietnamese and Russian join Korean and English: screens, menus, notices and PDFs; the permission prompts are translated too (macOS shows them, following the Mac's language settings). The lecture language is still Korean or English
• The app starts in your Mac's language (English for any language it doesn't speak); a language picked with the globe on the start screen or in Settings › Language stays (a choice made in 2.4 isn't carried over — pick it again if needed)
• In 2.4 the app stayed in Korean on Macs that had used an earlier version; it now follows the Mac's language until you choose one

## What's New (2.4)
• 영어 화면 — 화면·메뉴·알림·PDF까지 앱 전체를 영어로도 쓸 수 있습니다. 처음에는 Mac의 언어를 따르며, 첫 화면 왼쪽 위의 지구본이나 설정 › 언어에서 바꿉니다
• 슬라이드 PDF 형식 선택(설정 › PDF 형식): 가로(슬라이드가 한 쪽을 가득 채우고 다음 쪽에 그때 한 말) · 두 파일(슬라이드 PDF와 받아쓰기 PDF) · A4 한 쪽(이전 방식)
• 슬라이드마다 화면에서 읽은 제목을 붙이고, PDF 책갈피로 원하는 슬라이드로 바로 이동합니다 (제목 읽기도 Mac 안에서 처리됩니다)
• 깔끔하게 담기 — 주소창·플레이어·검은 여백처럼 그대로인 부분은 빼고, 슬라이드가 넘어갈 때 바뀌는 부분을 찾아 그 영역을 PDF에 담습니다 (기본으로 켜짐, 받아 적는 화면에서 바로 켜고 끔)
• 받아 적는 화면 — 강의 화면을 크게 보는 ‘화면’과 글을 크게 보는 ‘글’ 중에서 고릅니다. PDF에 담기는 부분은 빨간 테두리, 강의자 카메라는 흰 테두리로 보이고, 슬라이드를 담을 때마다 스크린샷처럼 반짝입니다
• 좁은 화면에서 기록의 긴 제목이 잘리지 않고 줄바꿈됩니다

## What's New (2.4, English localization)
• English interface — the whole app (screens, menus, notices and PDFs) is now available in English. It follows your Mac's language at first; switch it with the globe at the top left of the start screen or in Settings › Language
• Choose the slide PDF layout (Settings › PDF Layout): Landscape (each slide fills a page, with what was said on the next) · Two Files (a slides PDF and a transcript PDF) · A4 Page (the earlier layout)
• Each slide is named with the title read from the slide, and PDF bookmarks take you straight to any slide (titles are read on your Mac)
• Clean capture — parts that never change (the address bar, the player, black borders) stay out of the PDF; the app finds the part that changes when the slide turns and keeps that (on by default; switch it on the recording screen)
• See it working — choose Screen (the lecture window large) or Text (the transcript large) while recording; what goes into the PDF is outlined in red, the lecturer's camera in white, and each slide taken flashes like a screenshot
• Long recording names wrap instead of being cut off on narrow screens

## What's New (2.3)
• 기록마다 이름 변경·삭제 버튼이 바로 보입니다 (⋯ 또는 우클릭으로 공유)
• 일시정지 / 계속 — 쉬는 시간의 소리는 녹음하지 않습니다 (⌘P)
• 글 편집 — 잘못 들린 단어를 기록에서 바로 고칩니다
• ⌘F로 기록 안에서 찾기
• ‘녹음’ 메뉴와 단축키: ⌘R 시작·정지, ⌘O 파일 불러오기
• 녹음 중에 종료하거나 창을 닫으면 먼저 확인하고, 종료하더라도 지금까지의 내용을 저장합니다
• 슬라이드 PDF: 강의자 카메라를 스스로 찾아 표시하고 슬라이드 인식에서 제외합니다 (카메라 때문에 같은 슬라이드가 여러 장 담기던 문제를 줄였습니다)

## What's New (2.2)
• 앱 전체의 문구를 격식 있는 표현으로 다듬었습니다
• 처음 실행할 때 이용 안내 및 면책 고지를 표시합니다(설정 › 정보에서 다시 볼 수 있습니다)

## What's New (2.1)
• 강의 언어를 선택할 수 있습니다 — 한국어 / English (시작 버튼 아래)
• 새 음성 인식 엔진(선택, 내려받기): Qwen3-ASR — 한국어와 영어가 섞인 강의, 억양이 강한 영어에 가장 정확합니다 · Parakeet — 영어 강의 전용, 빠르고 가볍습니다
• 영어로 말하는 강의를 한국어 강의로 받아 적을 때 단어가 두 번씩 적히던 문제를 수정했습니다
• 한국어 문장 사이의 영어 인용을 더 많이, 제자리에 받아 적습니다
• 슬라이드 PDF 설명 애니메이션이 더 빨라졌습니다
• 첫 화면이 앱이 하는 일을 그림으로 보여 줍니다

## What's New (2.0)
• Apple 온디바이스 음성 인식으로 새로 만들었습니다 — AI 모델을 따로 내려받을 필요가 없습니다
• 새로운 ‘기록’ — 강의마다 녹음과 받아 적은 글을 한곳에서 보고 들을 수 있습니다
• 슬라이드 PDF — 슬라이드를 자동으로 모아 한 말과 함께 PDF로
• 말하는 대로 글자가 바로 나타납니다
• 영어 구간은 영어 그대로 받아 적습니다

## Notes for App Review (English)
Arc Lecture Transcriber transcribes the audio that is playing on the Mac (e.g. an online lecture in a browser) in real time, entirely on-device, using Apple's SpeechAnalyzer (SpeechTranscriber, or DictationTranscriber for languages it doesn't offer). Optionally (Settings › Speech Recognition) the user can download an open speech model — Whisper large-v3-turbo (about 575 MB), Qwen3-ASR 1.7B (about 1.5 GB) or Parakeet 0.6B (English only, about 540 MB), from huggingface.co — and transcribe with it instead, also entirely on-device. The main screen's lecture-language switch (Korean / English / Other) sets the lecture's language: Other lists every language Apple's on-device recognizers offer; choosing one whose model isn't on the Mac asks first (with the size), then the model downloads through AssetInventory. The interface is in 12 languages: it follows the Mac's language (English for any other), and the globe at the top left of the start screen (or Settings › Language) switches it. No account, no server, no network use for content.

How to test:
1. Launch the app. On first launch a usage notice and disclaimer appears (personal study use only; lectures stay their owners' copyright; transcripts can contain errors) — click "Agree and Start"; Settings › About reopens it. Then wait for "Ready".
2. Play any video with speech in Safari or another app. The lecture language starts as the Mac's language (English on an English Mac); for another language, choose it first (Korean, or one under Other) and allow its model download.
3. Click the round Start button. macOS asks for "System Audio Recording" permission (NSAudioCaptureUsageDescription) — allow it.
4. Text appears live. Click it again (Stop): a .txt transcript and .m4a recording are saved to ~/Downloads/Lecture Transcriber (or ~/Downloads/강의기록). "Copy All" (전체 복사) copies the whole transcript.
5. "Library" (기록) lists every session; open one to see its transcript with the recording — click any sentence to play from there.
6. You can also drag an audio/video file onto the window (or use Open File… / 파일 불러오기) to transcribe it.
7. Optional: Settings (⌘,) › Speech Recognition › Whisper, Qwen3-ASR or Parakeet › "Download · …MB" downloads that model (checked against its SHA-256); it is then selected, and the next recording uses it. "Delete" removes it again. (Parakeet is English only, and the optional engines write Korean and English lectures: otherwise the app uses Apple's recognizer and says so.)
8. Optional "Slide PDF" (슬라이드 PDF) checkbox: when recording starts, macOS's content-sharing picker (SCContentSharingPicker) asks which window to watch; the app captures only that window, about twice a second, to detect slide changes and builds a PDF of the slides with the transcript. Nothing leaves the Mac, and no Screen Recording permission is requested. Settings › PDF Layout chooses Landscape, Two Files or A4 Page; each slide's title is read on-device with Vision text recognition. "Clean Capture" (on by default) crops each page to the slide, found on the Mac from which pixels change between captured slides.

Entitlements:
- com.apple.security.device.audio-input: required to read the Core Audio process tap (AudioHardwareCreateProcessTap) that captures the system's audio output. The app never opens the microphone.
- com.apple.security.files.downloads.read-write: saves transcripts and recordings to ~/Downloads/Lecture Transcriber (or ~/Downloads/강의기록).
- com.apple.security.files.user-selected.read-only: reads a file the user picks or drops to transcribe it.
- com.apple.security.network.client: for the WKWebView that renders the app's local interface, and the optional, user-initiated download of speech model files (Whisper, Qwen3-ASR, Parakeet) from huggingface.co (plain HTTPS GET). No user data is sent.
