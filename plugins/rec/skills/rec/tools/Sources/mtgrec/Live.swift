import Foundation
import AVFoundation
import Speech
import CoreMedia

// MARK: - 트랙 따라 읽기

/// 녹음 중인 트랙을 뒤에서 따라 읽는다. 두 갈래가 있다.
///
/// **사이드카(`<트랙>.pcm`)** 가 정상 경로다. 녹음 데몬이 리샘플된 프레임을 헤더 없이
/// 붙여 쓰므로 오프셋만 들고 있으면 된다.
///
/// **WAV(`<트랙>.wav`) 직접 tail** 은 이미 돌고 있는 녹음에 뒤늦게 붙을 때만 쓴다.
/// `AVAudioFile` 밑의 `ExtAudioFile` 이 길이 필드를 close 때 확정하므로 헤더의 크기는
/// 믿을 수 없지만, data 청크의 **시작 위치**는 처음 한 번 파싱하면 고정이고 그 뒤는
/// 사이드카와 똑같은 16 kHz mono Int16 이다. 그래서 오프셋만 찾으면 같은 코드로 읽힌다.
final class TrackTail {
    private var handle: FileHandle?
    private var carry: Data = Data()
    private let url: URL
    private let isWav: Bool
    private let sampleRate: Double
    private let backfillSeconds: Double?
    private var positioned = false
    /// 이 tail 이 읽기 시작한 지점의 녹음상 시각. 뒤늦게 붙었으면 0 이 아니다.
    private(set) var startSeconds: Double = 0

    /// 사이드카가 있으면 그것을, 없으면 WAV 를 잡는다. 둘 다 없으면 nil.
    init?(directory: URL, name: String, sampleRate: Double, backfillSeconds: Double?) {
        let fm = FileManager.default
        let sidecar = directory.appendingPathComponent("\(name).pcm")
        let wav = directory.appendingPathComponent("\(name).wav")
        if fm.fileExists(atPath: sidecar.path) {
            self.url = sidecar
            self.isWav = false
        } else if fm.fileExists(atPath: wav.path) {
            self.url = wav
            self.isWav = true
        } else {
            return nil
        }
        self.sampleRate = sampleRate
        self.backfillSeconds = backfillSeconds
        // 시작 지점을 여기서 잡는다. 미루면 LiveTrack 이 startSeconds 를 0 으로 읽어
        // 뒤늦게 붙은 세션의 모든 발화 시각이 녹음 처음으로 밀린다.
        position()
    }

    var describesWavTail: Bool { isWav }

    /// 첫 읽기 전에 시작 지점을 잡는다. 파일이 아직 안 열리면 다음 호출에서 다시 시도한다.
    private func position() {
        guard handle == nil else { return }
        guard let opened = try? FileHandle(forReadingFrom: url) else { return }
        handle = opened
        guard isWav else { positioned = true; return }

        guard let dataOffset = Self.findDataChunk(opened) else {
            // 헤더를 못 읽으면 이 트랙은 포기한다. 억지로 읽으면 잡음만 나온다.
            try? opened.close()
            handle = nil
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
        let end = max(dataOffset, size)
        var start = dataOffset
        if let backfillSeconds {
            let backfillBytes = UInt64(backfillSeconds * sampleRate) * 2
            start = max(dataOffset, end > backfillBytes ? end - backfillBytes : dataOffset)
        }
        start -= (start - dataOffset) % 2      // 프레임 경계로 맞춘다
        startSeconds = Double(start - dataOffset) / 2 / sampleRate
        try? opened.seek(toOffset: start)
        positioned = true
    }

    /// RIFF 청크를 걸어 data 의 시작 바이트를 찾는다. 선언된 크기는 0 이라 쓰지 않는다.
    private static func findDataChunk(_ handle: FileHandle) -> UInt64? {
        guard let header = try? handle.read(upToCount: 64 * 1024),
              header.count > 12,
              header[0..<4].elementsEqual(Array("RIFF".utf8)),
              header[8..<12].elementsEqual(Array("WAVE".utf8)) else { return nil }
        var offset = 12
        while offset + 8 <= header.count {
            let id = header[header.startIndex + offset ..< header.startIndex + offset + 4]
            var size: UInt32 = 0
            for i in 0..<4 {
                size |= UInt32(header[header.startIndex + offset + 4 + i]) << (8 * UInt32(i))
            }
            if id.elementsEqual(Array("data".utf8)) { return UInt64(offset + 8) }
            offset += 8 + Int(size) + Int(size % 2)
        }
        return nil
    }

    /// 지난번 이후 붙은 샘플만 준다. 없으면 빈 배열.
    func next() -> [Float] {
        position()
        guard let handle, positioned else { return [] }
        // try? 가 Data?? 를 Data? 로 접는다. 읽기 실패와 EOF 를 같게 다뤄도 문제없다.
        guard let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty else { return [] }
        carry.append(data)
        let usable = carry.count - (carry.count % 2)
        guard usable > 0 else { return [] }
        let body = carry.prefix(usable)
        carry.removeFirst(usable)

        var samples = [Float](repeating: 0, count: usable / 2)
        body.withUnsafeBytes { raw in
            let pointer = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count {
                samples[i] = Float(Int16(littleEndian: pointer[i])) / 32768
            }
        }
        return samples
    }
}

// MARK: - 상태

struct TrackLevel: Codable {
    var track: String
    var speaker: String
    var peak: Float
    var silentSeconds: Double
}

struct VolatileLine: Codable {
    var track: String
    var speaker: String
    var text: String
}

struct FinishedInfo: Codable {
    struct Track: Codable {
        var name: String
        var speaker: String
        var seconds: Double
        var peak: Float
    }
    var tracks: [Track]
    var note: String?
}

struct Warning: Codable {
    var key: String
    var text: String?
}

struct LiveSnapshot: Codable {
    var title: String
    var startedAt: Date
    var micOnly: Bool
    var recording: Bool
    var segments: [Segment]
    var volatile: [VolatileLine]
    var levels: [TrackLevel]
    var notes: LiveNotes
    var finished: FinishedInfo?
    var warnings: [Warning]
}

/// 회의 중의 모든 상태가 여기 모인다. 서버 · 전사기 · 요약기가 각자 다른 스레드에서
/// 두드리므로 접근은 전부 락 안에서 한다.
final class LiveHub: @unchecked Sendable {
    private struct Pending {
        var segment: Segment
        var arrivedAt: Date
    }

    let directory: URL
    let session: Session
    let server: LiveServer
    private let lock = NSLock()

    private var published: [Segment] = []
    private var pending: [Pending] = []
    private var volatileLines: [String: VolatileLine] = [:]
    private var levels: [String: TrackLevel] = [:]
    private var lastSignalAt: [String: Date] = [:]
    private var notes: LiveNotes
    private var finished: FinishedInfo?
    private var recording = true
    private var volatileDirty = false
    private var warnings: [String: String] = [:]

    private let transcriptURL: URL
    private let notesURL: URL

    init(directory: URL, session: Session, server: LiveServer) {
        self.directory = directory
        self.session = session
        self.server = server
        self.transcriptURL = directory.appendingPathComponent("live.jsonl")
        self.notesURL = directory.appendingPathComponent("notes.json")
        // 재시작이면 디스크의 노트를 이어받는다. 커서는 0 으로 되돌아온다.
        self.notes = LiveNotes.resume(from: self.notesURL)
        for track in [("mic", "나"), ("sys", "상대")] where track.0 == "mic" ? !(session.sysOnly ?? false) : !session.micOnly {
            levels[track.0] = TrackLevel(track: track.0, speaker: track.1, peak: 0, silentSeconds: 0)
            lastSignalAt[track.0] = Date()
        }
    }

    // MARK: 쓰기

    /// 확정 발화는 바로 내보내지 않고 3초 붙잡는다. 그 사이에 반대 트랙의 같은 시각 결과가
    /// 들어오므로, 스피커 누화로 마이크가 주워 담은 상대 발언을 그때 걸러낼 수 있다.
    func enqueue(_ segment: Segment) {
        lock.lock()
        pending.append(Pending(segment: segment, arrivedAt: Date()))
        lock.unlock()
    }

    func setVolatile(track: String, speaker: String, text: String) {
        lock.lock()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            volatileLines[track] = nil
        } else {
            volatileLines[track] = VolatileLine(track: track, speaker: speaker, text: trimmed)
        }
        volatileDirty = true
        lock.unlock()
    }

    func note(level peak: Float, track: String) {
        lock.lock()
        if var entry = levels[track] {
            entry.peak = peak
            levels[track] = entry
            if peak >= 0.01 { lastSignalAt[track] = Date() }
        }
        lock.unlock()
    }

    // MARK: 읽기

    var snapshotData: Data {
        lock.lock()
        let snapshot = LiveSnapshot(title: session.title,
                                    startedAt: session.startedAt,
                                    micOnly: session.micOnly,
                                    recording: recording,
                                    segments: published,
                                    volatile: Array(volatileLines.values),
                                    levels: currentLevelsLocked(),
                                    notes: notes,
                                    finished: finished,
                                    warnings: warnings.map { Warning(key: $0.key, text: $0.value) })
        lock.unlock()
        return encode(snapshot)
    }

    /// 페이지 위쪽 배너 하나. 같은 key 로 다시 부르면 갈아치우고, nil 이면 내린다.
    func warn(key: String, text: String?) {
        lock.lock()
        if let text { warnings[key] = text } else { warnings[key] = nil }
        lock.unlock()
        server.broadcast(event: "warning", data: encode(Warning(key: key, text: text)))
    }

    private func currentLevelsLocked() -> [TrackLevel] {
        let now = Date()
        return levels.keys.sorted().map { key in
            var entry = levels[key]!
            entry.silentSeconds = now.timeIntervalSince(lastSignalAt[key] ?? now)
            return entry
        }
    }

    // MARK: 주기 작업

    /// 붙잡아 둔 확정 발화 중 3초가 지난 것을 내보낸다.
    func flushPending(force: Bool = false) {
        lock.lock()
        let now = Date()
        let ready = pending.filter { force || now.timeIntervalSince($0.arrivedAt) >= 3.0 }
        guard !ready.isEmpty else { lock.unlock(); return }
        let held = pending.filter { !(force || now.timeIntervalSince($0.arrivedAt) >= 3.0) }

        // 누화 판정에 쓸 창. 이미 내보낸 최근 발화 + 아직 붙잡고 있는 것 전부를 넣어야
        // 반대 트랙의 짝을 만난다. removeSpeakerBleed 는 mic 조각만 떨어뜨린다.
        let horizon = (ready.map { $0.segment.start }.min() ?? 0) - 30
        var window = published.filter { $0.end >= horizon }
        window.append(contentsOf: ready.map { $0.segment })
        window.append(contentsOf: held.map { $0.segment })
        window.sort { $0.start < $1.start }
        let (kept, _) = removeSpeakerBleed(window)
        let survivors = Set(kept.map(Self.key))

        let accepted = ready.map { $0.segment }.filter { survivors.contains(Self.key($0)) }
        pending = held
        published.append(contentsOf: accepted)
        published.sort { $0.start < $1.start }
        lock.unlock()

        guard !accepted.isEmpty else { return }
        appendTranscript(accepted)
        server.broadcast(event: "segments", data: encode(accepted))
    }

    private static func key(_ segment: Segment) -> String {
        "\(segment.track)|\(Int(segment.start * 100))|\(segment.text)"
    }

    func pushVolatileIfChanged() {
        lock.lock()
        guard volatileDirty else { lock.unlock(); return }
        volatileDirty = false
        let lines = Array(volatileLines.values)
        lock.unlock()
        server.broadcast(event: "volatile", data: encode(lines))
    }

    func pushLevels() {
        lock.lock()
        let current = currentLevelsLocked()
        lock.unlock()
        server.broadcast(event: "levels", data: encode(current))
    }

    // MARK: 요약

    /// 요약을 돌릴 때인지 본다. 새 발화가 충분히 쌓였거나, 조금이라도 쌓인 채로
    /// 하한 시간이 지났으면 돌린다. 조용한 구간에서 헛돌지 않게 하려는 것이다.
    func summaryDue(minimumCharacters: Int, minimumInterval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !notes.running else { return false }
        guard notes.cursor < published.count else { return false }
        let fresh = published[notes.cursor...].reduce(0) { $0 + $1.text.count }
        if fresh >= minimumCharacters { return true }
        let since = notes.updatedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        return fresh > 0 && since >= minimumInterval
    }

    /// 사이클 하나. 실패하면 직전 노트를 그대로 두고 `lastError` 만 남긴다.
    /// 회의 중에 노트가 사라지는 것이 요약이 한 번 실패하는 것보다 나쁘다.
    ///
    /// 창을 상한으로 자르는 이유가 있다. 예전에는 `published[cursor...]` 전체를
    /// 실었고 실패해도 커서를 안 옮겼다. 그래서 한 번 타임아웃하면 다음 재시도가
    /// 반드시 더 커졌고 영구 실패로 굳었다. 실제 회의 하나가
    /// 그렇게 105분에서 멈췄다 (창이 8,379자로 자라 설계치 1,500자의 6배).
    /// 이제 밀린 것은 15초마다 한 창씩 흘려보내며 따라잡는다.
    func runSummary(_ summarizer: Summarizer, rules: String, glossary: [String],
                    windowCharacters: Int) {
        lock.lock()
        guard !notes.running, notes.cursor < published.count else { lock.unlock(); return }
        notes.running = true
        let carry = notes

        // 창을 문자 수로 자른다. 세그먼트 하나가 상한을 넘어도 최소 하나는 싣는다.
        // 그러지 않으면 긴 발화 하나에 사이클이 영구히 걸린다.
        //
        // 실패했으면 다음 재시도의 창을 절반으로 줄인다. 같은 크기로 세 번
        // 되풀이하면 세 번 다 같은 이유로 타임아웃하고 그 구간을 버린다.
        // 실제 회의 하나가 그렇게 10분 넘는 구간을 잃었다.
        let effectiveWindow = max(400, windowCharacters >> min(notes.consecutiveFailures, 3))
        var window: [Segment] = []
        var budget = 0
        for segment in published[notes.cursor...] {
            if !window.isEmpty, budget + segment.text.count > effectiveWindow { break }
            window.append(segment)
            budget += segment.text.count
        }
        let cursor = notes.cursor + window.count
        let backlog = published.count - cursor
        let elapsed = window.last?.end ?? published.last?.end ?? 0
        lock.unlock()
        broadcastNotes()

        let prompt = buildSummaryPrompt(notes: carry, newSegments: window,
                                        elapsed: elapsed, glossary: glossary)
        let saved: LiveNotes
        do {
            let reply = try summarizer.run(prompt: prompt, rules: rules)
            // 스키마를 통과했다고 쓸 수 있는 노트인 것은 아니다. 퇴행이면 던져서
            // 아래 실패 경로로 보낸다. 그 경로는 직전 노트를 그대로 둔다.
            try validateNoteReply(headline: reply.headline, topics: reply.topics,
                                  actions: reply.actions, against: carry)
            lock.lock()
            notes.headline = reply.headline
            notes.topics = reply.topics
            notes.actions = reply.actions
            notes.cursor = cursor
            notes.updatedAt = Date()
            notes.lastError = nil
            notes.consecutiveFailures = 0
            if notes.coveredFromSeconds == nil { notes.coveredFromSeconds = window.first?.start }
            notes.coveredUntilSeconds = window.last?.end ?? notes.coveredUntilSeconds
            notes.running = false
            saved = notes
            lock.unlock()
            warn(key: "notes", text: nil)
            // 통과한 노트만 별도로 남긴다. `notes.json` 이 무엇에 덮여도 여기가 남는다.
            appendNoteHistory(saved)
        } catch {
            lock.lock()
            notes.lastError = "\(error)"
            notes.consecutiveFailures += 1
            // 세 번 놓친 창은 버린다. 붙들고 있으면 그 뒤 발화가 전부 노트에
            // 안 들어간다. 버린 사실은 `gaps` 에 남겨 나중에 셀 수 있게 한다.
            let abandoning = notes.consecutiveFailures >= 3
            if abandoning {
                notes.gaps.append(LiveNotes.Gap(
                    fromSeconds: window.first?.start ?? 0,
                    toSeconds: window.last?.end ?? 0,
                    reason: "요약 3회 실패: \(notes.lastError ?? "")"))
                notes.cursor = cursor
                notes.consecutiveFailures = 0
                notes.coveredUntilSeconds = window.last?.end ?? notes.coveredUntilSeconds
            }
            notes.running = false
            saved = notes
            lock.unlock()
            warn(key: "notes", text: abandoning
                 ? "요약이 \(formatTimestamp(window.first?.start ?? 0)) 구간을 건너뛰었습니다. 전사본에는 남아 있습니다."
                 : "요약 사이클 실패 (\(saved.consecutiveFailures)회). 직전 노트를 그대로 둡니다.")
        }
        // 성공이든 실패든 쓴다. 예전에는 실패 경로가 디스크에 안 써서 `notes.json` 이
        // 마지막 성공 시점에 얼어붙었고 `lastError` 가 `null` 로 남아 실패가 보이지 않았다.
        write(saved, to: notesURL)
        if backlog > 0 {
            FileHandle.standardError.write(
                "요약: \(window.count)개 처리, \(backlog)개 밀림\n".data(using: .utf8)!)
        }
        broadcastNotes()
    }

    /// 검증을 통과한 노트를 `notes.last-good.json` 에 갈아 쓰고
    /// `notes.history.jsonl` 에 한 줄 덧붙인다. 이력은 지우지 않는다.
    /// 사이클 한 번에 3KB 안팎이라 두 시간 회의에서 100KB 를 넘지 않는다.
    private func appendNoteHistory(_ note: LiveNotes) {
        write(note, to: LiveNotes.lastGoodURL(besides: notesURL))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(note) else { return }
        line.append(0x0A)
        let url = LiveNotes.historyURL(besides: notesURL)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    private func broadcastNotes() {
        lock.lock()
        let current = notes
        lock.unlock()
        server.broadcast(event: "notes", data: encode(current))
    }

    // MARK: 종료

    func markFinished(_ info: FinishedInfo?) {
        lock.lock()
        recording = false
        finished = info
        volatileLines = [:]
        lock.unlock()
        struct Status: Codable { var recording: Bool; var finished: FinishedInfo? }
        server.broadcast(event: "status", data: encode(Status(recording: false, finished: info)))
    }

    // MARK: 저장

    /// 실시간 결과는 `transcript.md` 와 겹치지 않는 자리에 남긴다. 정본은 종료 후
    /// 오프라인 패스가 만드는 `transcript.md` 이고 이 파일은 그 미리보기의 기록이다.
    private func appendTranscript(_ segments: [Segment]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        var lines = ""
        for segment in segments {
            guard let data = try? encoder.encode(segment),
                  let text = String(data: data, encoding: .utf8) else { continue }
            lines += text + "\n"
        }
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: transcriptURL.path) {
            fm.createFile(atPath: transcriptURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: transcriptURL) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(lines.utf8))
        try? handle.close()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)) ?? Data("null".utf8)
    }
}

// MARK: - 트랙 하나의 스트리밍 전사

/// 사이드카를 읽어 분석기에 밀어넣고, 나오는 결과를 허브에 넣는다.
/// 파일 단위 전사(`transcribeTrack`)와 문장 분할 · 용어 치환 로직을 공유한다.
final class LiveTrack: @unchecked Sendable {
    private let name: String
    private let speaker: String
    private let reader: TrackTail
    private let hub: LiveHub
    private let vocabulary: Vocabulary
    private let sampleRate: Double
    /// 분석기의 시계는 처음 밀어넣은 샘플에서 0 으로 출발한다. 녹음 도중에 붙었으면
    /// 그 0 이 녹음의 0 이 아니므로, 결과 시각에 이 값을 더해 녹음 시계로 되돌린다.
    private let timeOffset: Double

    private var feedTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(name: String, speaker: String, tail: TrackTail, hub: LiveHub,
         vocabulary: Vocabulary, sampleRate: Double) {
        self.name = name
        self.speaker = speaker
        self.reader = tail
        self.hub = hub
        self.vocabulary = vocabulary
        self.sampleRate = sampleRate
        self.timeOffset = tail.startSeconds
    }

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])

        let context = AnalysisContext()
        if !vocabulary.terms.isEmpty {
            context.contextualStrings[.general] = vocabulary.terms
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        self.analyzer = analyzer

        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecorderError.message("입력 포맷을 만들 수 없습니다 (\(name))")
        }
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let targetFormat = analyzerFormat ?? sourceFormat
        let converter = targetFormat == sourceFormat ? nil : AVAudioConverter(from: sourceFormat, to: targetFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        try await analyzer.start(inputSequence: stream)

        // 결과 소비를 먼저 띄운다. 아무도 안 받으면 분석이 막힌다.
        consumeTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    if result.isFinal {
                        self.acceptFinal(result.text, range: result.range)
                        self.hub.setVolatile(track: self.name, speaker: self.speaker, text: "")
                    } else {
                        self.hub.setVolatile(track: self.name, speaker: self.speaker,
                                             text: self.vocabulary.apply(to: String(result.text.characters)))
                    }
                }
            } catch {
                FileHandle.standardError.write("\(self.name) 전사 스트림 종료: \(error)\n".data(using: .utf8)!)
                self.hub.warn(key: "stt-\(self.name)",
                              text: "\(self.speaker) 트랙의 실시간 전사가 끊겼습니다. 녹음은 계속되고, 종료 후 전사로 복구됩니다.")
            }
        }

        feedTask = Task { [weak self] in
            await self?.feed(sourceFormat: sourceFormat, targetFormat: targetFormat, converter: converter)
        }
    }

    /// 사이드카에 붙은 만큼 읽어 분석기가 받는 포맷으로 바꿔 흘려보낸다.
    /// 0.2초 미만은 모아서 보낸다. 조각이 너무 잘면 인식이 흔들린다.
    ///
    /// `bufferStartTime` 은 주지 않는다. 리샘플링이 걸리면 변환된 프레임 수가 요청한
    /// 비율과 몇 프레임씩 어긋나는데, 그 상태에서 시각을 직접 매기면 분석기가
    /// `Audio input timestamp overlaps or precedes prior audio input` 으로 스트림을 닫는다.
    /// 파일 처음부터 순서대로 밀어넣으므로 분석기가 스스로 세는 시각이 곧 녹음 시각이다.
    private func feed(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat,
                      converter: AVAudioConverter?) async {
        var accumulator: [Float] = []
        let minimumFrames = Int(sampleRate * 0.2)

        while !Task.isCancelled {
            let samples = reader.next()
            if !samples.isEmpty {
                accumulator.append(contentsOf: samples)
                hub.note(level: samples.reduce(0) { max($0, abs($1)) }, track: name)
            }
            if accumulator.count >= minimumFrames {
                let batch = accumulator
                accumulator = []
                if let buffer = makeBuffer(batch, format: sourceFormat) {
                    if let converter {
                        if let converted = convert(buffer, with: converter, to: targetFormat) {
                            continuation?.yield(AnalyzerInput(buffer: converted))
                        }
                    } else {
                        continuation?.yield(AnalyzerInput(buffer: buffer))
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<samples.count { channel[i] = samples[i] }
        return buffer
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func acceptFinal(_ text: AttributedString, range: CMTimeRange) {
        for piece in splitIntoSentences(text, fallbackRange: range) {
            guard hasContent(piece.text) else { continue }
            hub.enqueue(Segment(start: piece.start + timeOffset,
                                end: piece.end + timeOffset,
                                track: name,
                                speaker: speaker,
                                text: vocabulary.apply(to: piece.text),
                                confidence: piece.confidence))
        }
    }

    /// 입력을 닫고 남은 결과를 확정시킨다.
    func finish() async {
        feedTask?.cancel()
        continuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await consumeTask?.value
    }
}

// MARK: - _live 데몬

/// 종료 경로가 셋(페이지 · 녹음 종료 감지 · 시그널)이라 서로 겹칠 수 있다.
/// 먼저 도착한 하나만 통과시킨다.
private final class ShutdownGate: @unchecked Sendable {
    let tracks: [LiveTrack]
    private let lock = NSLock()
    private var claimed = false

    init(tracks: [LiveTrack]) { self.tracks = tracks }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private enum ShutdownReason {
    case page       // 페이지의 「녹음 종료」
    case recorder   // 녹음 프로세스가 먼저 끝났다 (터미널의 mtgrec stop)
    case signal     // 누가 이 프로세스를 직접 끝냈다
}

func runLive(arguments: [String]) async {
    guard let path = arguments.first else { fail("_live 에 세션 경로가 필요합니다") }
    let directory = URL(fileURLWithPath: path)
    guard let session = try? Store.load(directory) else { fail("세션을 읽을 수 없습니다: \(path)") }
    // 이미 돌고 있는 녹음에 뒤늦게 붙는 경우. 사이드카가 없으므로 WAV 를 직접 따라 읽는다.
    let attaching = arguments.contains("--attach")

    let environment = ProcessInfo.processInfo.environment
    let minimumCharacters = environment["MTGREC_SUMMARY_CHARS"].flatMap(Int.init) ?? 1500
    let minimumInterval = environment["MTGREC_SUMMARY_SECONDS"].flatMap(Double.init) ?? 300
    // 한 사이클이 실을 발화의 상한. 밀린 것은 여러 사이클로 나눠 따라잡는다.
    // 상한이 없으면 실패가 재시도를 키우고 재시도가 다시 실패한다.
    let windowCharacters = environment["MTGREC_SUMMARY_WINDOW"].flatMap(Int.init)
        ?? max(minimumCharacters * 2, 3000)
    let linger = environment["MTGREC_LIVE_LINGER"].flatMap(Double.init) ?? 600
    // 뒤늦게 붙었을 때 거슬러 올라가 읽을 분량. 앞부분 전체를 다시 돌리면 회의 중에
    // 몇 분을 따라잡느라 쓰는데, 그 구간은 어차피 종료 후 오프라인 패스가 정확히 훑는다.
    let backfill = environment["MTGREC_ATTACH_BACKFILL"].flatMap(Double.init) ?? 300

    let server = LiveServer()
    do {
        try server.start(preferred: environment["MTGREC_PORT"].flatMap(UInt16.init))
    } catch {
        fail("페이지 서버를 열 수 없습니다: \(error)")
    }

    let hub = LiveHub(directory: directory, session: session, server: server)
    server.snapshot = { hub.snapshotData }

    // 세션에 접속 정보를 남긴다. start 명령이 이걸 읽어 URL 을 찍는다.
    var stamped = session
    stamped.livePID = ProcessInfo.processInfo.processIdentifier
    stamped.livePort = Int(server.port)
    stamped.liveToken = server.token
    try? Store.save(stamped, to: directory)

    let vocabulary = Vocabulary.load()
    let summarizer = Summarizer.fromEnvironment(workingDirectory: directory)
    let rules = SummaryRules.load()
    let glossarySection = buildGlossarySection(vocabulary)
    let locale = Locale(identifier: "ko-KR")
    let summaryQueue = DispatchQueue(label: "mtgrec.summary")

    var tracks: [LiveTrack] = []
    do {
        try await ensureModelInstalled(locale: locale)
        var wanted: [(String, String)] = []
        if !(session.sysOnly ?? false) { wanted.append(("mic", "나")) }
        if !session.micOnly { wanted.append(("sys", "상대")) }
        for (name, speaker) in wanted {
            guard let tail = TrackTail(directory: directory, name: name,
                                       sampleRate: Double(session.sampleRate),
                                       backfillSeconds: attaching ? backfill : nil) else {
                FileHandle.standardError.write("\(name) 트랙 파일이 없습니다\n".data(using: .utf8)!)
                continue
            }
            let track = LiveTrack(name: name, speaker: speaker, tail: tail, hub: hub,
                                  vocabulary: vocabulary, sampleRate: Double(session.sampleRate))
            try await track.start(locale: locale)
            tracks.append(track)
        }
        if attaching {
            hub.warn(key: "attached",
                     text: "녹음 도중에 붙었습니다. 이 페이지는 최근 \(Int(backfill / 60))분부터만 전사합니다. 그 앞은 종료 후 전사가 채웁니다.")
        }
    } catch {
        // 실시간 전사가 안 되더라도 녹음은 계속되어야 한다. 여기서 죽지 않고 알리기만 한다.
        FileHandle.standardError.write("실시간 전사를 시작하지 못했습니다: \(error)\n".data(using: .utf8)!)
    }

    let closer = ShutdownGate(tracks: tracks)

    @Sendable func shutdown(_ reason: ShutdownReason) {
        guard closer.claim() else { return }

        Task {
            for track in closer.tracks { await track.finish() }
            hub.flushPending(force: true)

            // 마지막 조각까지 노트에 반영한다. 신호로 끊긴 경우는 기다리게 하지 않는다.
            if reason != .signal, hub.summaryDue(minimumCharacters: 1, minimumInterval: 0) {
                hub.runSummary(summarizer, rules: rules, glossary: glossarySection,
                               windowCharacters: windowCharacters)
            }

            let final = try? Store.load(directory)
            let info = final.map { session in
                FinishedInfo(tracks: session.tracks.map {
                    FinishedInfo.Track(name: $0.name, speaker: $0.speaker,
                                       seconds: $0.seconds, peak: $0.peak)
                }, note: session.note)
            }
            hub.markFinished(info)

            // 사이드카는 여기서만 지운다. 이 프로세스가 마지막 독자다.
            for name in ["mic", "sys"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).pcm"))
            }
            if var stored = try? Store.load(directory) {
                stored.livePID = nil
                try? Store.save(stored, to: directory)
            }

            // 페이지를 바로 닫지 않는다. 회의 직후에 노트를 마저 읽는 시간이다.
            let hold = reason == .signal ? 0.5 : linger
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            server.stop()
            exit(0)
        }
    }

    server.onSummarize = {
        summaryQueue.async {
            hub.runSummary(summarizer, rules: rules, glossary: glossarySection,
                           windowCharacters: windowCharacters)
        }
    }
    server.onStop = {
        guard let pid = (try? Store.load(directory))?.recorderPID else {
            shutdown(.page)
            return
        }
        kill(pid, SIGTERM)
        // 녹음 데몬이 버퍼를 비우고 session.json 을 확정할 때까지 기다린다.
        DispatchQueue.global().async {
            for _ in 0..<150 {
                Thread.sleep(forTimeInterval: 0.1)
                if let updated = try? Store.load(directory), updated.status != .recording { break }
            }
            shutdown(.page)
        }
    }

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    termSource.setEventHandler { shutdown(.signal) }
    intSource.setEventHandler { shutdown(.signal) }
    termSource.resume()
    intSource.resume()

    print("live: \(server.url)")

    // 주기 작업. 전부 짧고 락 안에서만 상태를 만진다.
    var ticks = 0
    while true {
        try? await Task.sleep(nanoseconds: 500_000_000)
        ticks += 1
        hub.flushPending()
        hub.pushVolatileIfChanged()
        if ticks % 4 == 0 { hub.pushLevels() }
        if ticks % 60 == 0 { server.heartbeat() }

        if ticks % 30 == 0,
           hub.summaryDue(minimumCharacters: minimumCharacters, minimumInterval: minimumInterval) {
            summaryQueue.async {
                hub.runSummary(summarizer, rules: rules, glossary: glossarySection,
                               windowCharacters: windowCharacters)
            }
        }

        // 녹음이 먼저 끝났으면(터미널에서 mtgrec stop) 따라 내려간다.
        if ticks % 4 == 0 {
            let stored = try? Store.load(directory)
            let alive = stored?.recorderPID.map { kill($0, 0) == 0 } ?? false
            if stored?.status != .recording || !alive {
                shutdown(.recorder)
            }
        }
    }
}
