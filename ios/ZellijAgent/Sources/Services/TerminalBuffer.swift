import Foundation

@MainActor
final class TerminalBuffer: ObservableObject {
    @Published private(set) var text = ""

    private let maxCharacters = 120_000
    private var pendingData = Data()

    func append(_ data: Data) {
        pendingData.append(data)
        appendDecodablePrefix()
    }

    func append(_ chunk: String) {
        let readable = ANSITextSanitizer.readableText(from: chunk)
        guard !readable.isEmpty else { return }
        text.append(readable)
        trimIfNeeded()
    }

    func clear() {
        text.removeAll(keepingCapacity: true)
        pendingData.removeAll(keepingCapacity: true)
    }

    private func appendDecodablePrefix() {
        guard !pendingData.isEmpty else { return }

        var validLength = pendingData.count
        while validLength > 0 {
            if let decoded = String(data: pendingData.prefixData(validLength), encoding: .utf8) {
                append(decoded)
                pendingData.removeFirst(validLength)
                return
            }
            validLength -= 1
        }

        if pendingData.count > 4 {
            append(String(decoding: pendingData, as: UTF8.self))
            pendingData.removeAll(keepingCapacity: true)
        }
    }

    private func trimIfNeeded() {
        guard text.count > maxCharacters else { return }
        let start = text.index(text.endIndex, offsetBy: -maxCharacters)
        text = String(text[start...])
    }
}

private extension Data {
    func prefixData(_ length: Int) -> Data {
        Data(prefix(length))
    }
}
