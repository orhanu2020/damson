import Foundation
import DamsonTools

public enum DamsonEvent: Sendable {
    case approvalRequested(ApprovalRequest)
    case approvalResolved(ApprovalRequest, ApprovalDecision)
    case log(String)
}

public enum InputSource: String, Sendable {
    case text
    case voice
}
