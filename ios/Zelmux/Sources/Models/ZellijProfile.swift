import Foundation

struct ZellijProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var sessionName: String
    var trustedPublicKeyHash: String?
    var touchMode: TouchMode
    var lastTabPosition: Int?

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        sessionName: String,
        trustedPublicKeyHash: String? = nil,
        touchMode: TouchMode = .scroll,
        lastTabPosition: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.sessionName = sessionName
        self.trustedPublicKeyHash = trustedPublicKeyHash
        self.touchMode = touchMode
        self.lastTabPosition = lastTabPosition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        trustedPublicKeyHash = try container.decodeIfPresent(String.self, forKey: .trustedPublicKeyHash)
        touchMode = try container.decodeIfPresent(TouchMode.self, forKey: .touchMode) ?? .scroll
        lastTabPosition = try container.decodeIfPresent(Int.self, forKey: .lastTabPosition)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case sessionName
        case trustedPublicKeyHash
        case touchMode
        case lastTabPosition
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

    var systemImage: String {
        switch self {
        case .scroll:
            return "arrow.up.and.down"
        case .select:
            return "text.cursor"
        case .mouse:
            return "hand.tap"
        }
    }
}

enum TerminalColorSet: String, Codable, CaseIterable, Identifiable {
    case zellij
    case macDark
    case classicGreen

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .zellij:
            return "Zellij"
        case .macDark:
            return "Mac Dark"
        case .classicGreen:
            return "Classic Green"
        }
    }

    var detail: String {
        switch self {
        case .zellij:
            return "Use the theme sent by the Zellij web server."
        case .macDark:
            return "Use a neutral dark terminal palette."
        case .classicGreen:
            return "Use the original green-on-black Zelmux palette."
        }
    }
}

struct AppSettings: Codable {
    var profiles: [ZellijProfile]
    var selectedProfileID: UUID?
    var fontSize: Double
    var terminalColorSet: TerminalColorSet
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
        terminalColorSet: .zellij,
        promptHistory: [],
        snippets: defaultSnippets
    )

    init(
        profiles: [ZellijProfile],
        selectedProfileID: UUID?,
        fontSize: Double,
        terminalColorSet: TerminalColorSet,
        promptHistory: [String],
        snippets: [String]
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.fontSize = fontSize
        self.terminalColorSet = terminalColorSet
        self.promptHistory = promptHistory
        self.snippets = snippets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([ZellijProfile].self, forKey: .profiles)
        selectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 12
        terminalColorSet = try container.decodeIfPresent(TerminalColorSet.self, forKey: .terminalColorSet) ?? .zellij
        promptHistory = try container.decodeIfPresent([String].self, forKey: .promptHistory) ?? []
        snippets = try container.decodeIfPresent([String].self, forKey: .snippets) ?? Self.defaultSnippets
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case selectedProfileID
        case fontSize
        case terminalColorSet
        case promptHistory
        case snippets
    }

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
