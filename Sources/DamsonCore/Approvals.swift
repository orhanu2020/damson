import Foundation
import DamsonTools

/// Collects tool approval requests. Voice or UI resolves them; helpers wait here until then.
public final class ApprovalCenter: Approver, @unchecked Sendable {
    private struct Pending {
        var request: ApprovalRequest
        var continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    private let pending = LockedBox()
    private var items: [String: Pending] = [:]
    private var order: [String] = []

    public var onRequested: (@Sendable (ApprovalRequest) -> Void)?
    public var onResolved: (@Sendable (ApprovalRequest, ApprovalDecision) -> Void)?

    public init() {}

    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        return await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
            pending.lock.lock()
            items[request.id] = Pending(request: request, continuation: continuation)
            order.append(request.id)
            pending.lock.unlock()
            onRequested?(request)
        }
    }

    public func pendingRequests() -> [ApprovalRequest] {
        pending.lock.lock()
        defer { pending.lock.unlock() }
        return order.compactMap { items[$0]?.request }
    }

    @discardableResult
    public func resolve(id: String, decision: ApprovalDecision) -> ApprovalRequest? {
        pending.lock.lock()
        let entry = items.removeValue(forKey: id)
        order.removeAll { $0 == id }
        pending.lock.unlock()
        guard let entry = entry else { return nil }
        onResolved?(entry.request, decision)
        entry.continuation.resume(returning: decision)
        return entry.request
    }

    public func denyAll(taskID: String? = nil) {
        let ids = pendingRequests().filter { taskID == nil || $0.taskID == taskID }.map { $0.id }
        for id in ids { resolve(id: id, decision: .deny) }
    }
}

/// Tiny holder so a plain NSLock can live in a class used from async code only inside sync sections.
final class LockedBox: @unchecked Sendable {
    let lock = NSLock()
}
