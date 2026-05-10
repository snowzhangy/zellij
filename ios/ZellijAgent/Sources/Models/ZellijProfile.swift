import Foundation

struct ZellijProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var sessionName: String
    var trustedPublicKeyHash: String?
    var touchMode: TouchMode

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        sessionName: String,
        trustedPublicKeyHash: String? = nil,
        touchMode: TouchMode = .scroll
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.sessionName = sessionName
        self.trustedPublicKeyHash = trustedPublicKeyHash
        self.touchMode = touchMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        trustedPublicKeyHash = try container.decodeIfPresent(String.self, forKey: .trustedPublicKeyHash)
        touchMode = try container.decodeIfPresent(TouchMode.self, forKey: .touchMode) ?? .scroll
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case sessionName
        case trustedPublicKeyHash
        case touchMode
    }
}

enum TouchMode: String, Codable, CaseIterable, Identifiable {
    case scroll
    case select
    case mouse

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .scroll:
            return "Scroll"
        case .select:
            return "Select"
        case .mouse:
            return "Mouse"
        }
    }

    var detail: String {
        switch self {
        case .scroll:
            return "Drag scrolls terminal history; long-press and double-tap still select."
        case .select:
            return "Long-press or double-tap, then drag to adjust selection."
        case .mouse:
            return "Taps and drags are sent to Zellij panes."
        }
    }
}

struct AppSettings: Codable {
    var profiles: [ZellijProfile]
    var selectedProfileID: UUID?
    var fontSize: Double
    var promptHistory: [String]
    var snippets: [String]

    static let defaultSnippets = [
        "/resume",
        "/fork",
        "/memory",
        "/compact",
        "/clear",
        "/help",
        "/model",
        "/status",
        "/cost",
        "/init",
        "/diff",
        "/new"
    ]

    static let empty = AppSettings(
        profiles: [],
        selectedProfileID: nil,
        fontSize: 12,
        promptHistory: [],
        snippets: defaultSnippets
    )

    func mergingDefaultSnippets() -> AppSettings {
        var copy = self
        for snippet in Self.defaultSnippets where !copy.snippets.contains(snippet) {
            copy.snippets.append(snippet)
        }
        return copy
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(version: String?)
    case reconnecting
    case failed(String)

    var label: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected(let version):
            return version.map { "Connected \($0)" } ?? "Connected"
        case .reconnecting:
            return "Reconnecting"
        case .failed(let message):
            return message
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var canStartReconnect: Bool {
        switch self {
        case .connected, .failed:
            return true
        case .disconnected, .connecting, .reconnecting:
            return false
        }
    }
}
