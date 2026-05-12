import Combine
import Foundation

@MainActor
final class TerminalStream: ObservableObject {
    @Published private(set) var revision = 0
    private var pendingBytes: [UInt8] = []
    private var pendingReadOffset = 0
    private var publishTask: Task<Void, Never>?
    private var scheduledDelayNanoseconds: UInt64?
    private var lastUserInputAt = Date()
    private var isAppActive = true

    private static let interactiveDelayNanoseconds: UInt64 = 16_000_000
    private static let idleDelayNanoseconds: UInt64 = 100_000_000
    private static let backgroundDelayNanoseconds: UInt64 = 500_000_000
    private static let idleAfterSeconds: TimeInterval = 180
    private static let interactiveDrainBytes = 128 * 1024
    private static let idleDrainBytes = 192 * 1024
    private static let backgroundDrainBytes = 256 * 1024
    private static let compactOffsetBytes = 256 * 1024

    func append(_ data: Data) {
        compactIfDrained()
        pendingBytes.append(contentsOf: data)
        schedulePublish()
    }

    func markUserInput() {
        lastUserInputAt = Date()
        if hasPendingBytes {
            schedulePublish(allowReschedule: true)
        }
    }

    func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        if active, hasPendingBytes {
            schedulePublish(allowReschedule: true)
        }
    }

    func reset() {
        publishTask?.cancel()
        publishTask = nil
        scheduledDelayNanoseconds = nil
        pendingBytes.removeAll(keepingCapacity: true)
        pendingReadOffset = 0
    }

    private func schedulePublish() {
        schedulePublish(allowReschedule: false)
    }

    private func schedulePublish(allowReschedule: Bool) {
        let delay = currentPublishDelayNanoseconds()
        if let publishTask {
            guard allowReschedule,
                  let scheduledDelayNanoseconds,
                  delay < scheduledDelayNanoseconds else {
                return
            }
            publishTask.cancel()
            self.publishTask = nil
            self.scheduledDelayNanoseconds = nil
        }
        scheduledDelayNanoseconds = delay
        publishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.publishTask = nil
                self.scheduledDelayNanoseconds = nil
                guard self.hasPendingBytes else { return }
                self.revision &+= 1
            }
        }
    }

    private func currentPublishDelayNanoseconds() -> UInt64 {
        guard isAppActive else {
            return Self.backgroundDelayNanoseconds
        }
        if Date().timeIntervalSince(lastUserInputAt) > Self.idleAfterSeconds {
            return Self.idleDelayNanoseconds
        }
        return Self.interactiveDelayNanoseconds
    }

    func drainForFrame() -> [UInt8] {
        guard hasPendingBytes else { return [] }
        let byteCount = min(currentDrainByteLimit(), pendingBytes.count - pendingReadOffset)
        let endOffset = pendingReadOffset + byteCount
        let drained = Array(pendingBytes[pendingReadOffset..<endOffset])
        pendingReadOffset = endOffset

        if hasPendingBytes {
            compactIfNeeded()
            schedulePublish(allowReschedule: true)
        } else {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingReadOffset = 0
        }
        return drained
    }

    private var hasPendingBytes: Bool {
        pendingReadOffset < pendingBytes.count
    }

    private func currentDrainByteLimit() -> Int {
        guard isAppActive else {
            return Self.backgroundDrainBytes
        }
        if Date().timeIntervalSince(lastUserInputAt) > Self.idleAfterSeconds {
            return Self.idleDrainBytes
        }
        return Self.interactiveDrainBytes
    }

    private func compactIfDrained() {
        if pendingReadOffset == pendingBytes.count {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingReadOffset = 0
        }
    }

    private func compactIfNeeded() {
        guard pendingReadOffset >= Self.compactOffsetBytes,
              pendingReadOffset > pendingBytes.count - pendingReadOffset else {
            return
        }
        pendingBytes.removeSubrange(0..<pendingReadOffset)
        pendingReadOffset = 0
    }
}
