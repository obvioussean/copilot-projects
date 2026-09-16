import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionWorkflowTests: XCTestCase {
    private func resultTurn(_ id: String, kind: String = "foreground", pending: Bool = false) -> TranscriptTurn {
        TranscriptTurn(
            id: id, startedAt: Date(timeIntervalSince1970: pending ? 200 : 100),
            endedAt: pending ? nil : Date(timeIntervalSince1970: 150), kind: kind,
            userContent: id, assistantMessages: [], tools: [], isAborted: false
        )
    }

    func testDrawerResultStaysBeforeNewPromptEvenWhenCapturedLate() {
        for kind in ["foreground", "scheduled", "automated"] {
            let rows = TranscriptDrawerRow.make(
                turns: [resultTurn("old", kind: kind), resultTurn("pending", pending: true)],
                latestResult: RemoteTaskResult(
                    turnId: "old", capturedAt: Date(timeIntervalSince1970: 300), status: "finished"
                )
            )
            XCTAssertEqual(rows.map(\.id), ["turn-old", "result-old", "turn-pending"], kind)
        }
    }

    func testDrawerKeepsOnlyTheLatestResultAtItsMatchingTurn() {
        let turns = [resultTurn("old"), resultTurn("new")]
        XCTAssertEqual(
            TranscriptDrawerRow.make(turns: turns, latestResult: nil).map(\.id),
            ["turn-old", "turn-new"]
        )
        for status in ["finished", "stopped", "blocked"] {
            let result = RemoteTaskResult(turnId: "new", capturedAt: Date(), status: status)
            let rows = TranscriptDrawerRow.make(turns: turns, latestResult: result)
            XCTAssertEqual(rows.map(\.id), ["turn-old", "turn-new", "result-new"])
            guard case .result(let rendered) = rows.last else {
                return XCTFail("Expected the matching result after the last turn")
            }
            XCTAssertEqual(rendered, result)
        }
    }

    func testActionValidationIsClosedAndBudgetLimitsAreExplicit() throws {
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "hello", mode: .enqueue).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .send, prompt: "hello").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .abort, prompt: "unexpected").isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: 29).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .setBudget, maxAiCredits: .infinity).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget, maxAiCredits: 30).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .setBudget).isValid)
        XCTAssertFalse(RemoteSessionAction(kind: .answerBudget, requestId: "id", additionalAiCredits: 0).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .answerBudget, requestId: "id").isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionAction.self, from: Data(#"{"kind":"arbitrary-rpc"}"#.utf8)
        ))
    }

    func testWorkflowCapabilityRequiresCurrentVersionAndFreshEvidence() {
        let date = Date()
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000),
            capabilities: ["session-send"], sendReady: true
        )
        XCTAssertTrue(workflow.supports(.send, at: date))
        XCTAssertFalse(workflow.supports(.abort, at: date))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(16)))
        XCTAssertFalse(workflow.supports(.send, at: date.addingTimeInterval(-1)))
    }

    @MainActor
    func testNativeHostActionsUseDistinctHandoffsAndNeverInjectTerminalInput() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let session = Session(title: "Native actions", cwd: root.path)
        let project = Project(name: "Workflow test", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false }, agentActivityDirectory: sessions, resumeMarkerDirectory: sessions,
            remotePromptTarget: { _ in
                RemotePromptTarget(activity: .idle, send: { _ in
                    XCTFail("Native actions must not touch the terminal draft")
                    return false
                })
            },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        let now = Date()
        let sdkID = UUID().uuidString
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            pendingPermissionRequestIds: [], copilotSessionId: sdkID,
            conversationEpoch: "epoch-1", operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue), sendReady: true,
                limitsKnown: true
            )
        )
        let snapshotURL = sessions.appendingPathComponent("\(session.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        try Data(sdkID.utf8).write(to: sessions.appendingPathComponent("\(session.id).copilot-session"))
        let send = RemoteSessionAction(kind: .send, prompt: "native", mode: .immediate)
        let sendID = CLIOperationRequest(operationId: "send", conversationEpoch: "epoch-1")
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: send, operation: sendID), .accepted)
        let stop = RemoteSessionAction(kind: .abort)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: stop,
            operation: CLIOperationRequest(operationId: "stop", conversationEpoch: "epoch-1")
        ), .accepted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-send.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent("\(session.id).session-abort.json").path))
        XCTAssertEqual(model.performSessionAction(sessionId: session.id, action: stop, operation: sendID), .conflict)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "old", conversationEpoch: "epoch-0")
        ), .conflict)
        try FileManager.default.removeItem(at: sessions.appendingPathComponent("\(session.id).session-send.json"))
        snapshot.pendingPermissionRequestIds = ["pending"]
        try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        XCTAssertEqual(model.performSessionAction(
            sessionId: session.id, action: send,
            operation: CLIOperationRequest(operationId: "blocked", conversationEpoch: "epoch-1")
        ), .invalid)
    }

    func testResultSidecarRequiresExactConversationAndRetainedTurn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let turn = TranscriptTurn(
            id: "turn", startedAt: Date(), endedAt: Date(), kind: "foreground",
            userContent: "work", assistantMessages: [], tools: [], isAborted: false
        )
        let snapshot = TranscriptSnapshot(schemaVersion: 3, updatedAt: Date(), copilotSessionId: "sdk", turns: [turn])
        struct Envelope: Encodable {
            let schemaVersion = 1
            let copilotSessionId: String
            let result: RemoteTaskResult
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let result = RemoteTaskResult(turnId: "turn", capturedAt: Date(), status: "finished")
        let url = root.appendingPathComponent("tab.task-result.json")
        try encoder.encode(Envelope(copilotSessionId: "other", result: result)).write(to: url)
        XCTAssertNil(TranscriptController.attachingTaskResult(snapshot, sessionId: "tab", directory: root).latestResult)
        try encoder.encode(Envelope(copilotSessionId: "sdk", result: result)).write(to: url)
        let attached = TranscriptController.attachingTaskResult(snapshot, sessionId: "tab", directory: root)
        XCTAssertEqual(attached.latestResult?.turnId, "turn")
        XCTAssertEqual(attached.limitedToMostRecentTurns(1).latestResult, attached.latestResult)
        XCTAssertEqual(TranscriptImageAssociation.attach(images: [], to: attached).latestResult, attached.latestResult)
    }
}
