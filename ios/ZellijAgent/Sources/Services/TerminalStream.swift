import Combine
import Foundation

@MainActor
final class TerminalStream: ObservableObject {
    @Published private(set) var revision = 0
    private var chunks: [[UInt8]] = []

    func append(_ data: Data) {
        chunks.append(Array(data))
        revision &+= 1
    }

    func drain() -> [[UInt8]] {
        let drained = chunks
        chunks.removeAll(keepingCapacity: true)
        return drained
    }
}
