import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            scheduleSave()
        }
    }

    private let url: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZellijAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("settings-v1.json")
        self.settings = Self.load(from: url)
    }

    var selectedProfile: ZellijProfile? {
        guard let id = settings.selectedProfileID else { return settings.profiles.first }
        return settings.profiles.first { $0.id == id } ?? settings.profiles.first
    }

    func upsertProfile(_ profile: ZellijProfile, token: String?) {
        if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
            settings.profiles[index] = profile
        } else {
            settings.profiles.append(profile)
        }
        settings.selectedProfileID = profile.id
        if let token, !token.isEmpty {
            try? KeychainStore.saveToken(token, profileID: profile.id)
        }
        saveImmediately()
    }

    func selectProfile(_ profile: ZellijProfile) {
        settings.selectedProfileID = profile.id
    }

    func updateTrustedPublicKeyHash(_ hash: String, for profileID: UUID) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.profiles[index].trustedPublicKeyHash = hash
        saveImmediately()
    }

    func updateSessionName(_ sessionName: String, for profileID: UUID) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        settings.profiles[index].sessionName = sessionName
        saveImmediately()
    }

    func addPromptToHistory(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.promptHistory.removeAll { $0 == trimmed }
        settings.promptHistory.insert(trimmed, at: 0)
        if settings.promptHistory.count > 100 {
            settings.promptHistory.removeLast(settings.promptHistory.count - 100)
        }
    }

    private static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .empty
        }
        return decoded.mergingDefaultSnippets()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.saveImmediately()
        }
    }

    private func saveImmediately() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}
