import Foundation
import Combine
import Network
import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox

enum AppBuild {
    #if ZELMUX_DIAGNOSTICS
    static let diagnosticsEnabled = true
    #else
    static let diagnosticsEnabled = false
    #endif
}

enum ShellIntegrationEvent: Equatable {
    case promptStart
    case promptEnd
    case commandStart
    case commandFinished(exitCode: Int?)
    case unknown(String)
}

enum TerminalHardwareShortcut {
    case escape
    case controlC
    case controlD
    case previousTab
    case nextTab
    case tab(Int)
    case composePrompt
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var activeSession: ZellijSession?
    @Published var showingSettings = false
    @Published var showingComposer = false
    @Published var showingConnectionDoctor = false
    @Published var showingGestureShortcuts = false
    @Published var showingAboutPrivacy = false
    @Published var showingSessionPicker = false
    @Published var availableSessions: [SessionListItem] = []
    @Published var isLoadingSessions = false
    @Published var sessionListError: String?
    @Published var lastSessionListSummary: String?
    @Published var missingSessionName: String?
    @Published var showingCertificateTrust = false
    @Published var certificatePrompt: CertificatePrompt?
    @Published var lastObservedPublicKeyHash: String?
    @Published var sessionSwitchNotice: String?
    @Published var optionAsMetaKey = true
    @Published var zellijTheme: ZellijWebTheme?
    @Published private(set) var terminalTitle = ""
    @Published private(set) var terminalStatusText: String?
    @Published private(set) var reconnectCount: Int = 0
    @Published private(set) var memoryWarningCount: Int = 0
    @Published private(set) var lastClose: WebSocketClose?
    @Published private(set) var connectionLog: [ConnectionLogEntry] = []
    @Published private(set) var lastResize = TerminalResize(rows: 28, cols: 90)

    var settingsStore = SettingsStore()
    let terminalStream = TerminalStream()

    private var transport: ZellijWebTransport?
    private var monitor: NWPathMonitor?
    private var lastInterfaceTypes: Set<NWInterface.InterfaceType>?
    private var startupTask: Task<Void, Never>?
    private var hasStarted = false
    private var isAppActive = true
    private var notificationAuthorizationRequested = false
    private var lastBellAt: Date?
    private var reconnectTask: Task<Void, Never>?
    private var sessionRefreshTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var tabSwitchRefreshTask: Task<Void, Never>?
    private var sessionSwitchNoticeTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var activeCommandStartedAt: Date?
    private var lastTerminalMetrics: TerminalMetrics?
    private(set) var terminalBytesReceived: Int = 0
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
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if AppBuild.diagnosticsEnabled {
                        self.memoryWarningCount += 1
                        self.recordConnectionEvent("memory warning")
                    }
                    self.terminalStream.reset()
                    NotificationCenter.default.post(name: .zelmuxMemoryPressure, object: nil)
                }
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
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.connectionState == .disconnected else { return }
                self.connect()
            }
        }
    }

    func sceneBecameActive() {
        isAppActive = true
        if !hasStarted {
            start()
            return
        }
        switch connectionState {
        case .disconnected:
            connect()
        case .failed:
            reconnect()
        case .connected, .connecting, .reconnecting:
            break
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isAppActive = phase == .active
        terminalStream.setAppActive(isAppActive)
        if phase == .active {
            sceneBecameActive()
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
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: false,
                persistSessionNameOnSuccess: nil,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: generation
            )
        }
    }

    func disconnect() {
        recordConnectionEvent("disconnect")
        startupTask?.cancel()
        reconnectTask?.cancel()
        sessionRefreshTask?.cancel()
        resizeTask?.cancel()
        sessionSwitchNoticeTask?.cancel()
        resizeTask = nil
        sessionSwitchNoticeTask = nil
        sessionSwitchNotice = nil
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
        guard isAppActive else {
            recordConnectionEvent("reconnect deferred while inactive\(reason.map { ": \($0)" } ?? "")")
            connectionState = .disconnected
            return
        }
        guard let profile = selectedProfile,
              let token = try? KeychainStore.token(profileID: profile.id),
              !token.isEmpty else {
            return
        }
        startupTask?.cancel()
        recordConnectionEvent("reconnect scheduled\(reason.map { ": \($0)" } ?? "")")
        if AppBuild.diagnosticsEnabled {
            reconnectCount += 1
        }
        connectionState = .reconnecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
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
                generation: generation
            )
        }
    }

    func sendPrompt(_ prompt: String, appendEnter: Bool = true) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wrapped = "\u{1B}[200~" + prompt + "\u{1B}[201~" + (appendEnter ? "\r" : "")
        send(wrapped)
        settingsStore.addPromptToHistory(prompt)
    }

    func uploadImageForPrompt(data: Data, filename: String, mimeType: String) async throws -> String {
        guard activeSession?.isReadOnly != true else {
            throw ZellijWebTransport.TransportError.httpStatus(403)
        }
        guard let transport else {
            throw ZellijWebTransport.TransportError.sessionListUnavailable
        }
        recordConnectionEvent("upload image \(filename) bytes=\(data.count)")
        let response = try await transport.uploadImage(data: data, filename: filename, mimeType: mimeType)
        recordConnectionEvent("uploaded image \(response.path)")
        return response.path
    }

    func send(_ text: String) {
        guard let activeSession, !activeSession.isReadOnly, let transport else { return }
        transport.queueText(text, sequence: nextInputSequence())
    }

    func sendControl(_ scalar: UInt8) {
        sendData(Data([scalar]))
    }

    func goToPreviousTab() {
        sendData(Data([0x1B, 0x68])) // Alt-h: MoveFocusOrTab Left in the default Zellij keymap.
    }

    func goToNextTab() {
        sendData(Data([0x1B, 0x6C])) // Alt-l: MoveFocusOrTab Right in the default Zellij keymap.
    }

    func goToTab(_ index: Int) {
        guard (1...9).contains(index) else { return }
        if let profile = selectedProfile {
            settingsStore.updateLastTabPosition(index - 1, for: profile.id)
        }
        sendData(Data([0x14, UInt8(0x30 + index)])) // Ctrl-t, digit.
    }

    func handleHardwareShortcut(_ shortcut: TerminalHardwareShortcut) {
        switch shortcut {
        case .escape:
            sendControl(0x1B)
        case .controlC:
            sendControl(0x03)
        case .controlD:
            sendControl(0x04)
        case .previousTab:
            goToPreviousTab()
        case .nextTab:
            goToNextTab()
        case .tab(let index):
            goToTab(index)
        case .composePrompt:
            guard activeSession?.isReadOnly != true else { return }
            showingComposer = true
        }
    }

    func sendData(_ data: Data) {
        guard let activeSession, !activeSession.isReadOnly, let transport else { return }
        if isLikelyTabSwitchInput(data) {
            prepareForTabSwitch()
        }
        transport.queueBytes(data, sequence: nextInputSequence())
    }

    private func isLikelyTabSwitchInput(_ data: Data) -> Bool {
        let bytes = Array(data)
        if bytes == [0x1B, 0x68] || bytes == [0x1B, 0x6C] {
            return true
        }
        if bytes.count == 2,
           bytes[0] == 0x14,
           (0x31...0x39).contains(bytes[1]) {
            return true
        }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(
            of: "\u{001B}\\[<0;\\d+;[12]M",
            options: .regularExpression
        ) != nil
    }

    private func prepareForTabSwitch() {
        terminalStream.reset()
        scheduleTabSwitchRefresh()
    }

    private func scheduleTabSwitchRefresh() {
        let resize = lastResize
        let metrics = lastTerminalMetrics
        tabSwitchRefreshTask?.cancel()
        tabSwitchRefreshTask = Task { [weak self] in
            for delay in [80_000_000, 260_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.sendResizeNow(rows: resize.rows, cols: resize.cols, metrics: metrics)
            }
            await MainActor.run {
                self?.tabSwitchRefreshTask = nil
            }
        }
    }

    private func nextInputSequence() -> UInt64 {
        terminalStream.markUserInput()
        defer { inputSequence &+= 1 }
        return inputSequence
    }

    func sendResize(rows: Int, cols: Int, metrics: TerminalMetrics? = nil) {
        lastResize = TerminalResize(rows: rows, cols: cols)
        if let metrics {
            lastTerminalMetrics = metrics
        }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.resizeDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.sendResizeNow(rows: rows, cols: cols, metrics: metrics)
        }
    }

    private func sendResizeNow(rows: Int, cols: Int, metrics: TerminalMetrics? = nil) {
        resizeTask?.cancel()
        resizeTask = nil
        Task { [weak self] in
            guard let self else { return }
            try? await self.transport?.sendResize(rows: rows, cols: cols)
            if let metrics = metrics ?? self.lastTerminalMetrics {
                try? await self.transport?.sendTerminalMetrics(metrics)
            }
        }
    }

    func handleTerminalBell() {
        let now = Date()
        if let lastBellAt, now.timeIntervalSince(lastBellAt) < 2 {
            return
        }
        lastBellAt = now
        recordConnectionEvent("terminal bell")
        requestNotificationAuthorizationIfNeeded()

        if isAppActive {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Self.playShortDing()
        } else {
            postTerminalBellNotification()
        }
    }

    private func postTerminalBellNotification() {
        requestNotificationAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.sound = Self.shortDingNotificationSound
        let request = UNNotificationRequest(
            identifier: "zellij-terminal-bell-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !notificationAuthorizationRequested else { return }
        notificationAuthorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.sound]) { _, _ in }
    }

    func handleTerminalTitle(_ title: String) {
        guard terminalTitle != title else { return }
        terminalTitle = title
        terminalStatusText = Self.summaryStatus(fromTerminalTitle: title)
    }

    func handleShellIntegrationEvent(_ event: ShellIntegrationEvent) {
        switch event {
        case .commandStart:
            activeCommandStartedAt = Date()
            terminalStatusText = "Working"
            recordConnectionEvent("shell command start")
        case .commandFinished(let exitCode):
            let elapsed = activeCommandStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            activeCommandStartedAt = nil
            terminalStatusText = exitCode.map { $0 == 0 ? "Done" : "Exit \($0)" } ?? "Done"
            recordConnectionEvent("shell command finished exit=\(exitCode.map(String.init) ?? "unknown") elapsed=\(String(format: "%.1f", elapsed))s")
            guard elapsed >= 5 else { return }
            notifyAgentFinished(exitCode: exitCode)
        case .promptStart, .promptEnd:
            break
        case .unknown(let payload):
            recordConnectionEvent("shell osc unknown \(payload)")
        }
    }

    private func notifyAgentFinished(exitCode: Int?) {
        requestNotificationAuthorizationIfNeeded()
        if isAppActive {
            UINotificationFeedbackGenerator().notificationOccurred(exitCode == 0 ? .success : .warning)
            Self.playShortDing()
            return
        }
        let content = UNMutableNotificationContent()
        content.sound = Self.shortDingNotificationSound
        let request = UNNotificationRequest(
            identifier: "zelmux-agent-finished-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static var shortDingNotificationSound: UNNotificationSound {
        UNNotificationSound(named: UNNotificationSoundName("ZelmuxDing.wav"))
    }

    private static let shortDingSoundID: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "ZelmuxDing", withExtension: "wav") else {
            return nil
        }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        return status == kAudioServicesNoError ? soundID : nil
    }()

    private static func playShortDing() {
        if let soundID = shortDingSoundID {
            AudioServicesPlaySystemSound(soundID)
        } else {
            AudioServicesPlaySystemSound(1104)
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
        startupTask?.cancel()
        missingSessionName = nil
        showingSessionPicker = true
        refreshAvailableSessions()
    }

    func attachSession(_ session: SessionListItem) {
        startupTask?.cancel()
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
        terminalStream.reset()
        missingSessionName = nil
        sessionListError = nil
        connectionState = .connecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: false,
                persistSessionNameOnSuccess: session.name,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: generation
            )
        }
    }

    func createSession(_ sessionName: String) {
        startupTask?.cancel()
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
        terminalStream.reset()
        missingSessionName = nil
        sessionListError = nil
        connectionState = .connecting
        reconnectTask?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            await self?.connectWithRetry(
                profile: profile,
                token: token,
                isReconnect: false,
                allowCreate: true,
                persistSessionNameOnSuccess: trimmed,
                showPickerOnFailure: true,
                initialFailureMessage: nil,
                generation: generation
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
        transport.onTerminalData = { [weak self, weak transport] data in
            guard let self,
                  self.transport === transport,
                  generation == self.connectionGeneration else {
                return
            }
            if AppBuild.diagnosticsEnabled {
                self.terminalBytesReceived += data.count
            }
            self.terminalStream.append(data)
        }
        transport.onControlEvent = { [weak self, weak transport] event in
            guard let self,
                  self.transport === transport,
                  generation == self.connectionGeneration else {
                return
            }
            self.handleControlEvent(event)
        }
        var connectedAt: Date?
        transport.onClose = { [weak self, weak transport] close in
            Task { @MainActor in
                guard let self, self.transport === transport else { return }
                if AppBuild.diagnosticsEnabled {
                    self.lastClose = close
                }
                if !self.isAppActive {
                    self.recordConnectionEvent("websocket closed while inactive: \(close.message)")
                    self.transport = nil
                    transport?.disconnect()
                    self.connectionState = .disconnected
                    return
                }
                if close.code == 4404 {
                    self.handleSessionNotFoundClose(profile: profile, reason: close.message)
                    return
                }
                if close.code == 4405 {
                    self.handleWebClientsForbiddenClose(reason: close.reason ?? close.message)
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
            inputSequence = 0
            await transport.resetInputSequence()
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
            connectionState = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private func handleImmediateWebSocketClose(_ reason: String) {
        recordConnectionEvent("immediate websocket close: \(reason)")
        let hint = "The server closed the web session immediately. For existing Zellij sessions, open the Share plugin on the Mac with Ctrl-o then s, or set web_sharing \"on\" in ~/.config/zellij/config.kdl and restart the session."
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

    private func handleWebClientsForbiddenClose(reason: String) {
        recordConnectionEvent("web clients forbidden close: \(reason)")
        transport?.disconnect()
        transport = nil
        activeSession = nil
        missingSessionName = nil
        sessionListError = "\(reason)\nOpen the Share plugin on the Mac with Ctrl-o then s, or set web_sharing \"on\" in ~/.config/zellij/config.kdl and restart the session. Then refresh."
        lastSessionListSummary = "Web clients are disabled for this session."
        connectionState = .failed("Web clients are disabled")
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
            sendResizeNow(rows: lastResize.rows, cols: lastResize.cols, metrics: lastTerminalMetrics)
        case .switchedSession(let session):
            recordConnectionEvent("control switched session \(session)")
            showSessionSwitchNotice(session)
        case .log(let lines):
            recordConnectionEvent("control log: \(lines.joined(separator: " "))")
        case .logError(let lines):
            recordConnectionEvent("control error: \(lines.joined(separator: " "))")
        case .setConfig(_, let theme, let macOptionIsMeta):
            recordConnectionEvent("control SetConfig theme=\(theme == nil ? "nil" : "present") macOptionIsMeta=\(macOptionIsMeta.map { String($0) } ?? "nil")")
            zellijTheme = theme
            if let macOptionIsMeta {
                optionAsMetaKey = macOptionIsMeta
            }
        case .unknown:
            break
        }
    }

    private func showSessionSwitchNotice(_ session: String) {
        sessionSwitchNoticeTask?.cancel()
        sessionSwitchNotice = session.isEmpty ? "Switched session" : "Switched to \(session)"
        sessionSwitchNoticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sessionSwitchNotice = nil
                self?.sessionSwitchNoticeTask = nil
            }
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
                self.recordConnectionEvent("network interface changed; reconnecting")
                self.reconnect(reason: "network interface change")
            }
        }
        monitor.start(queue: DispatchQueue(label: "Zelmux.Network"))
        self.monitor = monitor
    }

    var diagnosticLogText: String {
        guard AppBuild.diagnosticsEnabled else {
            return "Diagnostics are disabled in this build."
        }
        var lines = [
            "Server: \(selectedProfile?.baseURL.absoluteString ?? "none")",
            "Profile: \(selectedProfile?.name ?? "none")",
            "Session: \(selectedProfile?.sessionName ?? "none")",
            "State: \(connectionState.label)",
            "Version: \(activeSession?.version ?? "unknown")",
            "Read-only: \(activeSession?.isReadOnly == true ? "yes" : "no")",
            "Terminal bytes: \(terminalBytesReceived)",
            "Reconnects: \(reconnectCount)",
            "Memory warnings: \(memoryWarningCount)"
        ]
        if let lastClose {
            lines.append("Last close: \(lastClose.message)")
        }
        if let lastSessionListSummary {
            lines.append("Sessions: \(lastSessionListSummary)")
        }
        if let lastObservedPublicKeyHash {
            lines.append("Observed SPKI: \(lastObservedPublicKeyHash)")
        }
        lines.append("")
        lines.append(contentsOf: connectionLog.map { $0.copyLine })
        return lines.joined(separator: "\n")
    }

    private func wireTransportLog(_ transport: ZellijWebTransport) {
        guard AppBuild.diagnosticsEnabled else { return }
        transport.onLog = { [weak self] message in
            Task { @MainActor in
                self?.recordConnectionEvent(message)
            }
        }
    }

    private func recordConnectionEvent(_ message: String) {
        guard AppBuild.diagnosticsEnabled else { return }
        connectionLog.append(ConnectionLogEntry(message: message))
        if connectionLog.count > 50 {
            connectionLog.removeFirst(connectionLog.count - 50)
        }
    }

    private static func summaryStatus(fromTerminalTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let tokenRange = trimmed.range(
            of: #"(?<!\d)\d{1,6}\s*/\s*\d{2,6}(?!\d)"#,
            options: .regularExpression
        ) {
            return String(trimmed[tokenRange]).replacingOccurrences(of: " ", with: "")
        }
        for marker in ["Working", "Done", "Thinking", "Idle", "Running"] where trimmed.localizedCaseInsensitiveContains(marker) {
            return marker
        }
        return String(trimmed.prefix(28))
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

extension Notification.Name {
    static let zelmuxMemoryPressure = Notification.Name("Zelmux.MemoryPressure")
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
