#!/bin/bash
# Builds a distributable zip of UnifiedUsageMonitor.app plus install notes.
#
# The app is signed with a local certificate, not an Apple Developer ID, so it
# cannot be notarized. Gatekeeper will therefore warn on any other Mac and the
# recipient has to open it once via the context menu — INSTALL.txt says how.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/UnifiedUsageMonitor.app"
DIST="dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="$DIST/UnifiedUsageMonitor-$VERSION.zip"

./build-app.sh

echo "▸ verifying signature"
codesign --verify --strict "$APP"
AUTHORITY="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "  signed by:      ${AUTHORITY:-ad-hoc}"
echo "  architectures:  $(lipo -archs "$APP/Contents/MacOS/UnifiedUsageMonitor")"

rm -rf "$DIST"
mkdir -p "$DIST/UnifiedUsageMonitor"
cp -R "$APP" "$DIST/UnifiedUsageMonitor/"

cat > "$DIST/UnifiedUsageMonitor/INSTALL.txt" <<'NOTE'
Unified Usage Monitor — Install
===============================

Shows how much Claude Code / Codex / Antigravity quota you have left, in the
macOS menu bar. Only the tools it detects are shown; with none installed it
shows nothing. Universal binary: Apple Silicon and Intel, macOS 14 or later.

The interface follows your macOS language (English and Korean), and can be
pinned from the menu bar icon's right-click menu.


1. Verify it
------------
This app reads the logins your CLIs already stored, so it is worth being sure
you got the real file. The release page lists a SHA-256; compare it:

  shasum -a 256 UnifiedUsageMonitor-*.zip

If you have the GitHub CLI, the stronger check is the build attestation —
GitHub's signed statement that this file came from the project's own release
workflow:

  gh attestation verify UnifiedUsageMonitor-*.zip --repo poca-p0ca/UnifiedUsageMonitor

The app does not check itself, on purpose: a modified build would just report
that it is fine.


2. Move the app
---------------
Drag UnifiedUsageMonitor.app into /Applications.


3. First launch — Gatekeeper will block it once
-----------------------------------------------
A double-click is blocked, because this is not notarized with an Apple
Developer ID. To allow it:

  Double-click the app, dismiss the warning, then open
  System Settings -> Privacy & Security, scroll to the bottom, and press
  "Open Anyway" next to UnifiedUsageMonitor.

Only needed once.

On macOS 14 you can instead Control-click the app -> "Open" -> "Open" again.
That shortcut was removed in macOS 15 Sequoia, so on 15 and later use the
System Settings route above.


4. Allow keychain access
------------------------
The app reads the login tokens each tool already stored. macOS asks once per
tool.

  Choose "Always Allow". Plain "Allow" makes it ask again every time.

It never asks for a password or an API key. It uses the sessions those tools
already established, and refreshes them when they lapse — the same thing each
tool's own CLI does when you run it.


5. Start at login (optional)
----------------------------
System Settings -> General -> Login Items & Extensions -> "Open at Login",
press + and add UnifiedUsageMonitor.app.


Using it
--------
  Left click    open the gauge popover
  Right click   refresh - language - open debug logs - quit

The needle points at what is LEFT. It falls toward E as you spend, and turns
red in the danger band.


If something goes wrong
-----------------------
Every raw service response is kept here:

  ~/Library/Logs/UnifiedUsageMonitor/

If a gauge is blank, read monitor.log in that folder first. If it says to sign
in, run that tool once in a terminal.


Worth knowing
-------------
All three usage APIs are private endpoints with no public documentation. If a
service changes one without notice, that gauge stops reading values. The others
keep working.


================================================================================


Unified Usage Monitor — 설치 방법
=================================

Claude Code / Codex / Antigravity 의 남은 사용량을 macOS 메뉴막대에 표시합니다.
설치된 도구만 자동으로 감지해서 띄웁니다. 셋 다 없으면 아무것도 표시하지 않습니다.
유니버설 바이너리라 Apple Silicon 과 Intel 모두에서 동작하고, macOS 14 이상이
필요합니다.

화면 언어는 macOS 언어 설정(영어·한국어)을 따르며, 메뉴막대 아이콘 우클릭 메뉴에서
고정할 수 있습니다.


1. 검증하기
-----------
이 앱은 각 CLI가 저장해둔 로그인을 읽습니다. 받은 파일이 진짜인지 확인할
가치가 있습니다. 릴리스 페이지에 SHA-256 이 적혀 있으니 대조하세요.

  shasum -a 256 UnifiedUsageMonitor-*.zip

GitHub CLI 가 있으면 더 강한 확인이 가능합니다. 이 파일이 프로젝트의 릴리스
워크플로에서 나왔다는 GitHub 의 서명된 진술입니다.

  gh attestation verify UnifiedUsageMonitor-*.zip --repo poca-p0ca/UnifiedUsageMonitor

앱이 자기 자신을 검사하지는 않습니다. 의도한 것으로, 변조된 빌드는 스스로를
정상이라고 보고하면 그만이기 때문입니다.


2. 앱 옮기기
------------
UnifiedUsageMonitor.app 을 /응용 프로그램 (Applications) 으로 드래그하세요.


3. 첫 실행 — Gatekeeper 가 한 번 막습니다
-----------------------------------------
Apple Developer ID 로 공증(notarize)한 앱이 아니라서 더블클릭하면 막힙니다.
허용하려면:

  앱을 더블클릭 → 경고 닫기 → 시스템 설정 → 개인정보 보호 및 보안 으로 가서
  맨 아래 UnifiedUsageMonitor 옆의 "그래도 열기" 를 누르세요.

이 과정은 최초 1회만 필요합니다.

macOS 14 에서는 앱을 Control 키를 누른 채 클릭 → "열기" → 다시 "열기" 로도
됩니다. 다만 그 방법은 macOS 15 Sequoia 에서 제거됐으므로, 15 이상에서는
위의 시스템 설정 경로를 쓰세요.


4. 키체인 접근 허용
-------------------
앱이 각 도구가 이미 저장해둔 로그인 토큰을 읽습니다. 도구마다 한 번씩
macOS 가 접근 허용을 묻습니다.

  반드시 "항상 허용" 을 누르세요. "허용" 을 누르면 매번 다시 묻습니다.

비밀번호나 API 키를 요구하지 않습니다. 이미 로그인된 세션을 쓰고, 만료되면
갱신합니다 — 해당 도구의 CLI 를 실행할 때 일어나는 것과 같은 동작입니다.


5. 로그인 항목에 추가 (선택)
----------------------------
시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램 → "로그인 시 열기" 에서
+ 를 눌러 UnifiedUsageMonitor.app 을 추가하세요.


사용법
------
  좌클릭   게이지 팝오버 열기
  우클릭   새로고침 · 언어 · 디버그 로그 열기 · 종료

바늘은 "남은 양" 을 가리킵니다. 쓸수록 E 쪽으로 떨어지고, 위험 수준에
들어가면 빨갛게 바뀝니다.


문제가 생기면
-------------
각 서비스의 원본 응답이 아래에 그대로 남습니다.

  ~/Library/Logs/UnifiedUsageMonitor/

게이지가 비어 있으면 그 폴더의 monitor.log 를 먼저 확인하세요.
"로그인 필요" 가 뜨면 해당 도구를 터미널에서 한 번 실행해 로그인하면 됩니다.


알아두실 점
-----------
사용량 API 는 세 곳 모두 공식 문서에 없는 비공개 엔드포인트입니다.
서비스 쪽에서 예고 없이 바꾸면 해당 게이지만 값을 못 읽게 됩니다.
그 경우에도 나머지 게이지는 정상 동작합니다.
NOTE

cp LICENSE "$DIST/UnifiedUsageMonitor/LICENSE.txt"

echo "▸ zipping"
mkdir -p "$DIST"
# ditto preserves the code signature; `zip` does not.
ditto -c -k --sequesterRsrc --keepParent "$DIST/UnifiedUsageMonitor" "$ZIP"
rm -rf "$DIST/UnifiedUsageMonitor"

echo "✓ $ZIP  ($(du -h "$ZIP" | cut -f1))"
