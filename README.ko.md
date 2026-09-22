# Unified Usage Monitor

> LANGUAGE: [English](README.md) · **한국어**

Claude · ChatGPT(Codex) · Antigravity의 구독 사용량을 macOS 메뉴막대에서 한번에 확인하세요.

<img src="docs/images/popover-ko-light-captured.png" width="620" alt="게이지 세 개가 있는 팝오버: ChatGPT · Codex, Claude, Antigravity">

## 기본 지원 서비스

Claude, ChatGPT Codex, 그리고 Antigravity를 지원합니다.
매 폴링마다 설치여부를 확인하며, 설치가 감지될 경우 팝오버 및 메뉴막대 UI에 추가됩니다.

| 도구        | 감지 대상                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| Claude Code | 키체인`Claude Code-credentials`, `~/.claude`, `~/.local/share/claude`, `~/.local/bin/claude` |
| Codex       | `~/.codex`, `~/.codex/auth.json`                                                                 |
| Antigravity | 키체인`gemini`/`antigravity`, `~/.gemini/antigravity-cli`, `~/.antigravity`                  |

> 문서화되지 않은 비공개 API를 사용하므로, Claude Code/Codex/Antigravity의 업데이트로 사용량을 불러오지 못할 수 있습니다. 대응되는 업데이트를 항상 개발중이니, 기다려주세요.

## 요구 사항

- macOS 14.0 이상
- Apple Silicon 또는 Intel
- 직접 빌드할 경우: Xcode Command Line Tools — 전체 Xcode는 필요 없습니다

---

## 설치

### 릴리스 앱 다운로드

[Releases](https://github.com/poca-p0ca/UnifiedUsageMonitor/releases)에서 zip을 받아 `UnifiedUsageMonitor.app`을 Finder의 `/응용 프로그램`으로 옮기세요.

- **첫 실행을 Gatekeeper가 막습니다.**
  Apple Developer ID로 공증(notarize)한 앱이 아니라서 `spctl`이 거부합니다.
  `더블클릭 → 경고 닫기 → 시스템 설정 → 개인정보 보호 및 보안`으로 가서 아래쪽의
  "UnifiedUsageMonitor이(가) 차단되었습니다" 줄에서 **그래도 열기**를 누르세요.
  최초 설치시에만 하면 됩니다.

  > macOS 14에서는 앱 우클릭 → 열기로도 됩니다
  >
- **최초 실행시 서비스별로 키체인 접근을 한 번씩 묻습니다. "항상 허용"을 눌러야 합니다.**

  > "허용"을 누르면 매번 다시 묻습니다.
  >

### 직접 빌드해서 사용

Command Line Tools가 필요합니다.

```bash
git clone https://github.com/poca-p0ca/UnifiedUsageMonitor.git
cd UnifiedUsageMonitor
./build-app.sh --install
open /Applications/UnifiedUsageMonitor.app
```

### 로그인 항목에 추가

시스템 설정 → 일반 → 로그인 항목에서 `UnifiedUsageMonitor.app`을 추가하면 macOS를 로그인할때 함께 켜지게됩니다.

---

## 확인되지 않은 빌드는 사용하면 안됩니다.

이 앱은 자격증명을 읽기 때문에, 변조된 클라이언트가 자격증명을 훔칠수 있습니다. 다음 명령어로 해당 빌드에 문제가 없는지 확인할 수 있습니다.

```bash
gh attestation verify 릴리즈압축파일명.zip --repo poca-p0ca/UnifiedUsageMonitor
shasum -a 256 릴리즈압축파일명.zip
```

릴리즈압축파일명.zip에는 본 레포 Release의 zip 파일이름을 넣으시면됩니다.

```bash
codesign -dvvv /Applications/UnifiedUsageMonitor.app   # Authority를 릴리스 노트와 대조
codesign -d -r- /Applications/UnifiedUsageMonitor.app  # designated requirement
```

---

## 라이선스

- [MIT](LICENSE)
- [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)

이 프로젝트는 Anthropic · OpenAI · Google과 아무 관계가 없습니다.
