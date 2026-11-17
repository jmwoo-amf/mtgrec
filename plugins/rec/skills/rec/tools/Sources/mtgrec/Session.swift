import Foundation

/// 세션 하나가 회의 하나다. 디렉터리 이름이 곧 세션 id 이고 그 안에
/// 오디오 · 전사본 · 요약이 모두 들어간다.
struct Session: Codable {
    enum Status: String, Codable {
        case recording        // 캡처 진행 중
        case recorded         // 오디오 확정, 전사 전
        case transcribed      // 전사본 있음
        case audioPurged      // 전사본만 남기고 오디오 삭제
        case failed
    }

    struct Track: Codable {
        var name: String        // "mic" | "sys"
        var speaker: String     // "나" | "상대"
        var file: String        // 세션 디렉터리 기준 상대 경로
        var frames: Int
        var seconds: Double
        var peak: Float
    }

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var sampleRate: Int
    var micOnly: Bool
    var muteOutput: Bool?
    /// 마이크를 파일에 쓰지 않고 시스템 오디오만 남긴다. 옛 session.json 은 nil.
    var sysOnly: Bool? = nil
    var status: Status
    var tracks: [Track]
    var recorderPID: Int32?
    var engine: String?
    var note: String?
    /// 실시간 note taker(_live 프로세스). 전부 optional 이라 이 필드를 모르던
    /// 시절의 session.json 도 그대로 디코딩된다.
    var livePID: Int32?
    var livePort: Int?
    var liveToken: String?
    /// 요약이 올라간 Notion 페이지. `/rec summary` 재실행이 이 값으로 기존
    /// 페이지를 갱신한다. 없으면 새로 만든다. 스킬(에이전트)이 채우고
    /// CLI 는 읽지도 쓰지도 않는다. 이 바이너리는 Notion 을 모른다.
    var notionPageId: String?
    var notionPageUrl: String?

    var duration: Double {
        guard let endedAt else { return Date().timeIntervalSince(startedAt) }
        return endedAt.timeIntervalSince(startedAt)
    }
}

enum Store {
    /// 저장 위치. `MTGREC_HOME` → 설정 파일의 `storage` → `Config.defaultStorage` 순이다.
    static var root: URL {
        let configured = ProcessInfo.processInfo.environment["MTGREC_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Config.shared.storage.flatMap { $0.isEmpty ? nil : $0 }
            ?? Config.defaultStorage
        return Config.expand(configured)
    }

    /// 진행 중인 세션을 가리키는 포인터. 한 번에 하나만 녹음한다.
    static var currentPointer: URL { root.appendingPathComponent(".current") }

    static func sessionDirectory(id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    static func metadataURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("session.json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func save(_ session: Session, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: metadataURL(directory), options: .atomic)
    }

    static func load(_ directory: URL) throws -> Session {
        let data = try Data(contentsOf: metadataURL(directory))
        return try decoder.decode(Session.self, from: data)
    }

    static func setCurrent(_ directory: URL?) throws {
        let fm = FileManager.default
        guard let directory else {
            if fm.fileExists(atPath: currentPointer.path) { try fm.removeItem(at: currentPointer) }
            return
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try directory.path.write(to: currentPointer, atomically: true, encoding: .utf8)
    }

    /// 진행 중 세션. 포인터가 남아 있어도 프로세스가 죽었으면 nil 을 준다.
    static func current() -> (directory: URL, session: Session)? {
        guard let path = try? String(contentsOf: currentPointer, encoding: .utf8) else { return nil }
        let directory = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let session = try? load(directory) else { return nil }
        guard session.status == .recording else { return nil }
        if let pid = session.recorderPID, kill(pid, 0) != 0 { return nil }
        return (directory, session)
    }

    /// 최근 세션부터. 디렉터리 이름이 날짜로 시작하므로 이름 역순이 시간 역순이다.
    static func list(limit: Int = 20) -> [(directory: URL, session: Session)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        // 걸러내기를 자르기보다 먼저 한다. 저장 루트에는 vocabulary.json 처럼
        // 세션이 아닌 파일도 있어서, 먼저 자르면 그것들이 자리를 차지해 목록이 빈다.
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted(by: >)
            .compactMap { name -> (directory: URL, session: Session)? in
                let directory = root.appendingPathComponent(name, isDirectory: true)
                guard let session = try? load(directory) else { return nil }
                return (directory, session)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// 사람이 준 제목을 디렉터리 이름으로 쓸 수 있게 다듬는다.
    static func makeID(title: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: date)

        let slug = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
        return slug.isEmpty ? stamp : "\(stamp)-\(slug)"
    }
}
