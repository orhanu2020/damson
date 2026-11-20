import Foundation
import DamsonSupport

/// Broadcasts engine events to any number of subscribers (UI, notifier, voice).
public final class EventBus: @unchecked Sendable {
    private let subscribers = Locked<[UUID: AsyncStream<DamsonEvent>.Continuation]>([:])

    public init() {}

    public func subscribe() -> AsyncStream<DamsonEvent> {
        return AsyncStream<DamsonEvent> { continuation in
            let id = UUID()
            self.subscribers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    public func publish(_ event: DamsonEvent) {
        let all = subscribers.current.values
        for continuation in all { continuation.yield(event) }
    }
}
