import Foundation

enum ZellijWireCodec {
    static func encodeResize(webClientID: String, rows: Int, cols: Int) throws -> String {
        let message = ClientControlMessage(
            webClientID: webClientID,
            payload: .terminalResize(TerminalResize(rows: rows, cols: cols))
        )
        let data = try JSONEncoder.zellij.encode(message)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        return json
    }

    static func decodeControlEvent(from data: Data) throws -> ZellijControlEvent {
        let raw = try JSONDecoder.zellij.decode(RawControlMessage.self, from: data)
        switch raw.type {
        case "SetConfig":
            return .setConfig(font: raw.font, macOptionIsMeta: raw.macOptionIsMeta)
        case "QueryTerminalSize":
            return .queryTerminalSize
        case "SwitchedSession":
            return .switchedSession(raw.newSessionName ?? "")
        case "Log":
            return .log(raw.lines ?? [])
        case "LogError":
            return .logError(raw.lines ?? [])
        default:
            return .unknown(raw.type)
        }
    }

    enum CodecError: Error {
        case invalidUTF8
    }
}

private struct ClientControlMessage: Encodable {
    let webClientID: String
    let payload: Payload

    enum CodingKeys: String, CodingKey {
        case webClientID = "web_client_id"
        case payload
    }

    enum Payload: Encodable {
        case terminalResize(TerminalResize)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            switch self {
            case .terminalResize(let size):
                try container.encode("TerminalResize", forKey: DynamicCodingKey("type"))
                try container.encode(size.rows, forKey: DynamicCodingKey("rows"))
                try container.encode(size.cols, forKey: DynamicCodingKey("cols"))
            }
        }
    }
}

private struct RawControlMessage: Decodable {
    let type: String
    let font: String?
    let macOptionIsMeta: Bool?
    let newSessionName: String?
    let lines: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case font
        case macOptionIsMeta = "mac_option_is_meta"
        case newSessionName = "new_session_name"
        case lines
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension JSONEncoder {
    static let zellij = JSONEncoder()
}

extension JSONDecoder {
    static let zellij = JSONDecoder()
}
