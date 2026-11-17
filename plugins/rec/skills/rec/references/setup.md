# `/rec setup`

설정 파일 `~/.config/mtgrec/config.json` 과 용어집을 만들고, `mtgrec` 을 빌드하고, 짧은 녹음으로 끝까지 도는지 확인한다. 처음 설치할 때, 그리고 설정을 바꾸고 싶을 때 쓴다.

질문은 `AskUserQuestion` 으로 묶어서 낸다. 한 번에 4개까지다. 기본값이 있는 것은 기본값을 첫 선택지로 둔다.

## 1. 환경 확인

아래를 한 번에 돌리고 표로 보여준다. **하나라도 막히면 그 자리에서 멈추고 해결 방법을 적는다.**

```bash
sw_vers -productVersion; uname -m; swift --version 2>&1 | head -1; command -v claude
```

| 항목 | 요구 | 막혔을 때 |
|------|------|------|
| macOS | 26 이상 | 전사에 쓰는 SpeechTranscriber 가 macOS 26 부터 있다. 업데이트 말고는 방법이 없다 |
| CPU | `arm64` | Intel 맥은 확인하지 않았다. 빌드는 될 수 있으나 보장하지 않는다고 알린다 |
| Swift | 6.2 이상 | `xcode-select --install` 또는 Xcode 26 설치 |
| `claude` | 경로가 나옴 | 라이브 요약과 용어 보정이 헤드리스 `claude` 를 부른다. 없으면 두 기능만 꺼지고 녹음 · 전사는 된다 |

커넥터도 확인한다.

| 커넥터 | 확인 | 없을 때 |
|------|------|------|
| Notion | `notion-get-self` 가 응답한다 | `notion.enabled: false` 로 간다. 요약은 터미널과 `summary.draft.md` 로만 남는다 |
| Google Calendar | 일정 조회 도구가 목록에 있다 | 세션 이름은 「수시 논의」, 참석자 칸은 `attendees.fallback` 으로 간다 |

## 2. 기존 설정과 preset

`~/.config/mtgrec/config.json` 이 이미 있으면 내용을 표로 보여주고 **어느 부분을 바꿀지 묻는다.** 고르지 않은 필드는 건드리지 않는다. 처음부터 다시 묻지 않는다.

이 스킬 아래에 `presets/{이름}/config.json` 이 있으면 그것으로 시작할지 묻는다. preset 을 고르면 그 파일을 복사한 뒤 3절에서 `owner` 와 Notion 사람 속성만 다시 묻는다. 나머지는 팀 공통값이다.

## 3. 질문

### 3-1. 기본

| 질문 | 기본값 | 들어가는 곳 |
|------|------|------|
| 녹음 저장 위치 | `~/Recordings/mtgrec` | `storage` |
| 이름 (회의록 작성자로 쓴다) | `notion-get-self` 의 이름 | `owner` |
| 본인 이메일 (캘린더 참석자에서 나를 가리고 회사 도메인을 정한다) | `notion-get-self` 의 이메일. 없으면 묻기만 한다 | `email` |
| 회의록을 Notion 에 올릴지 | 커넥터가 있으면 예 | `notion.enabled` |

저장 위치는 오디오가 쌓이는 곳이다. 1시간 회의 2트랙이 약 230MB 다. iCloud 동기화 폴더(`~/Documents`, `~/Desktop`)는 피하라고 한 줄 덧붙인다.

### 3-2. Notion

`notion.enabled` 가 참일 때만 묻는다.

| 선택 | 처리 |
|------|------|
| 기존 데이터베이스에 올린다 | 이름을 받아 `notion-search` 로 찾고, `notion-fetch` 로 `collection://` URL 과 스키마를 읽는다. title 속성이 무엇인지 확인한다 |
| 새로 만든다 | 부모 페이지를 받아(없으면 개인 페이지) `notion-create-database` 로 만든다. 스키마는 아래 |

새로 만들 때의 스키마.

```sql
CREATE TABLE ("제목" TITLE, "태그" MULTI_SELECT('회의록':blue), "상태" STATUS('시작 전':gray:to_do, '검토 중':blue:in_progress, '완료':green:complete), "작성자" PEOPLE)
```

그다음 고정 속성을 정한다. 스키마의 속성마다 **페이지를 만들 때 늘 같은 값인지, 내용을 보고 정할 것인지, 비워 둘 것인지** 를 묻는다.

| 답 | 들어가는 곳 | 값 형식 |
|------|------|------|
| 늘 같은 값 | `notion.properties` | multi_select 는 배열(`["회의록"]`), select · status 는 문자열, person 은 user id 배열 |
| 내용으로 판정 | `notion.inferred` | 판정 지시 한 문장. 옵션이 정해진 속성이면 「옵션 중에서만 고른다」를 넣는다 |
| 비워 둠 | 넣지 않는다 | |

person 속성(작성자 · Owner)은 `notion-get-self` 의 user id 를 기본값으로 둔다. 다른 사람이면 `notion-search` 의 `query_type: "user"` 로 찾는다.

아이콘은 기본 `📝` 이다. 원하지 않으면 빈 문자열로 둔다.

### 3-3. 회의록 제목과 참석자

| 질문 | 기본값 | 들어가는 곳 |
|------|------|------|
| 제목 형식 | `[{date} {time}] {attendees} \| {topic}` | `title.format` |
| 캘린더 일정 제목에서 뗄 접두어 | 맨 앞 대괄호 묶음 | `title.calendarPrefixPattern` |
| 회사 메일 도메인 | `email` 의 도메인 | `attendees.internalDomains` |
| 내부 회의일 때 참석자 칸 | `내부` | `attendees.fallback` |

**역할 그룹은 원하는 사람만 설정한다.** 「내부 회의의 참석자 칸을 구성원 역할로 가르고 싶은가」 를 묻고, 아니면 `people` · `groups` 를 비운다. 그러면 내부 회의는 늘 `fallback` 이 된다.

원하면 이렇게 받는다.

1. 구성원 이메일과 역할을 한 줄씩 받는다: `kim@example.com 기획`
2. 역할 조합마다 라벨을 받는다: `기획 + 개발 → 팀 전체`
3. 사외 조직 약칭이 있으면 받는다: `OO물류 자동화팀 → 자동화팀`

### 3-4. 문체

| 선택 | `style` |
|------|------|
| 기본 문체 (`references/style.md`) | `[]` |
| 우리 팀 문체 가이드 파일이 있다 | 그 파일들의 절대 경로 배열 |

### 3-5. 회의 후 안내

`/rec stop` 이 마지막 줄에 띄울 문장이다. 팀에 회의록을 정본으로 올리는 다른 스킬이 있으면 그 안내를 적는다. 없으면 빈 문자열로 둔다 (기본 안내가 나간다).

## 4. 용어집

`~/.config/mtgrec/vocabulary.json` 도 `{storage}/vocabulary.json` 도 없으면 preset 의 `vocabulary.json`, 없으면 `references/vocabulary.example.json` 을 `~/.config/mtgrec/vocabulary.json` 으로 복사한다.

이어서 「회의에 자주 나오는 고유명사 · 약어 · 제품명」 을 자유 입력으로 받는다. 받은 것은 `terms` 에만 넣는다. **`replacements` 와 `glossary` 는 지금 채우지 않는다.** 오인식형은 실제 전사본을 보기 전에는 모른다. 첫 회의를 전사한 뒤 SKILL.md 의 「새 용어를 발견했을 때」 절차로 넣는다고 안내한다.

## 5. 쓰기

`config.json` 전체를 보여주고 확인을 받은 뒤 쓴다. 기존 파일이 있으면 바뀌는 필드만 표로 보여준다.

```bash
mkdir -p ~/.config/mtgrec
```

필드 정의는 아래 「config.json」 절이다. JSON 은 `python3 -m json.tool` 로 한 번 검증한다.

## 6. 빌드와 확인

```bash
{이 스킬}/tools/build.sh
~/.claude/bin/mtgrec config
```

`mtgrec config` 의 출력에서 저장 위치 · 용어집 · 규칙 파일 경로가 설정과 맞는지 본다. 규칙 파일이 「없음. 내장 규칙 사용」 이면 스킬 경로를 못 찾은 것이다. 그때는 `~/.config/mtgrec/` 에 이 스킬의 `references/correct.md` · `live-summary.md` 를 복사한다.

## 7. 시험 녹음

사용자에게 묻고 한다. 회의 중이면 건너뛴다.

```bash
~/.claude/bin/mtgrec start "설정 확인" --no-live
```

처음 녹음하면 macOS 가 **마이크** 와 **시스템 오디오 녹음** 권한을 묻는다. 권한은 이 명령을 띄운 앱(터미널 · iTerm · Claude 앱)에 붙는다. 거부했으면 시스템 설정 > 개인정보 보호 및 보안에서 켜고 다시 한다.

사용자에게 10초 동안 말을 하면서 브라우저에서 아무 영상이나 소리 나게 틀어 달라고 한다. 그다음 끈다.

```bash
~/.claude/bin/mtgrec stop
~/.claude/bin/mtgrec transcribe --no-correct
```

| 결과 | 판정 |
|------|------|
| `mic (나)` · `sys (상대)` 모두 덩어리 1 이상 | 통과 |
| `sys (상대): 0 덩어리` | 시스템 오디오 권한이 없거나 소리가 다른 출력 장치로 나갔다 |
| `mic (나): 0 덩어리` | 마이크 권한이 없거나 입력 장치가 다르다 |
| 처음 전사에서 30초쯤 멈춤 | ko-KR 모델을 내려받는 중이다. 정상이다 |

Notion 을 켰으면 전사본으로 요약 → 페이지 생성까지 한 번 돌려 볼지 묻는다. 돌렸으면 만든 페이지 URL 을 주고, 지울지는 사용자가 정한다. 시험 세션 디렉터리도 지울지 묻는다.

## config.json

| 필드 | 형식 | 누가 읽나 | 뜻 |
|------|------|------|------|
| `storage` | 경로 | `mtgrec` | 세션이 쌓이는 곳. `~` 를 쓸 수 있다. `MTGREC_HOME` 이 있으면 그것이 이긴다 |
| `owner` | 문자열 | 스킬 | 사용자 이름 |
| `email` | 문자열 | 스킬 | 사용자 이메일. 캘린더 참석자 중 본인을 가리고, `internalDomains` 기본값을 정한다 |
| `notion.enabled` | bool | 스킬 | 거짓이면 Notion 단계를 건너뛴다 |
| `notion.dataSource` | `collection://...` | 스킬 | 페이지를 만들 데이터 소스 |
| `notion.icon` | 문자열 | 스킬 | 페이지 아이콘. 빈 문자열이면 붙이지 않는다 |
| `notion.properties` | 객체 | 스킬 | 늘 같은 값으로 넣을 속성 |
| `notion.inferred` | 객체 | 스킬 | 속성 이름 → 내용으로 정하는 방법 |
| `title.format` | 문자열 | 스킬 | `{date}` `{time}` `{attendees}` `{topic}` 자리표시자 |
| `title.calendarPrefixPattern` | 정규식 | 스킬 | 캘린더 일정 제목에서 뗄 접두어 |
| `attendees.internalDomains` | 배열 | 스킬 | 내부로 볼 메일 도메인 |
| `attendees.people` | 객체 | 스킬 | 이메일 → 역할 |
| `attendees.groups` | 배열 | 스킬 | `{roles, label}`. 내부 참석자의 역할 집합이 `roles` 와 같으면 `label` |
| `attendees.orgAliases` | 객체 | 스킬 | 사외 조직명 → 약칭 |
| `attendees.fallback` | 문자열 | 스킬 | 캘린더가 없거나 그룹이 안 갈릴 때의 참석자 칸 |
| `style` | 배열 | 요약 에이전트 | 문체 규격 파일. 비면 `references/style.md` |
| `handoff` | 문자열 | 스킬 | `/rec stop` 마지막 줄 안내 |

예시는 `references/config.example.json` 이다. 모르는 필드는 무시되므로 필드를 더해도 빌드를 다시 할 필요가 없다.
