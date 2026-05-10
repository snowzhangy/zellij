import Foundation

struct ZellijProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var sessionName: String
    var trustedPublicKeyHash: String?

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: URL,
        sessionName: String,
        trustedPublicKeyHash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.sessionName = sessionName
        self.trustedPublicKeyHash = trustedPublicKeyHash
    }
}

struct AppSettings: Codable {
    var profiles: [ZellijProfile]
    var selectedProfileID: UUID?
    var fontSize: Double
    var promptHistory: [String]
    var snippets: [String]

    static let empty = AppSettings(
        profiles: [],
        selectedProfileID: nil,
        fontSize: 12,
        promptHistory: [],
        snippets: [
            "/resume",
            "/fork",
            "/memory",
            "/compact",
            "/clear",
            "/help"
        ]
    )
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
