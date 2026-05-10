import Foundation

struct ZellijSession: Equatable {
    let webClientID: String
    let isReadOnly: Bool
    let version: String?
}

struct TerminalResize: Codable {
    let rows: Int
    let cols: Int
}

struct WebSocketClose: Equatable {
    let channel: String
    let code: Int?
    let reason: String?
    let message: String
}

struct SessionListResponse: Decodable {
    let sessions: [SessionListItem]

    init(sessions: [SessionListItem]) {
        self.sessions = sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let sessions = try? container.decode([SessionListItem].self, forKey: .sessions) {
            self.sessions = sessions
            return
        }
        let legacySessions = try container.decode([String].self, forKey: .sessions)
        self.sessions = legacySessions.map { SessionListItem(name: $0, status: .unknown) }
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }
}

struct SessionListItem: Codable, Equatable, Identifiable {
    let name: String
    let status: SessionListStatus

    var id: String {
        name
    }
}

enum SessionListStatus: String, Codable {
    case live
    case resurrectable
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = SessionListStatus(rawValue: value) ?? .unknown
    }
}

enum ZellijControlEvent: Equatable {
    case setConfig(font: String?, macOptionIsMeta: Bool?)
    case queryTerminalSize
    case switchedSession(String)
    case log([String])
    case logError([String])
    case unknown(String)
}

final class ZellijWebTransport {
    var onTerminalData: ((Data) -> Void)?
    var onControlEvent: ((ZellijControlEvent) -> Void)?
    var onClose: ((WebSocketClose) -> Void)?
    var onObservedPublicKeyHash: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private let profile: ZellijProfile
    private let authToken: String
    private let delegate: CertificatePinningDelegate
    private let session: URLSession
    private var controlTask: URLSessionWebSocketTask?
    private var terminalTask: URLSessionWebSocketTask?
    private var receiveTasks: [Task<Void, Never>] = []
    private var zellijSession: ZellijSession?
    private var isClosedIntentionally = false

    init(profile: ZellijProfile, authToken: String) {
        self.profile = profile
        self.authToken = authToken
        self.delegate = CertificatePinningDelegate()
        self.delegate.expectedPublicKeyHash = profile.trustedPublicKeyHash
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.delegate.observedPublicKeyHash = { [weak self] hash in
            self?.onObservedPublicKeyHash?(hash)
        }
    }

    func connect(rows: Int, cols: Int, allowCreate: Bool = false) async throws -> ZellijSession {
        isClosedIntentionally = false
        onLog?("transport login")
        try await login()
        onLog?("transport fetch version")
        let version = try? await fetchVersion()
        onLog?("transport fetch sessions")
        let sessions = try await fetchSessionList()
        if !allowCreate && !sessions.contains(where: { $0.name == profile.sessionName }) {
            onLog?("transport session missing \(profile.sessionName)")
            throw TransportError.sessionNotFound(profile.sessionName, sessions)
        }
        onLog?("transport create web client")
        let client = try await createClient()
        let zellijSession = ZellijSession(
            webClientID: client.webClientID,
            isReadOnly: client.isReadOnly,
            version: version
        )
        self.zellijSession = zellijSession

        onLog?("transport open control websocket")
        try await openControlSocket()
        try await receiveInitialControlEvent()
        startControlReceiveLoop()
        onLog?("transport open terminal websocket")
        try await openTerminalSocket(webClientID: client.webClientID, allowCreate: allowCreate)
        try await sendResize(rows: rows, cols: cols)
        onLog?("transport sent resize rows=\(rows) cols=\(cols)")
        startTerminalReceiveLoop()
        return zellijSession
    }

    func fetchSessions() async throws -> [SessionListItem] {
        onLog?("transport login for sessions")
        try await login()
        onLog?("transport fetch sessions")
        return try await fetchSessionList()
    }

    func fetchServerVersion() async throws -> String {
        onLog?("transport fetch version")
        return try await fetchVersion()
    }

    func disconnect() {
        isClosedIntentionally = true
        onLog?("transport disconnect")
        receiveTasks.forEach { $0.cancel() }
        receiveTasks.removeAll()
        controlTask?.cancel(with: .goingAway, reason: nil)
        terminalTask?.cancel(with: .goingAway, reason: nil)
        controlTask = nil
        terminalTask = nil
        zellijSession = nil
    }

    func sendText(_ text: String) async throws {
        try await terminalTask?.send(.string(text))
    }

    func sendBytes(_ data: Data) async throws {
        try await terminalTask?.send(.data(data))
    }

    func sendResize(rows: Int, cols: Int) async throws {
        guard let webClientID = zellijSession?.webClientID else { return }
        let json = try ZellijWireCodec.encodeResize(webClientID: webClientID, rows: rows, cols: cols)
        try await controlTask?.send(.string(json))
    }

    private func login() async throws {
        do {
            var request = authenticatedRequest(url: endpoint("command/login"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.zellij.encode(LoginRequest(authToken: authToken, rememberMe: true))
            let (_, response) = try await session.data(for: request)
            try validate(response)
            storeCookies(from: response)
        } catch {
            if let mismatch = delegate.certificateMismatch {
                throw TransportError.certificateMismatch(observed: mismatch.observed, expected: mismatch.expected)
            }
            if let hash = delegate.untrustedPublicKeyHash {
                throw TransportError.certificateUntrusted(hash)
            }
            throw error
        }
    }

    private func fetchVersion() async throws -> String {
        let (data, response) = try await session.data(for: authenticatedRequest(url: endpoint("info/version")))
        try validate(response)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchSessionList() async throws -> [SessionListItem] {
        let (data, response) = try await session.data(for: authenticatedRequest(url: endpoint("sessions")))
        try validate(response)
        do {
            return try JSONDecoder.zellij.decode(SessionListResponse.self, from: data).sessions
        } catch {
            throw TransportError.sessionListUnavailable
        }
    }

    private func createClient() async throws -> SessionResponse {
        var request = authenticatedRequest(url: endpoint("session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.zellij.decode(SessionResponse.self, from: data)
    }

    private func openControlSocket() async throws {
        let task = session.webSocketTask(with: authenticatedRequest(url: try websocketEndpoint("ws/control")))
        controlTask = task
        task.resume()
    }

    private func openTerminalSocket(webClientID: String, allowCreate: Bool) async throws {
        let sessionName = profile.sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? profile.sessionName
        let path = "ws/terminal/\(sessionName)"
        guard var components = URLComponents(url: try websocketEndpoint(path), resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "web_client_id", value: webClientID),
            URLQueryItem(name: "create", value: allowCreate ? "true" : "false")
        ]
        guard let url = components.url else { throw TransportError.invalidURL }
        let task = session.webSocketTask(with: authenticatedRequest(url: url))
        terminalTask = task
        task.resume()
    }

    private func startControlReceiveLoop() {
        if let controlTask {
            receiveTasks.append(Task { [weak self, controlTask] in
                await self?.receiveControlLoop(task: controlTask)
            })
        }
    }

    private func startTerminalReceiveLoop() {
        if let terminalTask {
            receiveTasks.append(Task { [weak self, terminalTask] in
                await self?.receiveTerminalLoop(task: terminalTask)
            })
        }
    }

    private func receiveInitialControlEvent() async throws {
        guard let controlTask else { return }
        let message = try await withTimeout(seconds: 2) {
            try await controlTask.receive()
        }
        if let event = try parseControlMessage(message) {
            onControlEvent?(event)
        }
    }

    private func receiveControlLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if let event = try parseControlMessage(message) {
                    onControlEvent?(event)
                }
            } catch {
                if !isClosedIntentionally {
                    let close = webSocketClose(channel: "control", task: task, error: error)
                    onLog?(close.message)
                    onClose?(close)
                }
                break
            }
        }
    }

    private func receiveTerminalLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    onTerminalData?(Data(text.utf8))
                case .data(let data):
                    onTerminalData?(data)
                @unknown default:
                    break
                }
            } catch {
                if !isClosedIntentionally {
                    let close = webSocketClose(channel: "terminal", task: task, error: error)
                    onLog?(close.message)
                    onClose?(close)
                }
                break
            }
        }
    }

    private func parseControlMessage(_ message: URLSessionWebSocketTask.Message) throws -> ZellijControlEvent? {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            return nil
        }
        return try ZellijWireCodec.decodeControlEvent(from: data)
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(profile.baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func websocketEndpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false) else {
            throw TransportError.invalidURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw TransportError.invalidURL }
        return url
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        addStoredCookies(to: &request)
        return request
    }

    private func addStoredCookies(to request: inout URLRequest) {
        let cookieStores = [
            session.configuration.httpCookieStorage,
            HTTPCookieStorage.shared
        ]
        let cookies = cookieStores
            .compactMap { $0?.cookies(for: profile.baseURL) }
            .flatMap { $0 }
        guard !cookies.isEmpty else { return }
        HTTPCookie.requestHeaderFields(with: cookies).forEach { header, value in
            request.setValue(value, forHTTPHeaderField: header)
        }
    }

    private func storeCookies(from response: URLResponse) {
        guard let url = response.url,
              let http = response as? HTTPURLResponse else {
            return
        }
        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            guard let key = field.key as? String,
                  let value = field.value as? String else {
                return
            }
            result[key] = value
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !cookies.isEmpty else { return }
        session.configuration.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
        HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: nil)
    }

    private func webSocketClose(
        channel: String,
        task: URLSessionWebSocketTask,
        error: Error
    ) -> WebSocketClose {
        let nsError = error as NSError
        var parts = [
            "\(channel) websocket closed",
            error.localizedDescription,
            "\(nsError.domain) \(nsError.code)"
        ]
        let closeCode = task.closeCode.rawValue
        let code: Int?
        if closeCode != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            parts.append("close \(closeCode)")
            code = closeCode
        } else {
            code = nil
        }
        let reason: String?
        if let closeReason = task.closeReason,
           let closeReasonText = String(data: closeReason, encoding: .utf8),
           !closeReasonText.isEmpty {
            parts.append(closeReasonText)
            reason = closeReasonText
        } else {
            reason = nil
        }
        return WebSocketClose(
            channel: channel,
            code: code,
            reason: reason,
            message: parts.joined(separator: " - ")
        )
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.httpStatus(http.statusCode)
        }
    }

    private func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TransportError.timeout
            }
            guard let result = try await group.next() else {
                throw TransportError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    enum TransportError: Error, LocalizedError {
        case invalidURL
        case httpStatus(Int)
        case certificateUntrusted(String)
        case certificateMismatch(observed: String, expected: String)
        case sessionNotFound(String, [SessionListItem])
        case sessionListUnavailable
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL"
            case .httpStatus(let status):
                return "Server returned HTTP \(status)"
            case .certificateUntrusted:
                return "Certificate must be trusted before connecting"
            case .certificateMismatch:
                return "Server certificate does not match the saved pin"
            case .sessionNotFound(let session, _):
                return "Session '\(session)' no longer exists"
            case .sessionListUnavailable:
                return "Server does not support session listing"
            case .timeout:
                return "Connection timed out"
            }
        }
    }
}

struct LoginRequest: Codable {
    let authToken: String
    let rememberMe: Bool

    enum CodingKeys: String, CodingKey {
        case authToken = "auth_token"
        case rememberMe = "remember_me"
    }
}

struct SessionResponse: Codable {
    let webClientID: String
    let isReadOnly: Bool

    enum CodingKeys: String, CodingKey {
        case webClientID = "web_client_id"
        case isReadOnly = "is_read_only"
    }
}
