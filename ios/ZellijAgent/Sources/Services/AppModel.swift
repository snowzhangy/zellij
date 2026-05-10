import Foundation
import Combine
import Network
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var activeSession: ZellijSession?
    @Published var showingSettings = false
    @Published var showingComposer = false
    @Published var showingSessionPicker = false
    @Published var availableSessions: [SessionListItem] = []
    @Published var isLoadingSessions = false
    @Published var sessionListError: String?
    @Published var lastSessionListSummary: String?
    @Published var missingSessionName: String?
    @Published var showingCertificateTrust = false
    @Published var certificatePrompt: CertificatePrompt?
    @Published var lastObservedPublicKeyHash: String?
    @Published var optionAsMetaKey = true
    @Published private(set) var connectionLog: [ConnectionLogEntry] = []
    @Published private(set) var lastResize = TerminalResize(rows: 28, cols: 90)

    var settingsStore = SettingsStore()
    let terminalBuffer = TerminalBuffer()
    let terminalStream = TerminalStream()

    private var transport: ZellijWebTransport?
    private var monitor: NWPathMonitor?
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType>?
    private var startupTask: Task<Void, Never>?
    private var hasStarted = false
    private var reconnectTask: Task<Void, Never>?
    private var sessionRefreshTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []
    private static let resizeDebounceNanoseconds: UInt64 = 150_000_000

    private enum ConnectResult {
        case connected
        case handled
        case failed(String)
    }

    var selectedProfile: ZellijProfile? {
        settingsStore.selectedProfile
    }

    init() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        startPathMonitor()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        recordConnectionEvent("app start")
        guard selectedProfile != nil else {
            recordConnectionEvent("show settings: no profile")
            showingSettings = true
            return
        }
        guard let profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            recordConnectionEvent("show settings: missing token")
            showingSettings = true
            return
        }
        startupTask?.cancel()
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.connectionState == .disconnected else { return }
                self.connect()
            }
        }
    }

    func connect() {
        guard let profile = selectedProfile else {
            recordConnectionEvent("connect skipped: no profile")
            showingSettings = true
            return
        }
        guard let token = try? KeychainStore.token(profileID: profile.id), !token.isEmpty else {
            recordConnectionEvent("connect skipped: missing token")
            showingSettings = true
            return
        }
        startupTask?.cancel()
        recordConnectionEvent("connect \(profile.baseURL.absoluteString) session=\(profile.sessionName)")
        connectionState = .connecting
        terminalBuffer.clear()
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: false,
                persistSessionNameOnSuccess: nil,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: connectionGeneration
            )
        }
    }

    func disconnect() {
        recordConnectionEvent("disconnect")
        startupTask?.cancel()
        reconnectTask?.cancel()
        sessionRefreshTask?.cancel()
        resizeTask?.cancel()
        resizeTask = nil
        isLoadingSessions = false
        let oldTransport = transport
        transport = nil
        oldTransport?.disconnect()
        activeSession = nil
        connectionState = .disconnected
    }

    func trustPendingCertificate() {
        guard let profile = selectedProfile,
              let prompt = certificatePrompt else { return }
        recordConnectionEvent("certificate trusted")
        settingsStore.updateTrustedPublicKeyHash(prompt.observedHash, for: profile.id)
        certificatePrompt = nil
        showingCertificateTrust = false
        connect()
    }

    func rejectPendingCertificate() {
        recordConnectionEvent("certificate rejected")
        certificatePrompt = nil
        showingCertificateTrust = false
        disconnect()
    }

    func reconnect(reason: String? = nil) {
        guard !showingSessionPicker else { return }
        guard connectionState.canStartReconnect else { return }
        guard let profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            return
        }
        recordConnectionEvent("reconnect scheduled\(reason.map { ": \($0)" } ?? "")")
        connectionState = .reconnecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: true,
                allowCreate: false,
                persistSessionNameOnSuccess: nil,
                showPickerOnFailure: true,
                initialFailureMessage: reason,
                generation: connectionGeneration
            )
        }
    }

    func sendPrompt(_ prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wrapped = "\u{1B}[200~" + prompt + "\u{1B}[201~\r"
        send(wrapped)
        settingsStore.addPromptToHistory(prompt)
    }

    func send(_ text: String) {
        guard activeSession?.isReadOnly != true else { return }
        Task { [weak self] in
            try? await self?.transport?.sendText(text)
        }
    }

    func sendControl(_ scalar: UInt8) {
        guard activeSession?.isReadOnly != true else { return }
        sendData(Data([scalar]))
    }

    func sendData(_ data: Data) {
        guard activeSession?.isReadOnly != true else { return }
        Task { [weak self] in
            try? await self?.transport?.sendBytes(data)
        }
    }

    func sendResize(rows: Int, cols: Int) {
        lastResize = TerminalResize(rows: rows, cols: cols)
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.resizeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.sendResizeNow(rows: rows, cols: cols)
        }
    }

    private func sendResizeNow(rows: Int, cols: Int) {
        resizeTask?.cancel()
        resizeTask = nil
        Task { [weak self] in
            try? await self?.transport?.sendResize(rows: rows, cols: cols)
        }
    }

    func selectProfile(_ profile: ZellijProfile) {
        settingsStore.selectProfile(profile)
        if connectionState == .disconnected {
            connect()
        } else {
            reconnect()
        }
    }

    func showSessionPicker() {
        missingSessionName = nil
        showingSessionPicker = true
        refreshAvailableSessions()
    }

    func attachSession(_ session: SessionListItem) {
        sessionRefreshTask?.cancel()
        isLoadingSessions = false
        guard var profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            sessionListError = "Missing profile or auth token."
            return
        }
        profile.sessionName = session.name
        recordConnectionEvent("attach session \(session.name)")
        missingSessionName = nil
        sessionListError = nil
        connectionState = .connecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: false,
                persistSessionNameOnSuccess: session.name,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: connectionGeneration
            )
        }
    }

    func createSession(_ sessionName: String) {
        sessionRefreshTask?.cancel()
        isLoadingSessions = false
        let trimmed = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            return
        }
        if let existing = availableSessions.first(where: { $0.name == trimmed }) {
            attachSession(existing)
            return
        }
        profile.sessionName = trimmed
        recordConnectionEvent("create session \(trimmed)")
        missingSessionName = nil
        sessionListError = nil
        connectionState = .connecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: true,
                persistSessionNameOnSuccess: trimmed,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: connectionGeneration
            )
        }
    }

    func refreshAvailableSessions() {
        guard let profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            sessionListError = "Missing profile or auth token."
            return
        }
        recordConnectionEvent("refresh sessions \(profile.baseURL.absoluteString)")
        isLoadingSessions = true
        sessionListError = nil
        sessionRefreshTask?.cancel()
        sessionRefreshTask = Task { [weak self] in
            let transport = ZellijWebTransport(profile: profile, authToken: token)
            self?.wireTransportLog(transport)
            transport.onObservedPublicKeyHash = { [weak self] hash in
                Task { @MainActor in
                    self?.lastObservedPublicKeyHash = hash
                }
            }
            do {
                let sessions = try await transport.fetchSessions()
                let version = try? await transport.fetchServerVersion()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.recordConnectionEvent("session list loaded count=\(sessions.count)\(version.map { " version=\($0)" } ?? "")")
                    self?.availableSessions = sessions
                    let versionText = version.map { " Zellij \($0)" } ?? ""
                    self?.lastSessionListSummary = "\(sessions.count) session\(sessions.count == 1 ? "" : "s") from \(profile.baseURL.absoluteString)\(versionText)"
                    self?.isLoadingSessions = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.recordConnectionEvent("session list failed: \(error.localizedDescription)")
                    self?.handleSessionRefreshError(error, baseURL: profile.baseURL)
                }
            }
        }
    }

    private func connectWithRetry(
        profile: ZellijProfile,
        token: String,
        isReconnect: Bool,
        allowCreate: Bool,
        persistSessionNameOnSuccess: String?,
        showPickerOnFailure: Bool,
        initialFailureMessage: String?,
        generation: UInt64
    ) async {
        let maxAttempts = showPickerOnFailure ? 2 : 1
        var lastFailureMessage = initialFailureMessage

        for attempt in 1...maxAttempts {
            guard !Task.isCancelled, generation == connectionGeneration else { return }
            let result = await connect(
                profile: profile,
                token: token,
                isReconnect: isReconnect,
                allowCreate: allowCreate,
                persistSessionNameOnSuccess: persistSessionNameOnSuccess,
                generation: generation
            )
            switch result {
            case .connected, .handled:
                return
            case .failed(let message):
                lastFailureMessage = message
                guard attempt < maxAttempts else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        guard showPickerOnFailure else { return }
        guard generation == connectionGeneration else { return }
        activeSession = nil
        sessionListError = lastFailureMessage ?? "Connection failed."
        lastSessionListSummary = "Connection failed. Choose a session or retry."
        missingSessionName = nil
        showingSessionPicker = true
        refreshAvailableSessions()
    }

    private func connect(
        profile: ZellijProfile,
        token: String,
        isReconnect: Bool,
        allowCreate: Bool,
        persistSessionNameOnSuccess: String? = nil,
        generation: UInt64
    ) async -> ConnectResult {
        let transport = ZellijWebTransport(profile: profile, authToken: token)
        wireTransportLog(transport)
        transport.onTerminalData = { [weak self] data in
            Task { @MainActor in
                self?.terminalStream.append(data)
                self?.terminalBuffer.append(data)
            }
        }
        transport.onControlEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleControlEvent(event)
            }
        }
        var connectedAt: Date?
        transport.onClose = { [weak self, weak transport] close in
            Task { @MainActor in
                guard let self, self.transport === transport else { return }
                if close.code == 4404 {
                    self.handleSessionNotFoundClose(profile: profile, reason: close.message)
                    return
                }
                if let connectedAt,
                   Date().timeIntervalSince(connectedAt) < 2 {
                    self.handleImmediateWebSocketClose(close.message)
                    return
                }
                self.reconnect(reason: close.message)
            }
        }
        transport.onObservedPublicKeyHash = { [weak self] hash in
            Task { @MainActor in
                guard let self else { return }
                self.lastObservedPublicKeyHash = hash
            }
        }
        self.transport?.disconnect()
        self.transport = transport

        do {
            guard generation == connectionGeneration else {
                transport.disconnect()
                return .handled
            }
            let session = try await transport.connect(
                rows: lastResize.rows,
                cols: lastResize.cols,
                allowCreate: allowCreate
            )
            guard generation == connectionGeneration else {
                transport.disconnect()
                return .handled
            }
            activeSession = session
            connectedAt = Date()
            recordConnectionEvent("connected webClientID=\(session.webClientID) version=\(session.version ?? "unknown") readOnly=\(session.isReadOnly)")
            if let persistSessionNameOnSuccess {
                settingsStore.updateSessionName(persistSessionNameOnSuccess, for: profile.id)
                missingSessionName = nil
                showingSessionPicker = false
            }
            connectionState = .connected(version: session.version)
            return .connected
        } catch {
            guard generation == connectionGeneration else {
                transport.disconnect()
                return .handled
            }
            recordConnectionEvent("connect failed: \(error.localizedDescription)")
            if self.transport === transport {
                self.transport = nil
                transport.disconnect()
            }
            if case ZellijWebTransport.TransportError.certificateUntrusted(let hash) = error {
                certificatePrompt = .untrusted(observed: hash)
                showingCertificateTrust = true
                connectionState = .failed("Certificate trust required")
                return .handled
            }
            if case ZellijWebTransport.TransportError.certificateMismatch(let observed, let expected) = error {
                certificatePrompt = .mismatch(observed: observed, expected: expected)
                showingCertificateTrust = true
                connectionState = .failed("Certificate mismatch")
                return .handled
            }
            if case ZellijWebTransport.TransportError.sessionNotFound(let sessionName, let sessions) = error {
                missingSessionName = sessionName
                availableSessions = sessions
                lastSessionListSummary = "\(sessions.count) session\(sessions.count == 1 ? "" : "s") found"
                sessionListError = nil
                isLoadingSessions = false
                showingSessionPicker = true
                activeSession = nil
                connectionState = .failed("Choose a session")
                return .handled
            }
            if isReconnect {
                connectionState = .failed(error.localizedDescription)
                return .failed(error.localizedDescription)
            } else {
                connectionState = .failed(error.localizedDescription)
                return .failed(error.localizedDescription)
            }
        }
    }

    private func handleImmediateWebSocketClose(_ reason: String) {
        recordConnectionEvent("immediate websocket close: \(reason)")
        let hint = "The server closed the web session immediately. For existing Zellij sessions, start or enable the session with web_sharing \"on\"."
        let message = "\(reason)\n\(hint)"
        transport?.disconnect()
        transport = nil
        activeSession = nil
        connectionState = .failed("Web session closed")
        sessionListError = message
        lastSessionListSummary = "Connection closed. Choose a session or enable web sharing."
        missingSessionName = nil
        showingSessionPicker = true
        refreshAvailableSessions()
    }

    private func handleSessionNotFoundClose(profile: ZellijProfile, reason: String) {
        recordConnectionEvent("session not found close: \(profile.sessionName) \(reason)")
        transport?.disconnect()
        transport = nil
        activeSession = nil
        missingSessionName = profile.sessionName
        sessionListError = reason
        lastSessionListSummary = "Session not found. Choose another session or create one."
        connectionState = .failed("Choose a session")
        showingSessionPicker = true
        refreshAvailableSessions()
    }

    private func handleSessionRefreshError(_ error: Error, baseURL: URL) {
        isLoadingSessions = false

        if case ZellijWebTransport.TransportError.certificateUntrusted(let hash) = error {
            certificatePrompt = .untrusted(observed: hash)
            showingCertificateTrust = true
            sessionListError = "Certificate trust required."
            lastSessionListSummary = "Certificate trust required for \(baseURL.absoluteString)"
            if !connectionState.isConnected {
                connectionState = .failed("Certificate trust required")
            }
            return
        }
        if case ZellijWebTransport.TransportError.certificateMismatch(let observed, let expected) = error {
            certificatePrompt = .mismatch(observed: observed, expected: expected)
            showingCertificateTrust = true
            sessionListError = "Certificate mismatch."
            lastSessionListSummary = "Certificate mismatch for \(baseURL.absoluteString)"
            if !connectionState.isConnected {
                connectionState = .failed("Certificate mismatch")
            }
            return
        }

        let nsError = error as NSError
        let detail = "\(error.localizedDescription) (\(nsError.domain) \(nsError.code))"
        sessionListError = "\(detail)\n\(baseURL.absoluteString)"
        lastSessionListSummary = "Failed to load sessions from \(baseURL.absoluteString)"
        if !connectionState.isConnected {
            connectionState = .failed(error.localizedDescription)
        }
    }

    private func handleControlEvent(_ event: ZellijControlEvent) {
        switch event {
        case .queryTerminalSize:
            recordConnectionEvent("control QueryTerminalSize")
            sendResizeNow(rows: lastResize.rows, cols: lastResize.cols)
        case .switchedSession(let session):
            terminalBuffer.append("\n[Switched to \(session)]\n")
        case .log(let lines):
            terminalBuffer.append(lines.joined(separator: "\n") + "\n")
        case .logError(let lines):
            terminalBuffer.append(lines.joined(separator: "\n") + "\n")
        case .setConfig(_, let macOptionIsMeta):
            recordConnectionEvent("control SetConfig macOptionIsMeta=\(macOptionIsMeta.map { String($0) } ?? "nil")")
            if let macOptionIsMeta {
                optionAsMetaKey = macOptionIsMeta
            }
        case .unknown:
            break
        }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            let interfaceTypes = Self.interfaceTypes(for: path)
            Task { @MainActor in
                guard let self else { return }
                let previousInterfaceTypes = self.lastInterfaceTypes
                self.lastInterfaceTypes = interfaceTypes
                guard let previousInterfaceTypes,
                      previousInterfaceTypes != interfaceTypes,
                      case .connected = self.connectionState else {
                    return
                }
                self.reconnect()
            }
        }
        monitor.start(queue: DispatchQueue(label: "ZellijAgent.Network"))
        self.monitor = monitor
    }

    var diagnosticLogText: String {
        connectionLog.map { $0.copyLine }.joined(separator: "\n")
    }

    private func wireTransportLog(_ transport: ZellijWebTransport) {
        transport.onLog = { [weak self] message in
            Task { @MainActor in
                self?.recordConnectionEvent(message)
            }
        }
    }

    private func recordConnectionEvent(_ message: String) {
        connectionLog.append(ConnectionLogEntry(message: message))
        if connectionLog.count > 50 {
            connectionLog.removeFirst(connectionLog.count - 50)
        }
    }

    private nonisolated static func interfaceTypes(for path: NWPath) -> Set<NWInterface.InterfaceType> {
        Set(
            [
                .wifi,
                .cellular,
                .wiredEthernet,
                .loopback,
                .other
            ].filter { path.usesInterfaceType($0) }
        )
    }
}

struct ConnectionLogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let message: String

    var displayLine: String {
        "\(timestamp.formatted(date: .omitted, time: .standard)) \(message)"
    }

    var copyLine: String {
        "\(timestamp.formatted(date: .numeric, time: .standard)) \(message)"
    }
}

struct CertificatePrompt: Equatable {
    let observedHash: String
    let expectedHash: String?
    let formattedObservedHash: String
    let formattedExpectedHash: String?

    private init(observedHash: String, expectedHash: String?) {
        self.observedHash = observedHash
        self.expectedHash = expectedHash
        self.formattedObservedHash = Self.readableHash(observedHash)
        self.formattedExpectedHash = expectedHash.map(Self.readableHash)
    }

    static func untrusted(observed: String) -> CertificatePrompt {
        CertificatePrompt(observedHash: observed, expectedHash: nil)
    }

    static func mismatch(observed: String, expected: String) -> CertificatePrompt {
        CertificatePrompt(observedHash: observed, expectedHash: expected)
    }

    var title: String {
        expectedHash == nil ? "Trust Zellij server?" : "Certificate changed"
    }

    var actionTitle: String {
        expectedHash == nil ? "Trust" : "Re-trust"
    }

    var message: String {
        if let formattedExpectedHash {
            return """
            Observed:
            \(formattedObservedHash)

            Expected:
            \(formattedExpectedHash)
            """
        }
        return formattedObservedHash
    }

    private static func readableHash(_ hash: String) -> String {
        var groups: [String] = []
        groups.reserveCapacity((hash.count / 16) + 1)
        var pairs: [String] = []
        pairs.reserveCapacity(8)

        var index = hash.startIndex
        while index < hash.endIndex {
            let next = hash.index(index, offsetBy: 2, limitedBy: hash.endIndex) ?? hash.endIndex
            pairs.append(String(hash[index..<next]))
            if pairs.count == 8 {
                groups.append(pairs.joined(separator: ":"))
                pairs.removeAll(keepingCapacity: true)
            }
            index = next
        }

        if !pairs.isEmpty {
            groups.append(pairs.joined(separator: ":"))
        }
        return groups.joined(separator: "\n")
    }
}
