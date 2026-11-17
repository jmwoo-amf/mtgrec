import Foundation

/// 전사본의 도메인 용어를 문맥을 보고 바로잡는다.
///
/// 치환표(`Vocabulary.replacements`)가 못 하는 일을 맡는다. 같은 글자가 어떤 문장에서는
/// 도메인 용어이고 어떤 문장에서는 평범한 한국어인 경우다. 예를 들어 `로스` 는 ROS 일 때와
/// 「재고 로스」일 때가 섞이고, `클라우드` 는 Point Cloud 일 때와 서버일 때가 섞인다.
/// 문장을 읽지 않고는 가를 수 없다.
///
/// 원본은 `transcript.raw.json` 으로 남기고 여기서부터 다시 시작하므로, 용어집을 고친 뒤
/// 몇 번을 다시 돌려도 보정이 누적되지 않는다.
enum Correct {
    enum Kind: String {
        case table = "치환"      // 경계 규칙을 건 기계적 치환
        case context = "문맥"    // 모델이 문장을 읽고 판단한 것
        case both = "치환+문맥"
    }

    struct Report {
        var changes: [Change]
        var costUSD: Double
        var chunks: Int
        var failures: Int
    }

    struct Change {
        var index: Int
        var kind: Kind
        var speaker: String
        var start: Double
        var before: String
        var after: String
    }

    /// 한 번에 넘길 문장 수. 너무 크면 모델이 뒤쪽을 대충 보고, 너무 작으면
    /// 앞뒤 문맥이 잘려 「로스」가 ROS 인지 손실인지 판단할 근거가 사라진다.
    ///
    /// 호출 하나가 문장 수와 거의 무관하게 1분 남짓 걸리므로, 덩이를 잘게 쪼개면
    /// 회의 하나에 몇 분이 그냥 날아간다. 크게 잡고 동시에 돌리는 편이 낫다.
    static let chunkSize = 150
    static let concurrency = 4

    /// 프롬프트가 붙인 번호와 화자 꼬리표를 모델이 문장에 섞어 돌려주는 일이 있다.
    /// 그대로 두면 전사본에 `[나] ` 가 박힌다. 받는 쪽에서 걷어낸다.
    static func stripPrefix(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 앞머리의 `12`, `12\t`, `[나]`, `[상대]` 를 순서에 상관없이 벗긴다.
        for _ in 0..<3 {
            if let match = result.range(of: "^\\s*\\d+\\s*[\\t:.]?\\s*", options: .regularExpression) {
                result.removeSubrange(match)
                continue
            }
            if let match = result.range(of: "^\\s*\\[[^\\]]{1,8}\\]\\s*", options: .regularExpression) {
                result.removeSubrange(match)
                continue
            }
            break
        }
        return result
    }

    /// 모델이 문장을 고치는 게 아니라 새로 쓰기 시작하면 버린다.
    /// 보정은 낱말 교정이지 재작성이 아니다.
    ///
    /// 길이 비율을 좁게 잡는 이유가 있다. 용어를 바꾸는 것은 문장 길이를 크게 흔들지
    /// 않는다. 크게 흔들렸다면 모델이 말을 보태거나 문장을 잘라낸 것이고, 그것은
    /// 보정이 아니라 왜곡이다. 놓치는 편이 왜곡하는 편보다 낫다.
    static func plausible(_ before: String, _ after: String) -> Bool {
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard after != before else { return false }
        let ratio = Double(after.count) / Double(max(before.count, 1))
        guard ratio > 0.7, ratio < 1.4 else { return false }
        return textSimilarity(before, after) >= 0.6
    }
}

private let correctionSchema = """
{"type":"object","additionalProperties":false,
 "properties":{"corrections":{"type":"array","items":{"type":"object","additionalProperties":false,
   "properties":{"i":{"type":"integer"},"text":{"type":"string"}},
   "required":["i","text"]}}},
 "required":["corrections"]}
"""

private let fallbackRules = """
너는 회의 전사본의 도메인 용어 오인식을 바로잡는 도구다. JSON 만 출력한다.

번호가 붙은 문장이 순서대로 온다. **고쳐야 할 문장만** `{"i": 번호, "text": "고친 문장"}` 로 돌려준다.
고칠 것이 없으면 `{"corrections": []}` 를 돌려준다.

## 하는 일

용어집에 있는 말이 잘못 인식된 자리를 정식 표기로 바꾼다. 그것뿐이다.

## 하지 않는 일

- **문장을 다시 쓰지 않는다.** 어색해도, 비문이어도, 말이 끊겨 있어도 그대로 둔다.
  바꾸는 것은 오인식된 낱말이지 문장이 아니다
- 맞춤법·띄어쓰기·말투를 고치지 않는다
- 요약하거나 줄이지 않는다
- 확신이 없으면 두고 간다. 놓친 오인식은 사람이 원문을 보면 되지만,
  멀쩡한 말을 도메인 용어로 바꿔 놓으면 그 문장은 되돌릴 수 없다

## 판단 기준

같은 글자가 도메인 용어일 때와 평범한 한국어일 때가 있다. 문장이 무엇을 말하고 있는지로 가른다.
아래는 용어집에 ROS · Point Cloud 가 있을 때의 예다. 이번 용어집에 없는 말은 모양이 같아도 고치지 않는다.

- `로스 드라이버로 바로 붙일 수 있어요` → 소프트웨어 드라이버이므로 ROS 다. 고친다
- `운송 중에 로스가 좀 생겼어요` → 손실이다. 두고 간다
- `비 오는 날 클라우드에 노이즈가 많아요` → 점 데이터의 노이즈이므로 Point Cloud 다. 고친다
- `데이터는 클라우드에 올려 드릴게요` → 저장 공간이다. 두고 간다
"""

enum CorrectionRules {
    static func load() -> String {
        References.load("correct.md", envKey: "MTGREC_CORRECT_RULES") ?? fallbackRules
    }
}

/// 청크 하나를 모델에 넘겨 바뀐 문장만 받아온다.
private func correctChunk(_ segments: [(index: Int, segment: Segment)],
                          glossary: [String: String],
                          rules: String,
                          summarizer: Summarizer) throws -> (edits: [Int: String], costUSD: Double) {
    var lines: [String] = []
    lines.append("## 용어집")
    lines.append("")
    for key in glossary.keys.sorted() {
        lines.append("- **\(key)** — \(glossary[key] ?? "")")
    }
    lines.append("")
    lines.append("## 문장")
    lines.append("")
    // 화자는 넣지 않는다. `[나]` 같은 꼬리표를 붙여 주면 모델이 그것을 문장의 일부로
    // 여기고 고친 문장에 그대로 베껴 넣는다. 「로스」가 ROS 인지 아닌지는 화자가 아니라
    // 문장 내용으로 갈리므로 없어도 판단에 지장이 없다.
    for entry in segments {
        lines.append("\(entry.index)\t\(entry.segment.text)")
    }

    let reply = try summarizer.runRaw(prompt: lines.joined(separator: "\n"),
                                      rules: rules,
                                      schema: correctionSchema)
    struct Reply: Codable {
        struct Item: Codable { var i: Int; var text: String }
        var corrections: [Item]?
    }
    let decoded = try JSONDecoder().decode(Reply.self, from: reply.payload)
    var output: [Int: String] = [:]
    for item in decoded.corrections ?? [] { output[item.i] = Correct.stripPrefix(item.text) }
    return (output, reply.costUSD)
}

// MARK: - correct 명령

func runCorrect(arguments: [String]) async {
    let target: (directory: URL, session: Session)
    if let first = arguments.first, !first.hasPrefix("-") {
        let directory = first.contains("/") ? URL(fileURLWithPath: first) : Store.sessionDirectory(id: first)
        guard let session = try? Store.load(directory) else { fail("세션을 읽을 수 없습니다: \(first)") }
        target = (directory, session)
    } else {
        guard let latest = Store.list(limit: 1).first else { fail("세션이 없습니다") }
        target = latest
    }
    let changes = await correctTranscript(directory: target.directory, session: target.session)
    reportCorrections(changes, directory: target.directory)
}

func reportCorrections(_ report: Correct.Report?, directory: URL) {
    guard let report else {
        print("보정을 건너뛰었습니다.")
        return
    }
    let changes = report.changes
    if report.failures > 0 {
        print("보정 청크 \(report.chunks)개 중 \(report.failures)개 실패. 그 구간은 원문 그대로입니다.")
    }
    if changes.isEmpty {
        print("보정할 곳이 없습니다.")
        return
    }
    let context = changes.filter { $0.kind != .table }.count
    print(String(format: "용어 보정 %d군데 (치환만 %d, 문맥 판단 %d) · $%.3f",
                 changes.count, changes.count - context, context, report.costUSD))
    for change in changes.prefix(12) {
        print("  [\(formatTimestamp(change.start))] \(change.speaker) · \(change.kind.rawValue)")
        print("    - \(change.before)")
        print("    + \(change.after)")
    }
    if changes.count > 12 { print("  … 그 밖에 \(changes.count - 12)군데") }
    print("  원본: \(directory.appendingPathComponent("transcript.raw.md").path)")
}

/// 전사본을 읽어 보정하고 제자리에 다시 쓴다. 원본은 `transcript.raw.*` 로 남는다.
/// 보정을 못 하면 nil 을 준다. 전사본 자체는 어떤 경우에도 손상되지 않는다.
@discardableResult
func correctTranscript(directory: URL, session: Session) async -> Correct.Report? {
    let fm = FileManager.default
    let rawJSON = directory.appendingPathComponent("transcript.raw.json")
    let rawMarkdown = directory.appendingPathComponent("transcript.raw.md")
    let liveJSON = directory.appendingPathComponent("transcript.json")
    let liveMarkdown = directory.appendingPathComponent("transcript.md")

    // 원본을 한 번만 떠 둔다. 두 번째부터는 그 원본에서 다시 시작하므로
    // 용어집을 고쳐 가며 몇 번을 돌려도 보정이 겹쳐 쌓이지 않는다.
    if !fm.fileExists(atPath: rawJSON.path) {
        guard fm.fileExists(atPath: liveJSON.path) else {
            FileHandle.standardError.write("transcript.json 이 없습니다. 먼저 전사를 하십시오\n".data(using: .utf8)!)
            return nil
        }
        try? fm.copyItem(at: liveJSON, to: rawJSON)
        if fm.fileExists(atPath: liveMarkdown.path) {
            try? fm.copyItem(at: liveMarkdown, to: rawMarkdown)
        }
    }

    guard let data = try? Data(contentsOf: rawJSON),
          var segments = try? JSONDecoder().decode([Segment].self, from: data),
          !segments.isEmpty else {
        FileHandle.standardError.write("전사본을 읽을 수 없습니다\n".data(using: .utf8)!)
        return nil
    }

    let vocabulary = Vocabulary.load()

    // 보정 전 원문. 마지막에 이것과 비교해 세그먼트마다 한 줄로 보고한다.
    // 단계별로 따로 보고하면 같은 문장이 두 번 나와 무엇이 바뀐 건지 읽히지 않는다.
    let original = segments.map(\.text)
    var touchedByTable = Set<Int>()

    // 1단계. 치환표를 원문에 다시 건다. 전사 때 이미 한 번 걸렸지만, 그 뒤에 용어집을
    // 고쳤을 수 있다. 여기서 다시 걸어야 `/rec correct` 가 용어집 수정의 반영 수단이 된다.
    for index in segments.indices {
        let after = vocabulary.apply(to: segments[index].text)
        guard after != segments[index].text else { continue }
        segments[index].text = after
        touchedByTable.insert(index)
    }

    let rules = CorrectionRules.load()
    var summarizer = Summarizer.fromEnvironment(workingDirectory: directory)
    // 보정은 추론이 아니라 찾아 바꾸기다. 생각을 길게 시키면 청크마다 몇 분씩 걸리고
    // 판단이 좋아지지도 않는다. 대신 타임아웃은 넉넉히 준다.
    summarizer.effort = ProcessInfo.processInfo.environment["MTGREC_CORRECT_EFFORT"] ?? "low"
    summarizer.timeout = ProcessInfo.processInfo.environment["MTGREC_CORRECT_TIMEOUT"]
        .flatMap(Double.init) ?? 240
    let indexed = segments.enumerated().map { (index: $0.offset, segment: $0.element) }
    let chunks = stride(from: 0, to: indexed.count, by: Correct.chunkSize).map {
        Array(indexed[$0..<min($0 + Correct.chunkSize, indexed.count)])
    }

    var corrections: [Int: String] = [:]
    var failures = 0
    var cursor = 0
    var spent: Double = 0
    // 2단계. 용어집이 비어 있으면 문맥 보정은 건너뛰고 치환 결과만 남긴다.
    if vocabulary.glossary.isEmpty {
        FileHandle.standardError.write("vocabulary.json 에 glossary 가 없어 문맥 보정은 건너뜁니다\n".data(using: .utf8)!)
        cursor = chunks.count
    }
    while cursor < chunks.count {
        let batch = Array(chunks[cursor..<min(cursor + Correct.concurrency, chunks.count)])
        cursor += batch.count
        await withTaskGroup(of: Result<(edits: [Int: String], costUSD: Double), Error>.self) { group in
            for chunk in batch {
                group.addTask {
                    do {
                        return .success(try correctChunk(chunk, glossary: vocabulary.glossary,
                                                         rules: rules, summarizer: summarizer))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let found):
                    corrections.merge(found.edits) { _, new in new }
                    spent += found.costUSD
                case .failure(let error):
                    failures += 1
                    FileHandle.standardError.write("  보정 청크 실패: \(error)\n".data(using: .utf8)!)
                }
            }
        }
    }

    // 모델이 문장을 새로 쓰기 시작한 것은 버린다. 걸러낸 것은 원문 그대로 남는다.
    var touchedByContext = Set<Int>()
    for (index, text) in corrections {
        guard segments.indices.contains(index) else { continue }
        guard Correct.plausible(segments[index].text, text) else { continue }
        segments[index].text = text
        touchedByContext.insert(index)
    }

    var changes: [Correct.Change] = []
    for index in segments.indices where segments[index].text != original[index] {
        let table = touchedByTable.contains(index)
        let context = touchedByContext.contains(index)
        changes.append(Correct.Change(index: index,
                                      kind: table && context ? .both : (context ? .context : .table),
                                      speaker: segments[index].speaker,
                                      start: segments[index].start,
                                      before: original[index],
                                      after: segments[index].text))
    }

    let report = Correct.Report(changes: changes, costUSD: spent,
                                chunks: chunks.count, failures: failures)
    guard !changes.isEmpty else { return report }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let encoded = try? encoder.encode(segments) {
        try? encoded.write(to: liveJSON, options: .atomic)
    }
    var corrected = session
    corrected.engine = (session.engine ?? "") + " + 용어보정"
    let markdown = renderMarkdown(session: corrected, segments: mergeAdjacent(segments))
    try? markdown.write(to: liveMarkdown, atomically: true, encoding: .utf8)

    return report
}
