import Foundation

public enum RemoteSessionActionKind: String, Codable, Sendable, CaseIterable {
    case send = "session-send"
    case abort = "session-abort"
    case setBudget = "set-session-budget"
    case answerBudget = "answer-session-budget"
}

public enum RemotePromptMode: String, Codable, Sendable, CaseIterable {
    case enqueue
    case immediate

    public var title: String {
        switch self {
        case .enqueue: "Run after current task"
        case .immediate: "Steer current task"
        }
    }
}

public struct RemoteWorkflowActionResult: Equatable, Sendable {
    public let state: RemoteOperationState
    public let message: String?
    public let operationId: String?

    public init(state: RemoteOperationState, message: String? = nil, operationId: String? = nil) {
        self.state = state
        self.message = message
        self.operationId = operationId
    }
}

/// A closed set of user actions, not an arbitrary SDK RPC proxy.
public struct RemoteSessionAction: Codable, Equatable, Sendable {
    public let kind: RemoteSessionActionKind
    public var prompt: String?
    public var mode: RemotePromptMode?
    public var maxAiCredits: Double?
    public var requestId: String?
    public var additionalAiCredits: Double?

    public init(
        kind: RemoteSessionActionKind,
        prompt: String? = nil,
        mode: RemotePromptMode? = nil,
        maxAiCredits: Double? = nil,
        requestId: String? = nil,
        additionalAiCredits: Double? = nil
    ) {
        self.kind = kind
        self.prompt = prompt
        self.mode = mode
        self.maxAiCredits = maxAiCredits
        self.requestId = requestId
        self.additionalAiCredits = additionalAiCredits
    }

    public var isValid: Bool {
        switch kind {
        case .send:
            guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= 8_192, mode != nil else { return false }
            return maxAiCredits == nil && requestId == nil && additionalAiCredits == nil
        case .abort:
            return prompt == nil && mode == nil && maxAiCredits == nil
                && requestId == nil && additionalAiCredits == nil
        case .setBudget:
            return prompt == nil && mode == nil && requestId == nil
                && additionalAiCredits == nil
                && (maxAiCredits.map { $0.isFinite && $0 >= 30 } ?? true)
        case .answerBudget:
            guard let requestId, !requestId.isEmpty, requestId.utf8.count <= 200 else { return false }
            return prompt == nil && mode == nil && maxAiCredits == nil
                && (additionalAiCredits.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }
}

public struct RemoteBudgetRequest: Codable, Equatable, Sendable, Identifiable {
    public let requestId: String
    public let maxAiCredits: Double
    public let usedAiCredits: Double
    public var id: String { requestId }

    public init(requestId: String, maxAiCredits: Double, usedAiCredits: Double) {
        self.requestId = requestId
        self.maxAiCredits = maxAiCredits
        self.usedAiCredits = usedAiCredits
    }
}

public struct RemoteWorkflowAgent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct RemoteSessionWorkflow: Codable, Equatable, Sendable {
    public let version: Int
    public var observedAtMilliseconds: Int64
    public let capabilities: [String]
    public let sendReady: Bool
    public let legacyPromptFallback: Bool?
    public let totalAiCredits: Double?
    public let contextTokens: Int?
    public let contextTokenLimit: Int?
    public let limitsKnown: Bool
    public let maxAiCredits: Double?
    public let budgetRequest: RemoteBudgetRequest?
    public let agents: [RemoteWorkflowAgent]
    public let schedules: [String]
    public let error: String?

    public init(
        version: Int = 1,
        observedAtMilliseconds: Int64,
        capabilities: [String],
        sendReady: Bool,
        legacyPromptFallback: Bool? = nil,
        totalAiCredits: Double? = nil,
        contextTokens: Int? = nil,
        contextTokenLimit: Int? = nil,
        limitsKnown: Bool = false,
        maxAiCredits: Double? = nil,
        budgetRequest: RemoteBudgetRequest? = nil,
        agents: [RemoteWorkflowAgent] = [],
        schedules: [String] = [],
        error: String? = nil
    ) {
        self.version = version
        self.observedAtMilliseconds = observedAtMilliseconds
        self.capabilities = capabilities
        self.sendReady = sendReady
        self.legacyPromptFallback = legacyPromptFallback
        self.totalAiCredits = totalAiCredits
        self.contextTokens = contextTokens
        self.contextTokenLimit = contextTokenLimit
        self.limitsKnown = limitsKnown
        self.maxAiCredits = maxAiCredits
        self.budgetRequest = budgetRequest
        self.agents = agents
        self.schedules = schedules
        self.error = error
    }

    public func isFresh(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince1970 * 1_000 - Double(observedAtMilliseconds)
        return version == 1 && age >= 0 && age <= 15_000
    }

    public func supports(_ kind: RemoteSessionActionKind, at date: Date = Date()) -> Bool {
        isFresh(at: date) && capabilities.contains(kind.rawValue)
    }
}

public struct RemoteTaskFileChange: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let diff: String
    public let truncated: Bool
    public var id: String { path }

    public init(path: String, diff: String, truncated: Bool = false) {
        self.path = path
        self.diff = diff
        self.truncated = truncated
    }
}

public struct RemoteTaskDiff: Codable, Equatable, Sendable {
    public let requestedMode: String
    public let mode: String
    public let isFallback: Bool
    public let unavailableReason: String?
    public let truncated: Bool
    public let changes: [RemoteTaskFileChange]

    public init(
        requestedMode: String, mode: String, isFallback: Bool,
        unavailableReason: String? = nil, truncated: Bool = false,
        changes: [RemoteTaskFileChange]
    ) {
        self.requestedMode = requestedMode
        self.mode = mode
        self.isFallback = isFallback
        self.unavailableReason = unavailableReason
        self.truncated = truncated
        self.changes = changes
    }

    public var title: String {
        mode == "session" && !isFallback
            ? "Changes in this session"
            : "Working-tree changes (not attributed to this task)"
    }
}

public struct RemoteTaskCheck: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let exitCode: Int?
    public let workingDirectory: String?

    public init(id: String, title: String, exitCode: Int?, workingDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.exitCode = exitCode
        self.workingDirectory = workingDirectory
    }

    public var outcome: String {
        exitCode.map { "Exited \($0)" } ?? "Completion not verified"
    }
}

public struct RemoteTaskResult: Codable, Equatable, Sendable {
    public let turnId: String
    public let capturedAt: Date
    public let status: String
    public let summary: String?
    public let branch: String?
    public let repository: String?
    public let diff: RemoteTaskDiff?
    public let checks: [RemoteTaskCheck]
    public let pullRequests: [String]
    public let error: String?

    public init(
        turnId: String, capturedAt: Date, status: String, summary: String? = nil,
        branch: String? = nil, repository: String? = nil, diff: RemoteTaskDiff? = nil,
        checks: [RemoteTaskCheck] = [], pullRequests: [String] = [], error: String? = nil
    ) {
        self.turnId = turnId
        self.capturedAt = capturedAt
        self.status = status
        self.summary = summary
        self.branch = branch
        self.repository = repository
        self.diff = diff
        self.checks = checks
        self.pullRequests = pullRequests
        self.error = error
    }
}
