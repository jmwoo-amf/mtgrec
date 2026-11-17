import Foundation

/// 회의 중에 갱신되는 논의 묶음 노트.
///
/// 전사본을 순서대로 흘려보내는 것만으로는 회의 중에 쓸모가 없다. 같은 주제가 여러 번
/// 끊겨 돌아오기 때문이다. 그래서 새로 확정된 발화가 쌓일 때마다 헤드리스 `claude` 를
/// 불러 기존 묶음에 병합시킨다. 이것은 **미리보기**이고, 정본 요약은 회의가 끝난 뒤
/// `transcript.md` 를 놓고 `references/summary.md` 절차로 따로 만든다.
struct LiveNotes: Codable {
    struct Topic: Codable {
        var title: String
        var background: String?
        var content: String?
        var conclusion: String?
        /// 1 = 뒤따르는 작업의 방향을 바꾸는 것, 2 = 막고 있는 것, 3 = 알아야 하는 사실
        var importance: Int?
    }

    var updatedAt: Date?
    /// 여기까지의 세그먼트를 모델에 넘겼다. 다음 사이클은 이 뒤부터만 보낸다.
    var cursor: Int = 0
    var headline: [String] = []
    var topics: [Topic] = []
    var actions: [String] = []
    /// 마지막 사이클이 실패한 이유. 실패해도 직전 노트는 지우지 않는다.
    var lastError: String?
    var running: Bool = false

    /// 노트가 실제로 덮은 구간. 라이브가 녹음 도중에 붙었거나 사이클이 멈추면
    /// 녹음 길이와 어긋난다. 이 값이 없으면 32분짜리 노트를 147분짜리로
    /// 착각한다. 실제로 그런 일이 있었다.
    var coveredFromSeconds: Double?
    var coveredUntilSeconds: Double?

    /// 연속 실패 횟수. 같은 창을 세 번 놓치면 건너뛰고 `gaps` 에 적는다.
    /// 창을 영구히 붙들고 있으면 그 뒤 발화가 전부 노트에 안 들어간다.
    var consecutiveFailures: Int = 0

    /// 사이클이 포기한 구간. 비어 있는 것이 정상이다.
    struct Gap: Codable {
        var fromSeconds: Double
        var toSeconds: Double
        var reason: String
    }
    var gaps: [Gap] = []

    init() {}

    /// 합성 Codable 은 기본값이 있어도 키가 없으면 던진다. 이 필드들을 모르던
    /// 시절의 `notes.json` 을 읽어야 하므로 전부 `decodeIfPresent` 로 받는다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        headline = try c.decodeIfPresent([String].self, forKey: .headline) ?? []
        topics = try c.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        coveredFromSeconds = try c.decodeIfPresent(Double.self, forKey: .coveredFromSeconds)
        coveredUntilSeconds = try c.decodeIfPresent(Double.self, forKey: .coveredUntilSeconds)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        gaps = try c.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
    }

    /// 재시작할 때 디스크에서 이어받는다.
    ///
    /// `cursor` 는 **가져오지 않는다.** 그것은 이 프로세스의 `published` 배열
    /// 인덱스이고 재시작하면 배열이 비어서 시작한다. 옛 커서(예: 241)를 그대로
    /// 쓰면 `cursor < published.count` 가 영구히 거짓이 되어 노트가 다시는 안 돈다.
    ///
    /// 이걸 안 하면 재시작이 앞 구간 노트를 통째로 버린다. 실제로 앞 한 시간 노트가
    /// 그렇게 사라진 적이 있다.
    static func resume(from url: URL) -> LiveNotes {
        var loaded = decode(url) ?? LiveNotes()
        // `notes.json` 이 이미 퇴행본으로 덮여 있으면 마지막 정상본에서 이어받는다.
        // 검증 게이트가 붙은 뒤에는 여기 걸릴 일이 없지만, 게이트 없던 시절에
        // 만들어진 세션과 손으로 건드린 파일이 남아 있다.
        if loaded.topics.isEmpty, let good = decode(lastGoodURL(besides: url)), !good.topics.isEmpty {
            loaded.headline = good.headline
            loaded.topics = good.topics
            loaded.actions = good.actions
        }
        loaded.cursor = 0
        loaded.running = false
        loaded.consecutiveFailures = 0
        return loaded
    }

    private static func decode(_ url: URL) -> LiveNotes? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveNotes.self, from: data)
    }

    /// 마지막으로 검증을 통과한 노트. `notes.json` 과 같은 디렉터리에 둔다.
    static func lastGoodURL(besides notesURL: URL) -> URL {
        notesURL.deletingLastPathComponent().appendingPathComponent("notes.last-good.json")
    }

    /// 통과한 노트를 한 줄씩 덧붙이는 이력. 덮어쓰지 않으므로 되돌릴 수 있다.
    static func historyURL(besides notesURL: URL) -> URL {
        notesURL.deletingLastPathComponent().appendingPathComponent("notes.history.jsonl")
    }
}

/// 스키마만 만족하는 빈 응답을 성공으로 받으면 쌓아 온 노트가 통째로 날아간다.
///
/// 실제 회의에서 모델이 `{"headline":["placeholder"],"topics":[],
/// "actions":["placeholder"]}` 를 돌려줬고, 스키마의 `required` 는 키 존재만 보므로
/// 그대로 통과해 안건 5건이 지워졌다. 회의 중에 보고 있던 노트가 사라지는 것이
/// 요약 한 번 실패하는 것보다 나쁘다. 퇴행이면 실패로 처리해 직전 노트를 지킨다.
enum NoteRegression: Error, CustomStringConvertible {
    case emptyTopics
    case junk(String)
    case shrank(Int, Int)

    var description: String {
        switch self {
        case .emptyTopics:
            return "빈 노트를 돌려받았습니다 (안건 0건). 직전 노트를 지킵니다"
        case .junk(let token):
            return "노트에 자리표시 문자열(\(token))이 들어 있습니다. 직전 노트를 지킵니다"
        case .shrank(let before, let after):
            return "노트가 \(before)자에서 \(after)자로 줄었습니다. 직전 노트를 지킵니다"
        }
    }
}

/// 모델이 채우지 못했을 때 스키마를 메우려고 내놓는 상투적인 값들.
/// 정상 노트에 이 단어 하나가 항목 전체로 오는 일은 없다.
private let junkTokens: Set<String> = [
    "placeholder", "tbd", "todo", "n/a", "na", "none", "null", "...", "…",
    "string", "example", "예시", "자리표시",
]

/// 노트의 알맹이 글자 수. 제목만 남고 본문이 사라진 퇴행을 잡으려고 본문까지 센다.
func noteMass(headline: [String], topics: [LiveNotes.Topic], actions: [String]) -> Int {
    var total = headline.reduce(0) { $0 + $1.count } + actions.reduce(0) { $0 + $1.count }
    for topic in topics {
        total += topic.title.count
        total += (topic.background ?? "").count
        total += (topic.content ?? "").count
        total += (topic.conclusion ?? "").count
    }
    return total
}

/// 갱신본이 직전 노트보다 퇴행했으면 던진다.
///
/// 판정을 셋으로 나눈다. 첫째와 둘째는 명백한 사고이고, 셋째는 확률적이다.
/// 셋째의 오탐 비용은 `gaps` 한 줄이고 미탐 비용은 노트 전체이므로 조인다.
func validateNoteReply(headline: [String], topics: [LiveNotes.Topic], actions: [String],
                       against carry: LiveNotes) throws {
    // 1. 있던 안건이 통째로 사라졌다
    if topics.isEmpty, !carry.topics.isEmpty { throw NoteRegression.emptyTopics }

    // 2. 자리표시 문자열이 항목 전체로 왔다
    var candidates = headline + actions + topics.map(\.title)
    candidates += topics.compactMap(\.conclusion)
    for value in candidates {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if junkTokens.contains(normalized) { throw NoteRegression.junk(value) }
    }

    // 3. 알맹이가 절반 아래로 쪼그라들었다. 노트가 자리를 잡은 뒤에만 본다.
    //    초기 사이클은 정상적으로도 크게 출렁인다.
    let before = noteMass(headline: carry.headline, topics: carry.topics, actions: carry.actions)
    guard before >= 600 else { return }
    let after = noteMass(headline: headline, topics: topics, actions: actions)
    if after * 100 < before * 40 { throw NoteRegression.shrank(before, after) }
}

/// 모델이 돌려줘야 하는 모양. `--json-schema` 로 그대로 넘긴다.
private let notesSchema = """
{"type":"object","additionalProperties":false,
 "properties":{
  "headline":{"type":"array","items":{"type":"string"}},
  "topics":{"type":"array","items":{"type":"object","additionalProperties":false,
    "properties":{
      "title":{"type":"string"},
      "background":{"type":"string"},
      "content":{"type":"string"},
      "conclusion":{"type":"string"},
      "importance":{"type":"integer"}},
    "required":["title","content","conclusion","importance"]}},
  "actions":{"type":"array","items":{"type":"string"}}},
 "required":["headline","topics","actions"]}
"""

/// 규칙은 파일로 둔다. 문구를 고칠 때 재빌드가 필요 없어야 한다.
/// 파일이 없으면 아래 내장본으로 돈다.
private let fallbackRules = """
너는 진행 중인 회의의 전사본을 논의 묶음으로 정리하는 도구다. JSON 만 출력한다.

입력으로 지금까지 만들어 둔 노트(JSON)와 그 뒤에 새로 확정된 발화가 온다.
새 발화를 기존 묶음에 **병합**해 갱신된 노트 전체를 돌려준다. 기존 묶음을 근거 없이 지우지 않는다.

- topics 는 3~7개. 제목은 명사구가 아니라 그 자리에서 다룬 질문으로 쓴다
  (`PoC 장비 구성` 이 아니라 `PoC 에 어떤 모델을 몇 대 투입할 것인가`)
- importance 는 1 = 뒤따르는 작업의 방향을 바꾸는 것, 2 = 막고 있는 것, 3 = 알아야 하는 사실
- conclusion 은 정해진 것만. 안 정해졌으면 `미결 - {무엇이 걸려 있는지}`. 잠정이면 잠정이라고 쓴다
- background 는 이 논의가 왜 열렸는지 한 줄. 전사본에 없으면 빈 문자열로 둔다
- actions 는 요청 표현(`~부탁드립니다`, `~확인해 주세요`, `~까지 주시면`, `~정리해서 공유`)을
  전부 훑어 뽑는다. 담당은 괄호로 끝에 붙이되 추론한 것에는 `추정: ` 을 붙인다
- headline 은 지금까지 무엇을 정했거나 무엇에 막혔는지 2~4줄

원칙
- 추출이지 창작이 아니다. 전사본에 있는 말만 쓴다. 구조가 비어 보인다고 배경이나 결론을 지어내지 않는다
- 화자는 「나」와 「상대」뿐이고 상대 트랙 안에서 누가 말했는지는 모른다. 실행 담당을 단정하지 않는다
- 아직 끝나지 않은 회의다. 결론이 없는 것이 정상이다. 미결을 미결로 둔다
- 숫자·식별자·날짜가 문맥과 어긋나면 고치지 말고 `(전사 불확실)` 을 붙인다
- 잡담, 화면 조작, 인사, 되풀이는 버린다
"""

enum SummaryRules {
    static func load() -> String {
        References.load("live-summary.md", envKey: "MTGREC_SUMMARY_RULES") ?? fallbackRules
    }
}

enum SummaryError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 헤드리스 `claude` 를 한 번 부른다.
///
/// 안전장치를 겹쳐 건다. 이 프로세스는 사람이 보고 있지 않은 채로 도는 데다
/// 회의 중에 돌기 때문에, 요약기가 무언가를 실제로 건드리는 사고는 조용히 일어난다.
///
/// - `--safe-mode`         CLAUDE.md · 스킬 · 훅 · 플러그인 · MCP · 에이전트 전부 끔
/// - `--strict-mcp-config` `--mcp-config` 를 안 줬으므로 MCP 서버가 하나도 안 뜬다
/// - `--restricted`        Bash 를 비롯한 코드 실행 도구와 WebFetch 제거, 사용자·프로젝트 설정 무시
/// - `--max-budget-usd`    호출당 상한
/// - 벽시계 타임아웃        위 셋이 다 새도 여기서 끊는다
///
/// (2.1.252 에는 `--max-turns` 가 없다. 위 조합이 그 자리를 대신한다.)
struct Summarizer {
    var model: String
    var budgetUSD: Double
    var timeout: TimeInterval
    var workingDirectory: URL
    /// 생각을 얼마나 시킬지. 요약은 기본값(모델이 알아서)이 낫지만, 용어 보정은
    /// 사실상 찾아 바꾸기라서 낮춰야 한다. 높은 상태로 두면 청크 하나가 150초를 넘긴다.
    var effort: String?

    static func fromEnvironment(workingDirectory: URL) -> Summarizer {
        let environment = ProcessInfo.processInfo.environment
        return Summarizer(
            model: environment["MTGREC_SUMMARY_MODEL"] ?? "sonnet",
            budgetUSD: environment["MTGREC_SUMMARY_BUDGET"].flatMap(Double.init) ?? 0.30,
            timeout: environment["MTGREC_SUMMARY_TIMEOUT"].flatMap(Double.init) ?? 150,
            workingDirectory: workingDirectory,
            effort: nil)
    }

    private static func executable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MTGREC_CLAUDE_BIN"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 갱신된 노트 조각을 준다. 실패는 던진다. 부르는 쪽이 직전 노트를 지키고 경고만 남긴다.
    func run(prompt: String, rules: String) throws -> (headline: [String],
                                                        topics: [LiveNotes.Topic],
                                                        actions: [String]) {
        let payload = try runRaw(prompt: prompt, rules: rules, schema: notesSchema).payload
        struct Reply: Codable {
            var headline: [String]?
            var topics: [LiveNotes.Topic]?
            var actions: [String]?
        }
        let reply = try JSONDecoder().decode(Reply.self, from: payload)
        return (reply.headline ?? [], reply.topics ?? [], reply.actions ?? [])
    }

    /// 스키마를 지정해 한 번 부르고, 봉투에서 알맹이만 JSON 으로 꺼내 준다.
    /// 요약과 용어 보정이 같은 안전장치를 쓰도록 여기 한 군데로 모은다.
    func runRaw(prompt: String, rules: String, schema: String) throws -> (payload: Data, costUSD: Double) {
        guard let executable = Self.executable() else {
            throw SummaryError.message("claude 실행 파일을 찾을 수 없습니다")
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "-p",
            "--safe-mode",
            "--strict-mcp-config",
            "--restricted",
            "--no-session-persistence",
            "--model", model,
            "--max-budget-usd", String(format: "%.2f", budgetUSD),
            "--output-format", "json",
            "--json-schema", schema,
            "--system-prompt", rules,
        ]
        if let effort { process.arguments?.append(contentsOf: ["--effort", effort]) }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        try process.run()

        // 파이프를 먼저 비우기 시작한다. 응답이 64KB 파이프 버퍼를 넘으면
        // 자식이 write 에서 막히고 waitUntilExit 가 영원히 안 돌아온다.
        var outputData = Data(), errorData = Data()
        let lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outputData.append(chunk); lock.unlock()
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errorData.append(chunk); lock.unlock()
        }

        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline { timedOut = true; process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        outputData.append(output.fileHandleForReading.availableData)
        errorData.append(errors.fileHandleForReading.availableData)
        let stdout = outputData, stderr = errorData
        lock.unlock()

        if timedOut { throw SummaryError.message("\(Int(timeout))초 안에 끝나지 않았습니다") }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw SummaryError.message("claude 종료 코드 \(process.terminationStatus). \(message.prefix(300))")
        }
        return try Self.parse(stdout)
    }

    /// `--output-format json` 의 봉투에서 알맹이를 꺼낸다.
    /// `--json-schema` 를 줬으므로 보통 `structured_output` 에 파싱된 객체가 들어 있고,
    /// 그게 없으면 `result` 문자열을 JSON 으로 다시 읽는다.
    static func parse(_ data: Data) throws -> (payload: Data, costUSD: Double) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SummaryError.message("응답이 JSON 이 아닙니다: \(text.prefix(200))")
        }
        if let isError = envelope["is_error"] as? Bool, isError {
            throw SummaryError.message("claude 가 오류를 보고했습니다: \((envelope["result"] as? String ?? "").prefix(200))")
        }

        var payload: [String: Any]?
        if let structured = envelope["structured_output"] as? [String: Any] {
            payload = structured
        } else if let text = envelope["result"] as? String {
            payload = extractObject(from: text)
        }
        guard let payload else {
            throw SummaryError.message("응답에서 노트 JSON 을 찾지 못했습니다")
        }

        let cost = envelope["total_cost_usd"] as? Double ?? 0
        return (try JSONSerialization.data(withJSONObject: payload), cost)
    }

    /// 코드펜스나 앞뒤 산문에 싸여 오는 경우를 위해 가장 바깥 객체만 도려낸다.
    private static func extractObject(from text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(text[start...end])
        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
    }
}

/// 모델에 넘길 본문. 노트 전체 + 커서 뒤의 새 발화만 담는다.
/// 매번 전사본 전체를 보내면 회의가 길어질수록 호출이 비싸지고 느려진다.
/// 용어집의 문맥 판정용 항목을 프롬프트에 붙일 형태로 뽑는다.
///
/// 결정적 치환(`Vocabulary.replacements`)은 이미 `Live.swift` 가 세그먼트마다
/// 걸어 두었다. 여기서 주는 것은 치환표로 못 가르는 것들의 판정 근거다.
/// 사이클에서 이미 모델이 발화를 읽고 있으므로 별 보정 단계를 두지 않고
/// 근거만 넘긴다. 입력이 약 2,000자 늘고 출력은 늘지 않는다.
func buildGlossarySection(_ vocabulary: Vocabulary) -> [String] {
    guard !vocabulary.glossary.isEmpty else { return [] }
    var lines = ["## 용어집", ""]
    lines.append("아래 항목에 한해 오인식을 고쳐 쓴다. **숫자 · 식별자 · 날짜는 고치지 않는다.**")
    lines.append("근거가 이 표에 없으면 고치지 말고 `(전사 불확실)` 을 붙인다.")
    lines.append("")
    for key in vocabulary.glossary.keys.sorted() {
        lines.append("- **\(key)** — \(vocabulary.glossary[key] ?? "")")
    }
    lines.append("")
    return lines
}

func buildSummaryPrompt(notes: LiveNotes, newSegments: [Segment], elapsed: Double,
                        glossary: [String] = []) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    struct Carry: Codable {
        var headline: [String]
        var topics: [LiveNotes.Topic]
        var actions: [String]
    }
    let carry = Carry(headline: notes.headline, topics: notes.topics, actions: notes.actions)
    let carryJSON = (try? encoder.encode(carry)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

    var lines: [String] = []
    lines.append(contentsOf: glossary)
    lines.append("## 지금까지의 노트")
    lines.append("")
    lines.append(carryJSON)
    lines.append("")
    lines.append("## 새로 확정된 발화 (경과 \(formatTimestamp(elapsed)))")
    lines.append("")
    for segment in newSegments {
        lines.append("[\(formatTimestamp(segment.start))] \(segment.speaker): \(segment.text)")
    }
    lines.append("")
    lines.append("위 발화를 노트에 병합해 갱신된 노트 전체를 JSON 으로 돌려주십시오.")
    return lines.joined(separator: "\n")
}
