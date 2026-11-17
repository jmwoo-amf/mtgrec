import Foundation

let usage = """
mtgrec - 회의 로컬 녹음과 온디바이스 전사

  mtgrec start [제목] [--mic-only | --sys-only] [--mute] [--no-live]
                                     녹음 시작 (백그라운드)
                                     --mic-only 시스템 오디오 없이 마이크만
                                     --sys-only 마이크 없이 시스템 오디오만 (내 목소리를 남기지 않음)
                                     --mute     탭으로 받되 스피커로는 안 내보냄
                                     --no-live  실시간 페이지와 요약을 띄우지 않음
  mtgrec stop                        녹음 종료 후 트랙 요약
  mtgrec status                      진행 여부와 경과 시간, 실시간 페이지 주소
  mtgrec live                        진행 중 세션의 실시간 페이지 주소
  mtgrec list [-n N]                 최근 세션 목록
  mtgrec transcribe [세션] [--no-correct]
                                     전사. 이어서 도메인 용어를 문맥 보고 보정
  mtgrec correct [세션]              용어 보정만 다시. 용어집을 고친 뒤 돌린다
  mtgrec clean [--days N] [--dry-run] 전사 끝난 세션의 오디오 삭제
  mtgrec config                      설정 파일 · 저장 위치 · 용어집 · 규칙 파일 경로를 보여준다
  mtgrec notion [세션] --page-id <id> [--page-url <url>]
                                     요약이 올라간 Notion 페이지를 기록한다.
                                     /rec summary 재실행이 이 값으로 갱신한다

세션은 ~/.config/mtgrec/config.json 의 storage 아래에 쌓인다 (없으면 ~/Recordings/mtgrec).
MTGREC_HOME 이 있으면 그것이 이긴다.

실시간 페이지는 127.0.0.1 에만 뜬다. 전사는 온디바이스이고, 요약만 헤드리스 claude 를
부르므로 전사 텍스트가 단말 밖으로 나간다. 그것을 원하지 않으면 --no-live 로 끈다.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("mtgrec: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                     : String(format: "%d:%02d", minutes, secs)
}

// MARK: - start

func commandStart(arguments: [String]) {
    if let existing = Store.current() {
        fail("이미 녹음 중입니다: \(existing.session.title) (\(formatDuration(existing.session.duration)) 경과). 먼저 mtgrec stop 을 하십시오")
    }

    var micOnly = false
    var sysOnly = false
    var muteOutput = false
    var live = true
    var titleParts: [String] = []
    for argument in arguments {
        switch argument {
        case "--mic-only": micOnly = true
        case "--sys-only": sysOnly = true
        case "--mute": muteOutput = true
        case "--no-live": live = false
        default: titleParts.append(argument)
        }
    }
    if micOnly && sysOnly { fail("--mic-only 와 --sys-only 는 함께 쓸 수 없습니다") }
    let title = titleParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    let now = Date()
    let id = Store.makeID(title: title, at: now)
    let directory = Store.sessionDirectory(id: id)

    let session = Session(id: id,
                          title: title.isEmpty ? id : title,
                          startedAt: now,
                          endedAt: nil,
                          sampleRate: 16000,
                          micOnly: micOnly,
                          muteOutput: muteOutput,
                          sysOnly: sysOnly,
                          status: .recording,
                          tracks: [],
                          recorderPID: nil,
                          engine: nil,
                          note: nil)
    do { try Store.save(session, to: directory) } catch { fail("세션을 만들 수 없습니다: \(error)") }

    // 캡처는 별도 프로세스가 맡는다. CLI 가 끝나도 녹음이 계속되어야 하기 때문이다.
    let logURL = directory.appendingPathComponent("record.log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    guard let logHandle = try? FileHandle(forWritingTo: logURL) else { fail("로그 파일을 열 수 없습니다") }

    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let process = Process()
    process.executableURL = executable
    // 사이드카는 실시간 전사기가 따라 읽으려고 쓰는 것이다. 안 띄울 거면 쓰지 않는다.
    process.arguments = ["_record", directory.path] + (live ? ["--sidecar"] : [])
    process.standardOutput = logHandle
    process.standardError = logHandle
    do { try process.run() } catch { fail("녹음 프로세스를 띄울 수 없습니다: \(error)") }

    // 자식이 캡처를 실제로 시작했는지 확인하고 나서 성공을 알린다.
    var started = false
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.1)
        if let updated = try? Store.load(directory) {
            if updated.recorderPID != nil { started = true; break }
            if updated.status == .failed {
                let reason = updated.note ?? "알 수 없는 오류"
                fail("녹음을 시작하지 못했습니다: \(reason)")
            }
        }
        if !process.isRunning { break }
    }
    guard started else {
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        fail("녹음이 시작되지 않았습니다.\n\(log)")
    }

    try? Store.setCurrent(directory)
    print("녹음 시작: \(session.title)")
    print("  세션: \(directory.path)")
    print("  트랙: \(micOnly ? "마이크만" : sysOnly ? "시스템 오디오(상대)만. 마이크는 기록하지 않음" : "마이크(나) + 시스템 오디오(상대)")")
    if muteOutput {
        print("  출력: 음소거. 녹음이 끝날 때까지 이 맥의 스피커로는 아무 소리도 나오지 않습니다")
    }
    if live {
        if let url = startLive(executable: executable, directory: directory) {
            print("  실시간: \(url)")
        } else {
            print("  실시간: 페이지를 띄우지 못했습니다. 녹음은 그대로 진행됩니다 (\(directory.path)/live.log)")
        }
    }
    print("")
    print("회의 참석자에게 녹음 사실을 알리십시오. 끝나면 mtgrec stop.")
}

/// 실시간 페이지 프로세스를 띄우고 주소를 준다.
///
/// **실패해도 녹음을 막지 않는다.** 이쪽은 부가 기능이고 녹음이 본체다.
/// 포트를 못 잡거나 전사 모델을 못 내려받았을 때 회의가 통째로 날아가면 안 된다.
private func startLive(executable: URL, directory: URL, attach: Bool = false) -> String? {
    let logURL = directory.appendingPathComponent("live.log")
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    guard let logHandle = try? FileHandle(forWritingTo: logURL) else { return nil }
    _ = try? logHandle.seekToEnd()

    let process = Process()
    process.executableURL = executable
    process.arguments = ["_live", directory.path] + (attach ? ["--attach"] : [])
    process.standardOutput = logHandle
    process.standardError = logHandle
    do { try process.run() } catch { return nil }

    // 서버가 실제로 포트를 잡았는지 확인하고 나서 주소를 준다.
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.1)
        if let updated = try? Store.load(directory),
           let port = updated.livePort, let token = updated.liveToken, updated.livePID != nil {
            return "http://127.0.0.1:\(port)/?t=\(token)"
        }
        if !process.isRunning { return nil }
    }
    return nil
}

// MARK: - _record (내부 데몬)

func commandRecord(arguments: [String]) {
    guard let path = arguments.first else { fail("_record 에 세션 경로가 필요합니다") }
    let directory = URL(fileURLWithPath: path)
    guard var session = try? Store.load(directory) else { fail("세션을 읽을 수 없습니다: \(path)") }
    let sidecar = arguments.contains("--sidecar")

    let recorder = Recorder(targetRate: Double(session.sampleRate),
                            micOnly: session.micOnly,
                            sysOnly: session.sysOnly ?? false,
                            muteOutput: session.muteOutput ?? false,
                            writeSidecar: sidecar)
    do {
        try recorder.start(directory: directory)
    } catch {
        session.status = .failed
        session.note = "\(error)"
        session.endedAt = Date()
        try? Store.save(session, to: directory)
        fail("\(error)")
    }

    session.recorderPID = ProcessInfo.processInfo.processIdentifier
    try? Store.save(session, to: directory)

    // SIGTERM 을 받으면 남은 버퍼를 비우고 정상 종료한다. 기본 동작은 즉시 죽는 것이라
    // 파일 끝이 잘리므로 반드시 가로챈다.
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let group = DispatchGroup()
    group.enter()
    var finished = false
    let finish = {
        guard !finished else { return }
        finished = true
        group.leave()
    }
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    termSource.setEventHandler { finish() }
    intSource.setEventHandler { finish() }
    termSource.resume()
    intSource.resume()

    DispatchQueue.global().async {
        group.wait()
        let tracks = recorder.stop()
        // 시작할 때 읽어 둔 것을 그대로 쓰면 그 사이에 _live 가 적어 넣은 접속 정보를
        // 덮어쓴다. 디스크의 현재 상태를 다시 읽고 내 필드만 얹는다.
        var final = (try? Store.load(directory)) ?? session
        final.tracks = tracks
        final.endedAt = Date()
        final.status = tracks.contains(where: { $0.frames > 0 }) ? .recorded : .failed
        if recorder.droppedFrames > 0 {
            final.note = "버퍼 오버런으로 \(recorder.droppedFrames) 프레임 유실"
        }
        if final.status == .failed && final.note == nil {
            final.note = "캡처된 오디오가 없습니다"
        }
        try? Store.save(final, to: directory)
        try? Store.setCurrent(nil)
        exit(0)
    }

    dispatchMain()
}

// MARK: - stop

func commandStop() {
    guard let current = Store.current() else {
        fail("진행 중인 녹음이 없습니다")
    }
    guard let pid = current.session.recorderPID else {
        fail("녹음 프로세스를 찾을 수 없습니다")
    }

    kill(pid, SIGTERM)

    var final: Session?
    for _ in 0..<150 {
        Thread.sleep(forTimeInterval: 0.1)
        if let updated = try? Store.load(current.directory), updated.status != .recording {
            final = updated
            break
        }
    }
    guard let final else {
        fail("녹음 프로세스가 15초 안에 끝나지 않았습니다. 세션: \(current.directory.path)")
    }

    print("녹음 종료: \(final.title)")
    print("  길이: \(formatDuration(final.duration))")
    for track in final.tracks {
        let level = track.peak > 0.01 ? "" : "  (무음에 가까움)"
        print(String(format: "  %@ (%@): %@ peak %.3f%@",
                     track.name, track.speaker, formatDuration(track.seconds), track.peak, level))
    }
    if let note = final.note { print("  비고: \(note)") }
    print("  세션: \(current.directory.path)")

    // 실시간 프로세스는 녹음이 끝난 것을 스스로 알아채고 마지막 요약까지 한 뒤 내려간다.
    // 여기서 죽이면 회의 직후에 노트를 마저 읽을 창이 사라진다.
    if let pid = final.livePID, kill(pid, 0) == 0,
       let port = final.livePort, let token = final.liveToken {
        print("  실시간 페이지는 잠시 더 열려 있습니다: http://127.0.0.1:\(port)/?t=\(token)")
    } else {
        // 실시간이 안 떴거나 이미 죽었으면 사이드카를 치울 사람이 없다.
        for name in ["mic", "sys"] {
            try? FileManager.default.removeItem(
                at: current.directory.appendingPathComponent("\(name).pcm"))
        }
    }
}

// MARK: - live

func commandLive() {
    guard let current = Store.current() else {
        fail("진행 중인 녹음이 없습니다")
    }
    if let port = current.session.livePort, let token = current.session.liveToken,
       let pid = current.session.livePID, kill(pid, 0) == 0 {
        print("http://127.0.0.1:\(port)/?t=\(token)")
        return
    }

    // 페이지 없이 시작한 녹음에 뒤늦게 붙는다. 사이드카가 없으므로 _live 가 WAV 를 따라 읽는다.
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    guard let url = startLive(executable: executable, directory: current.directory, attach: true) else {
        fail("실시간 페이지를 띄우지 못했습니다: \(current.directory.path)/live.log")
    }
    print(url)
    print("녹음 도중에 붙었으므로 최근 구간부터만 전사합니다. 앞부분은 종료 후 전사가 채웁니다.")
}

// MARK: - status / list

func commandStatus() {
    if let current = Store.current() {
        print("녹음 중: \(current.session.title)")
        print("  경과: \(formatDuration(current.session.duration))")
        print("  세션: \(current.directory.path)")
        if let port = current.session.livePort, let token = current.session.liveToken,
           let pid = current.session.livePID, kill(pid, 0) == 0 {
            print("  실시간: http://127.0.0.1:\(port)/?t=\(token)")
        }
        return
    }
    print("녹음 중이 아닙니다.")
    let recent = Store.list(limit: 3)
    if !recent.isEmpty {
        print("\n최근 세션:")
        for entry in recent {
            print("  \(entry.session.id)  [\(entry.session.status.rawValue)]  \(formatDuration(entry.session.duration))")
        }
    }
}

func commandList(arguments: [String]) {
    var limit = 20
    if let index = arguments.firstIndex(of: "-n"), index + 1 < arguments.count,
       let value = Int(arguments[index + 1]) { limit = value }
    let sessions = Store.list(limit: limit)
    if sessions.isEmpty { print("세션이 없습니다."); return }
    for entry in sessions {
        let session = entry.session
        print("\(session.id)")
        print("  제목 \(session.title)  길이 \(formatDuration(session.duration))  상태 \(session.status.rawValue)")
    }
}

// MARK: - dispatch

/// 스킬이 만든 Notion 요약 페이지를 session.json 에 기록한다.
///
/// 이 바이너리는 Notion 을 모른다. 페이지를 만드는 것은 스킬(에이전트)이고,
/// 여기서 하는 일은 그 결과를 세션 메타데이터에 원자적으로 얹는 것뿐이다.
/// 스킬이 JSON 을 손으로 편집하면 다른 필드가 깨질 수 있어 경로를 하나 둔다.
func commandNotion(arguments: [String]) {
    var sessionArg: String?
    var pageId: String?
    var pageUrl: String?
    var i = 0
    while i < arguments.count {
        switch arguments[i] {
        case "--page-id":
            i += 1; pageId = i < arguments.count ? arguments[i] : nil
        case "--page-url":
            i += 1; pageUrl = i < arguments.count ? arguments[i] : nil
        default:
            if sessionArg == nil { sessionArg = arguments[i] }
        }
        i += 1
    }
    guard let pageId, !pageId.isEmpty else {
        fail("--page-id 가 필요합니다.\n\n  mtgrec notion [세션] --page-id <id> [--page-url <url>]")
    }

    let directory: URL
    if let sessionArg {
        directory = Store.sessionDirectory(id: sessionArg)
    } else if let latest = Store.list(limit: 1).first {
        directory = latest.directory
    } else {
        fail("세션이 없습니다.")
    }
    guard FileManager.default.fileExists(atPath: Store.metadataURL(directory).path) else {
        fail("session.json 이 없습니다: \(directory.path)")
    }

    do {
        var session = try Store.load(directory)
        let previous = session.notionPageId
        session.notionPageId = pageId
        session.notionPageUrl = pageUrl
        try Store.save(session, to: directory)
        if let previous, previous != pageId {
            print("페이지 id 교체: \(previous) -> \(pageId)")
        } else {
            print("페이지 id 기록: \(pageId)")
        }
        if let pageUrl { print("  \(pageUrl)") }
    } catch {
        fail("session.json 을 고칠 수 없습니다: \(error.localizedDescription)")
    }
}

// MARK: - config

/// 지금 바이너리가 실제로 무엇을 읽는지 보여준다. 설정이 안 먹을 때 가장 먼저 본다.
func commandConfig() {
    let fm = FileManager.default
    let configExists = fm.fileExists(atPath: Config.fileURL.path)
    print("설정 파일: \(Config.fileURL.path)\(configExists ? "" : "  (없음. 기본값 사용)")")
    let source = ProcessInfo.processInfo.environment["MTGREC_HOME"].flatMap { $0.isEmpty ? nil : $0 } != nil
        ? "MTGREC_HOME" : (Config.shared.storage != nil ? "config.storage" : "기본값")
    print("저장 위치: \(Store.root.path)  (\(source))")

    let vocabularyCandidates: [URL] = [
        ProcessInfo.processInfo.environment["MTGREC_VOCAB"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
        Config.directory.appendingPathComponent("vocabulary.json"),
        Store.root.appendingPathComponent("vocabulary.json"),
    ].compactMap { $0 }
    if let url = vocabularyCandidates.first(where: { fm.fileExists(atPath: $0.path) }) {
        let vocabulary = Vocabulary.load()
        print("용어집: \(url.path)  (terms \(vocabulary.terms.count) · replacements \(vocabulary.replacements.count) · glossary \(vocabulary.glossary.count))")
    } else {
        print("용어집: 없음. 용어 보정은 건너뜁니다")
    }
    for (name, key) in [("correct.md", "MTGREC_CORRECT_RULES"), ("live-summary.md", "MTGREC_SUMMARY_RULES")] {
        print("\(name): \(References.find(name, envKey: key)?.path ?? "없음. 내장 규칙 사용")")
    }
}

@main
struct MtgRec {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            return
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "start":
            commandStart(arguments: rest)
        case "_record":
            commandRecord(arguments: rest)
        case "stop":
            commandStop()
        case "status":
            commandStatus()
        case "live":
            commandLive()
        case "_live":
            await runLive(arguments: rest)
        case "list":
            commandList(arguments: rest)
        case "transcribe":
            await runTranscribe(arguments: rest)
        case "correct":
            await runCorrect(arguments: rest)
        case "clean":
            runClean(arguments: rest)
        case "notion":
            commandNotion(arguments: rest)
        case "config":
            commandConfig()
        case "-h", "--help", "help":
            print(usage)
        default:
            fail("모르는 명령입니다: \(command)\n\n\(usage)")
        }
    }
}
