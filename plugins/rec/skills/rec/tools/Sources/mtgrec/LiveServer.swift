import Foundation
import Network
import Security

/// 회의 중에만 사는 최소 HTTP 서버. 루프백에만 붙는다.
///
/// 라우트는 넷뿐이다. 페이지 하나, SSE 스트림 하나, 그리고 페이지에서 누르는 버튼 둘.
/// 의존성을 들이지 않은 것은 이 바이너리가 `~/.claude/bin` 에 홀로 복사되기 때문이다.
final class LiveServer: @unchecked Sendable {
    let token: String
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let lock = NSLock()
    private var clients: [NWConnection] = []
    private let queue = DispatchQueue(label: "mtgrec.server")

    /// 페이지에서 「지금 요약」을 눌렀을 때.
    var onSummarize: (() -> Void)?
    /// 페이지에서 「녹음 종료」를 눌렀을 때.
    var onStop: (() -> Void)?
    /// 새 구독자에게 처음 보낼 전체 상태.
    var snapshot: (() -> Data)?

    init() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 후보 포트를 차례로 시도한다. 전부 막혀 있으면 throw.
    func start(preferred: UInt16?) throws {
        let candidates: [UInt16] = preferred.map { [$0] } ?? Array(8477...8486)
        var lastError: String = "포트를 열 수 없습니다"
        for candidate in candidates {
            do {
                try bind(to: candidate)
                port = candidate
                return
            } catch {
                lastError = "\(error)"
            }
        }
        throw RecorderError.message(lastError)
    }

    private func bind(to candidate: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // 루프백에만 묶는다. 외부 인터페이스로는 아예 안 뜨므로 방화벽 프롬프트도 없다.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                               port: NWEndpoint.Port(rawValue: candidate)!)
        let listener = try NWListener(using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: semaphore.signal()
            case .failed(let error): failure = error; semaphore.signal()
            case .cancelled: semaphore.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if semaphore.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw RecorderError.message("포트 \(candidate) 응답 없음")
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        self.listener = listener
    }

    func stop() {
        lock.lock()
        let open = clients
        clients = []
        lock.unlock()
        for connection in open { connection.cancel() }
        listener?.cancel()
        listener = nil
    }

    var url: String { "http://127.0.0.1:\(port)/?t=\(token)" }

    // MARK: - 요청 처리

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    /// 헤더가 다 올 때까지 읽는다. 본문은 쓰지 않으므로 읽지 않는다.
    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 { connection.cancel(); return }
                self.receiveHeader(connection, buffer: buffer)
                return
            }
            let header = String(data: buffer[..<terminator.lowerBound], encoding: .utf8) ?? ""
            self.route(connection, header: header)
        }
    }

    private func route(_ connection: NWConnection, header: String) {
        guard let requestLine = header.split(separator: "\r\n").first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let authorized = target.contains("t=\(token)") || header.contains("X-Mtgrec-Token: \(token)")

        switch (method, path) {
        case ("GET", "/"):
            // 페이지 자체는 토큰 없이도 준다. 토큰이 없으면 페이지의 JS 가 붙지 못할 뿐이다.
            send(connection, status: "200 OK", contentType: "text/html; charset=utf-8",
                 body: Data(livePageHTML.utf8), close: true)

        case ("GET", "/events"):
            guard authorized else { return deny(connection) }
            openStream(connection)

        case ("POST", "/summarize"):
            guard authorized else { return deny(connection) }
            onSummarize?()
            sendJSON(connection, "{\"ok\":true}")

        case ("POST", "/stop"):
            guard authorized else { return deny(connection) }
            onStop?()
            sendJSON(connection, "{\"ok\":true}")

        default:
            send(connection, status: "404 Not Found", contentType: "text/plain; charset=utf-8",
                 body: Data("not found".utf8), close: true)
        }
    }

    private func deny(_ connection: NWConnection) {
        send(connection, status: "403 Forbidden", contentType: "text/plain; charset=utf-8",
             body: Data("토큰이 필요합니다. mtgrec 이 출력한 URL 을 그대로 여십시오.".utf8), close: true)
    }

    // MARK: - 보내기

    private func send(_ connection: NWConnection, status: String, contentType: String,
                      body: Data, close: Bool) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body,
                        completion: .contentProcessed { _ in if close { connection.cancel() } })
    }

    private func sendJSON(_ connection: NWConnection, _ json: String) {
        send(connection, status: "200 OK", contentType: "application/json; charset=utf-8",
             body: Data(json.utf8), close: true)
    }

    private func openStream(_ connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: keep-alive\r\n"
        head += "X-Accel-Buffering: no\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        // 끊긴 구독자를 목록에서 걷어낸다. 브라우저 탭을 닫으면 여기로 온다.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(connection)
            default: break
            }
        }

        lock.lock()
        clients.append(connection)
        lock.unlock()

        if let snapshot = snapshot?() {
            write(connection, frame(event: "snapshot", data: snapshot))
        }
    }

    private func drop(_ connection: NWConnection) {
        lock.lock()
        clients.removeAll { $0 === connection }
        lock.unlock()
    }

    private func frame(event: String, data: Data) -> Data {
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        // SSE 는 줄 단위 프로토콜이다. JSON 을 한 줄로 인코딩하므로 개행이 섞일 일은 없지만
        // 혹시 섞여도 프레임이 깨지지 않게 줄마다 data: 를 붙인다.
        let body = payload.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "data: \($0)" }
            .joined(separator: "\n")
        return Data("event: \(event)\n\(body)\n\n".utf8)
    }

    private func write(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.drop(connection); connection.cancel() }
        })
    }

    func broadcast(event: String, data: Data) {
        lock.lock()
        let targets = clients
        lock.unlock()
        guard !targets.isEmpty else { return }
        let payload = frame(event: event, data: data)
        for connection in targets { write(connection, payload) }
    }

    /// 프록시나 절전이 끼어들어도 스트림이 살아 있게 주기적으로 코멘트를 흘린다.
    func heartbeat() {
        lock.lock()
        let targets = clients
        lock.unlock()
        for connection in targets { write(connection, Data(": ping\n\n".utf8)) }
    }
}
