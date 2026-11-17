# mtgrec

맥에서 회의를 로컬 녹음하고 온디바이스로 전사한 뒤, 요약을 만들어 Notion 회의록 페이지로 올리는 Claude Code 플러그인입니다.

| 단계 | 하는 일 |
|------|------|
| 녹음 | 마이크(나)와 시스템 오디오(상대)를 별도 트랙으로 녹음. 회의 앱(Meet · Teams · Zoom)에 상관없음 |
| 실시간 노트 | `127.0.0.1` 페이지에 실시간 전사와 논의 묶음 노트가 뜸. 상대 트랙이 60초 무음이면 경고 |
| 전사 | Apple SpeechTranscriber(ko-KR), 온디바이스 |
| 용어 보정 | 용어집의 치환표 + 문맥 판단으로 고유명사 오인식 교정 |
| 요약 | `회의 결론` · `논의 내용`(중요도 순 안건 카드) · `액션플랜` 3절 |
| Notion | 지정한 데이터베이스에 회의록 페이지 생성 (선택) |

## 요구 사항

| 항목 | 값 |
|------|------|
| macOS | 26 이상, Apple Silicon |
| Swift | 6.2 이상 (`xcode-select --install` 또는 Xcode 26) |
| Claude Code | CLI 설치 (`claude` 가 PATH 에 있어야 실시간 노트와 용어 보정이 동작) |
| Notion | Claude 에 Notion 커넥터 연결 (Notion 을 안 쓰면 불필요) |
| Google Calendar | 선택. 연결돼 있으면 일정 제목과 참석자로 회의록 제목을 만듦 |

## 설치

Claude Code 에서:

```
/plugin marketplace add jmwoo-amf/mtgrec
/plugin install rec@mtgrec
```

private 저장소이므로 GitHub 에 이 저장소 접근 권한이 있어야 합니다 (`gh auth status` 로 확인).

그다음 설정 마법사를 실행합니다. 플러그인 스킬이라 명령이 `/rec:rec` 으로 보일 수 있습니다. "rec 설정해줘" 라고 말해도 됩니다.

```
/rec setup
```

환경 확인 → 저장 위치 · Notion DB · 회의록 제목 · 참석자 규칙 · 용어집 질문 → `~/.config/mtgrec/config.json` 작성 → 빌드 → 10초 시험 녹음 순서로 진행합니다. 처음 녹음할 때 macOS 가 마이크와 시스템 오디오 녹음 권한을 묻습니다.

## 사용

| 명령 | 동작 |
|------|------|
| `/rec start [제목]` | 녹음 시작. 실시간 페이지 주소를 알려줌 |
| `/rec stop` | 종료 → 전사 → 용어 보정 → 요약 → Notion 페이지 |
| `/rec` | 상태 |
| `/rec summary [세션]` | 요약 다시 만들기 |
| `/rec correct [세션]` | 용어집을 고친 뒤 보정만 다시 |
| `/rec clean --days 14` | 전사 끝난 세션의 오디오 삭제 |
| `/rec setup` | 설정 변경 |

자연어로 "녹음 시작해줘", "녹음 끝" 이라고 해도 됩니다.

## 자리별 옵션

| 자리 | 옵션 |
|------|------|
| 원격 회의, 헤드폰 | 없음 (기본) |
| 원격 회의, 소리는 옆 사람 장비로 들음 | `--mute` |
| 대면 회의, 내 맥은 회의에 안 붙음 | `--mic-only` (화자 구분 없음) |
| 듣기만 하고 내 목소리는 남기지 않음 | `--sys-only` |

## 데이터가 어디로 가는가

| 데이터 | 위치 |
|------|------|
| 오디오 | 맥 안에만 있음. 외부로 보내지 않음 |
| 전사 텍스트 | 실시간 노트 · 용어 보정 · 요약 때 Claude 에 전달됨. 원하지 않으면 `--no-live` 로 시작하고 보정은 `--no-correct` |
| 요약 | 터미널, 세션 폴더의 `summary.draft.md`, 설정한 Notion DB |

회의 참석자에게 녹음 사실을 알리십시오.

## 설정 파일

| 파일 | 내용 |
|------|------|
| `~/.config/mtgrec/config.json` | 저장 위치, Notion DB와 속성, 제목 형식, 참석자 규칙, 문체 파일, 회의 후 안내 |
| `~/.config/mtgrec/vocabulary.json` | 용어집 (`terms` · `replacements` · `glossary`) |

필드 정의는 `plugins/rec/skills/rec/references/setup.md`, 예시는 같은 폴더의 `config.example.json` 입니다. `~/.claude/bin/mtgrec config` 로 지금 실제로 읽는 파일을 확인할 수 있습니다.

## 업데이트

```
/plugin update rec@mtgrec
```

Swift 코드가 바뀐 버전이면 `/rec setup` 의 빌드 단계(또는 스킬 폴더의 `tools/build.sh`)를 다시 실행합니다.
