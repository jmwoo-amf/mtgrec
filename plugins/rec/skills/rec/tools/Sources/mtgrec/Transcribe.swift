import Foundation
import AVFoundation
import Speech
import CoreMedia

struct Segment: Codable {
    var start: Double
    var end: Double
    var track: String
    var speaker: String
    var text: String
    var confidence: Double?
}

struct Vocabulary: Codable {
    /// 인식 전에 힌트로 넣는 고유명사. 제품명 · 프로젝트 코드 · 사람 이름처럼
    /// 일반 한국어 모델이 알 리 없는 말을 여기 둔다.
    var terms: [String] = []
    /// 인식 후 치환. 힌트로도 안 잡히는 것을 마지막에 바로잡는다.
    var replacements: [String: String] = [:]
    /// 문맥 보정 패스가 읽는 용어집. `정식 표기: 설명과 오인식 양상`.
    /// 치환표로는 못 고치는 것(같은 글자가 때로는 일반 한국어인 경우)이 여기 온다.
    var glossary: [String: String] = [:]

    static func load() -> Vocabulary {
        let candidates: [URL] = [
            ProcessInfo.processInfo.environment["MTGREC_VOCAB"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            Config.directory.appendingPathComponent("vocabulary.json"),
            Store.root.appendingPathComponent("vocabulary.json"),
        ].compactMap { $0 }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data) else { continue }
            return vocabulary
        }
        return Vocabulary()
    }

    /// 치환은 **앞 글자가 한글이면 걸지 않는다.**
    ///
    /// 단순 부분 문자열 치환은 조용히 다른 낱말을 부순다. `로스` → `ROS` 를 넣으면
    /// 「크로스」가 「크ROS」가 된다. 한국어는 교착어라 뒤에는 조사가 붙는 것이 정상이므로
    /// (`로스로`, `로스가`) 뒷경계는 막지 않고 앞경계만 막는다. 이 규칙 하나로 낱말 중간에
    /// 얻어걸리는 사고가 대부분 사라진다.
    ///
    /// 그래도 못 막는 것이 있다. `로스` 는 앞이 공백이어도 「재고 로스」일 수 있고
    /// `클라우드` 는 Point Cloud 일 때와 서버일 때가 섞인다. 이런 것은 치환표에 넣지 않고
    /// 문맥 보정 패스(`mtgrec correct`)에 맡긴다.
    func apply(to text: String) -> String {
        var result = text
        // 긴 항목을 먼저 건다. 그래야 `로스 투` 가 `로스` 보다 앞서 잡힌다.
        for (wrong, right) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            result = Self.replaceGuarded(result, of: wrong, with: right)
        }
        return result
    }

    static func replaceGuarded(_ text: String, of needle: String, with replacement: String) -> String {
        guard !needle.isEmpty else { return text }
        var output = ""
        var index = text.startIndex
        while let found = text.range(of: needle, range: index..<text.endIndex) {
            let precededByHangul = found.lowerBound > text.startIndex
                && isHangul(text[text.index(before: found.lowerBound)])
            output += text[index..<found.lowerBound]
            output += precededByHangul ? needle : replacement
            index = found.upperBound
        }
        output += text[index...]
        return output
    }

    private static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value)      // 음절
                || (0x1100...0x11FF).contains(scalar.value) // 자모
                || (0x3130...0x318F).contains(scalar.value) // 호환 자모
        }
    }
}

enum TranscribeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// 한 덩어리의 인식 결과를 문장 단위로 쪼갠다.
///
/// SpeechTranscriber 는 무음으로 끊길 때까지를 결과 하나로 준다. 회의에서는 한 사람이
/// 1~2분을 이어 말하는 일이 흔해서, 그대로 두면 타임스탬프가 덩어리 시작 하나뿐이라
/// 회의록 대조에서 "몇 분에 나온 말인지"를 짚을 수가 없다. `.audioTimeRange` 로 들어오는
/// 단어별 시각을 이용해 문장 경계에서 끊는다.
func splitIntoSentences(_ attributed: AttributedString,
                                fallbackRange: CMTimeRange,
                                maxSeconds: Double = 25) -> [(start: Double, end: Double, text: String, confidence: Double?)] {
    var output: [(start: Double, end: Double, text: String, confidence: Double?)] = []

    var buffer = ""
    var bufferStart: Double?
    var bufferEnd: Double?
    var confidences: [Double] = []

    func flush() {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        defer { bufferStart = nil; bufferEnd = nil; confidences = [] }
        guard !text.isEmpty else { return }
        let average = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        output.append((bufferStart ?? fallbackRange.start.seconds,
                       bufferEnd ?? fallbackRange.end.seconds,
                       text,
                       average))
    }

    for run in attributed.runs {
        let piece = String(attributed[run.range].characters)
        if let range = run.audioTimeRange {
            let start = range.start.seconds
            let end = range.end.seconds
            if bufferStart == nil { bufferStart = start }
            bufferEnd = end
        }
        if let value = run.transcriptionConfidence { confidences.append(Double(value)) }
        buffer += piece

        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let endsSentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
        let tooLong = (bufferEnd ?? 0) - (bufferStart ?? 0) >= maxSeconds
        if endsSentence || tooLong { flush() }
    }
    flush()

    // 단어별 시각이 하나도 없으면 덩어리 전체를 한 세그먼트로 둔다.
    if output.isEmpty {
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            output.append((fallbackRange.start.seconds, fallbackRange.end.seconds, text, nil))
        }
    }
    return output
}

/// 트랙 하나를 통째로 전사한다. 트랙이 곧 화자이므로 화자 분리 모델이 필요 없다.
func transcribeTrack(url: URL, track: Session.Track, locale: Locale, vocabulary: Vocabulary) async throws -> [Segment] {
    let transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [],
                                        attributeOptions: [.audioTimeRange, .transcriptionConfidence])

    let context = AnalysisContext()
    if !vocabulary.terms.isEmpty {
        context.contextualStrings[.general] = vocabulary.terms
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.setContext(context)

    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { return [] }

    // 결과 소비를 먼저 띄운다. 분석이 결과를 밀어내는 동안 아무도 받지 않으면 막힌다.
    let collector = Task { () -> [Segment] in
        var segments: [Segment] = []
        for try await result in transcriber.results where result.isFinal {
            for piece in splitIntoSentences(result.text, fallbackRange: result.range) {
                guard hasContent(piece.text) else { continue }
                segments.append(Segment(start: piece.start,
                                        end: piece.end,
                                        track: track.name,
                                        speaker: track.speaker,
                                        text: vocabulary.apply(to: piece.text),
                                        confidence: piece.confidence))
            }
        }
        return segments
    }

    // analyzeSequence 로 파일을 끝까지 밀어넣은 뒤 finalize 해야 결과 스트림이 닫힌다.
    // start(inputAudioFile:finishAfterFile:) 만 부르면 스트림이 열린 채로 남아 멈춘다.
    _ = try await analyzer.analyzeSequence(from: file)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return try await collector.value
}

/// ko-KR 모델이 없으면 받아온다. 첫 실행에서 한 번만 걸린다.
func ensureModelInstalled(locale: Locale) async throws {
    let probe = SpeechTranscriber(locale: locale,
                                  transcriptionOptions: [],
                                  reportingOptions: [],
                                  attributeOptions: [])
    let status = await AssetInventory.status(forModules: [probe])
    guard status != .installed else { return }
    guard status != .unsupported else {
        throw TranscribeError.message("\(locale.identifier(.bcp47)) 전사 모델을 이 기기에서 지원하지 않습니다")
    }

    _ = try? await AssetInventory.reserve(locale: locale)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) else { return }
    FileHandle.standardError.write("전사 모델(\(locale.identifier(.bcp47)))을 내려받는 중입니다...\n".data(using: .utf8)!)
    try await request.downloadAndInstall()
}

func formatTimestamp(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// 같은 화자가 이어 말한 조각은 한 덩어리로 묶는다. 문장마다 줄을 나누면 읽을 수가 없다.
///
/// 다만 무한정 묶으면 덩어리 앞의 타임스탬프 하나가 몇 분을 대표하게 되어 쓸모가 없어진다.
/// `maxBlock` 을 넘으면 끊어서, 읽을 만하면서도 시각이 대략 맞는 상태를 유지한다.
/// 문장 단위 원본은 transcript.json 에 그대로 남으므로 정확한 인용은 그쪽을 본다.
func mergeAdjacent(_ segments: [Segment], gapTolerance: Double = 2.0, maxBlock: Double = 60) -> [Segment] {
    var merged: [Segment] = []
    for segment in segments {
        if var last = merged.last,
           last.speaker == segment.speaker,
           segment.start - last.end <= gapTolerance,
           segment.end - last.start <= maxBlock {
            last.end = segment.end
            last.text += " " + segment.text
            merged[merged.count - 1] = last
        } else {
            merged.append(segment)
        }
    }
    return merged
}

/// 마이크가 주운 잡음이 마침표 하나로 인식되는 일이 흔하다. 글자가 없는 조각은 버린다.
func hasContent(_ text: String) -> Bool {
    text.unicodeScalars.contains {
        CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
    }
}

/// 두 문장이 같은 말인지 본다. 글자 2-gram 의 Dice 계수를 쓴다.
/// 한국어는 어절 경계가 인식마다 달라져서 단어 단위 비교가 잘 맞지 않는다.
func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
    func bigrams(_ text: String) -> Set<String> {
        let cleaned = text.unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
        guard cleaned.count >= 2 else { return cleaned.isEmpty ? [] : [cleaned] }
        let characters = Array(cleaned)
        return Set((0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) })
    }
    let a = bigrams(lhs), b = bigrams(rhs)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    return 2.0 * Double(a.intersection(b).count) / Double(a.count + b.count)
}

/// 헤드폰 없이 스피커로 회의하면 마이크가 상대 목소리를 그대로 주워 담는다.
/// 그러면 상대 발언이 「나」로도 한 번 더 기록되어, 이 도구를 만든 이유인
/// 화자 구분이 정확히 그 지점에서 무너진다. 시스템 트랙이 상대에 대해서는
/// 항상 더 깨끗하므로, 시간이 겹치고 내용이 같은 마이크 조각은 버린다.
func removeSpeakerBleed(_ segments: [Segment],
                        similarityThreshold: Double = 0.6) -> (kept: [Segment], dropped: Int) {
    let system = segments.filter { $0.track == "sys" }
    guard !system.isEmpty else { return (segments, 0) }

    var dropped = 0
    let kept = segments.filter { segment in
        guard segment.track == "mic" else { return true }
        for other in system {
            let overlap = min(segment.end, other.end) - max(segment.start, other.start)
            let shorter = min(segment.end - segment.start, other.end - other.start)
            guard shorter > 0, overlap > shorter * 0.5 else { continue }
            if textSimilarity(segment.text, other.text) >= similarityThreshold {
                dropped += 1
                return false
            }
        }
        return true
    }
    return (kept, dropped)
}

func renderMarkdown(session: Session, segments: [Segment]) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    formatter.locale = Locale(identifier: "ko_KR")

    var lines: [String] = []
    lines.append("# \(session.title)")
    lines.append("")

    var span = formatter.string(from: session.startedAt)
    if let endedAt = session.endedAt {
        let endFormatter = DateFormatter()
        endFormatter.dateFormat = "HH:mm"
        span += " ~ " + endFormatter.string(from: endedAt)
    }
    lines.append("| | |")
    lines.append("|---|---|")
    lines.append("| 일시 | \(span) (\(formatTimestamp(session.duration))) |")
    lines.append("| 트랙 | \(session.tracks.map { "\($0.name)=\($0.speaker)" }.joined(separator: ", ")) |")
    lines.append("| 엔진 | \(session.engine ?? "-") |")
    lines.append("| 발화 | \(segments.count) 덩어리 |")
    lines.append("")
    lines.append("---")
    lines.append("")

    if segments.isEmpty {
        lines.append("전사된 발화가 없습니다. 오디오 트랙의 peak 값을 확인하십시오.")
    }
    for segment in segments {
        lines.append("**[\(formatTimestamp(segment.start))] \(segment.speaker)**")
        lines.append("")
        lines.append(segment.text)
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

func runTranscribe(arguments: [String]) async {
    let target: (directory: URL, session: Session)
    if let first = arguments.first, !first.hasPrefix("-") {
        let directory = first.contains("/") ? URL(fileURLWithPath: first) : Store.sessionDirectory(id: first)
        guard let session = try? Store.load(directory) else { fail("세션을 읽을 수 없습니다: \(first)") }
        target = (directory, session)
    } else {
        guard let latest = Store.list(limit: 1).first else { fail("세션이 없습니다") }
        target = latest
    }

    var session = target.session
    guard session.status != .recording else { fail("아직 녹음 중입니다. mtgrec stop 을 먼저 하십시오") }
    guard session.status != .audioPurged else { fail("오디오가 이미 삭제된 세션입니다: \(session.id)") }
    guard !session.tracks.isEmpty else { fail("트랙이 없습니다: \(session.id)") }

    let locale = Locale(identifier: "ko-KR")
    let vocabulary = Vocabulary.load()

    var allSegments: [Segment] = []
    do {
        try await ensureModelInstalled(locale: locale)
        for track in session.tracks where track.frames > 0 {
            let url = target.directory.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let segments = try await transcribeTrack(url: url, track: track,
                                                     locale: locale, vocabulary: vocabulary)
            allSegments.append(contentsOf: segments)
            FileHandle.standardError.write("  \(track.name) (\(track.speaker)): \(segments.count) 덩어리\n".data(using: .utf8)!)
        }
    } catch {
        fail("전사 실패: \(error)")
    }

    // 두 트랙이 같은 IO 사이클로 기록되어 시작점이 같으므로 시작 시각 정렬만으로 병합된다.
    allSegments.sort { $0.start < $1.start }
    let (cleaned, bleedDropped) = removeSpeakerBleed(allSegments)
    allSegments = cleaned
    let merged = mergeAdjacent(allSegments)

    session.engine = "apple-speechtranscriber ko-KR"
    session.status = .transcribed
    session.note = bleedDropped > 0
        ? "스피커 누화로 마이크 트랙에서 \(bleedDropped) 조각 제거. 헤드폰을 쓰면 이 보정이 필요 없습니다"
        : nil
    try? Store.save(session, to: target.directory)

    // JSON 은 쪼개진 그대로 남긴다. 정확한 인용과 시각은 여기를 본다.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? encoder.encode(allSegments) {
        try? data.write(to: target.directory.appendingPathComponent("transcript.json"))
    }
    let markdown = renderMarkdown(session: session, segments: merged)
    try? markdown.write(to: target.directory.appendingPathComponent("transcript.md"),
                        atomically: true, encoding: .utf8)

    print("전사 완료: \(session.title)")
    print("  발화 \(merged.count) 덩어리")
    print("  \(target.directory.appendingPathComponent("transcript.md").path)")

    // 용어 보정까지 해야 전사가 끝난 것이다. 이걸 미루면 요약과 회의록 대조가
    // 오인식된 용어 위에서 돌고, 그 뒤에 고쳐 봐야 이미 퍼진 뒤다.
    guard !arguments.contains("--no-correct") else { return }
    print("")
    print("용어 보정 중… (문장 수에 따라 1~4분)")
    let report = await correctTranscript(directory: target.directory, session: session)
    reportCorrections(report, directory: target.directory)
}

// MARK: - clean

func runClean(arguments: [String]) {
    var days = 14
    var dryRun = false
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--days":
            index += 1
            if index < arguments.count, let value = Int(arguments[index]) { days = value }
        case "--dry-run":
            dryRun = true
        default:
            break
        }
        index += 1
    }

    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
    var purged = 0
    var freedBytes: Int64 = 0

    for entry in Store.list(limit: 1000) {
        var session = entry.session
        // 전사본이 없는 세션의 오디오는 지우지 않는다. 지우면 복구할 방법이 없다.
        guard session.status == .transcribed else { continue }
        guard let endedAt = session.endedAt, endedAt < cutoff else { continue }

        // 실시간 전사기가 쓰다 만 사이드카가 남아 있으면 같이 치운다. 세션당 수백 MB 다.
        for name in ["mic", "sys"] {
            let stray = entry.directory.appendingPathComponent("\(name).pcm")
            if FileManager.default.fileExists(atPath: stray.path), !dryRun {
                try? FileManager.default.removeItem(at: stray)
            }
        }

        var removed: [String] = []
        for track in session.tracks {
            let url = entry.directory.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if !dryRun { try? FileManager.default.removeItem(at: url) }
            freedBytes += size
            removed.append(track.file)
        }
        guard !removed.isEmpty else { continue }
        purged += 1
        print("\(dryRun ? "[dry-run] " : "")\(session.id): \(removed.joined(separator: ", ")) 삭제")
        if !dryRun {
            session.status = .audioPurged
            try? Store.save(session, to: entry.directory)
        }
    }

    let megabytes = Double(freedBytes) / 1_048_576
    if purged == 0 {
        print("\(days)일 지난 전사 완료 세션 중 삭제할 오디오가 없습니다.")
    } else {
        print(String(format: "%@세션 %d개, %.1f MB", dryRun ? "[dry-run] " : "", purged, megabytes))
    }
}
