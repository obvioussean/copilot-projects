import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
/// Host-owned transcript windows preserve image association and legacy JSON.
final class RemoteTranscriptOptimizationTests: XCTestCase {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixtureTurn(index: Int) -> TranscriptTurn {
        TranscriptTurn(
            id: "turn-\(index)",
            startedAt: Self.epoch.addingTimeInterval(Double(index) * 100),
            endedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 50),
            kind: "foreground",
            userContent: "ask \(index)",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "message-\(index)",
                    timestamp: Self.epoch.addingTimeInterval(Double(index) * 100 + 10),
                    content: "reply \(index)"
                )
            ],
            tools: [],
            isAborted: false
        )
    }

    private func fixtureSnapshot(turnCount: Int) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Self.epoch,
            copilotSessionId: "copilot-session",
            turns: (0..<turnCount).map(fixtureTurn(index:))
        )
    }

    /// One retained image per turn index, displayed just after that turn began.
    private func fixtureImages(forTurnIndexes indexes: [Int]) -> [RemoteKittyImageCapture.RetainedImageInfo] {
        indexes.map { index in
            RemoteKittyImageCapture.RetainedImageInfo(
                imageId: UInt32(index + 1),
                version: UInt64(index + 1) << 32 | 7,
                displayedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 5)
            )
        }
    }

    private func decode(_ data: Data) throws -> TranscriptSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptSnapshot.self, from: data)
    }

    // MARK: - Response payload

    func testTranscriptResponseAppliesWindowAfterImageAssociation() throws {
        let snapshot = fixtureSnapshot(turnCount: 6)
        // Images displayed during turns 1 and 4 — one inside the window a
        // `limit=2` response returns, one only in the dropped prefix.
        let images = fixtureImages(forTurnIndexes: [1, 4])

        let fullData = try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil
        ))
        let full = try decode(fullData)
        // The legacy shape is preserved byte-for-byte: no window, no metadata.
        XCTAssertNil(full.totalTurns)
        XCTAssertFalse(
            String(decoding: fullData, as: UTF8.self).contains("totalTurns"),
            "an unlimited response must not carry window metadata"
        )
        XCTAssertEqual(full.turns.count, 6)
        XCTAssertEqual(full.turns[1].images?.map(\.imageId), [2])
        XCTAssertEqual(full.turns[4].images?.map(\.imageId), [5])

        let limited = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: 2
        )))
        XCTAssertEqual(limited.totalTurns, 6)
        XCTAssertEqual(limited.turns.map(\.id), ["turn-4", "turn-5"])
        // Association ran against the full transcript, so a windowed turn's
        // images are exactly the ones the unlimited response reports…
        XCTAssertEqual(limited.turns[0].images, full.turns[4].images)
        XCTAssertEqual(limited.turns[1].images, full.turns[5].images)
        // …and the image displayed during a dropped turn is not re-anchored onto
        // whatever turn happens to be oldest in the window.
        let windowedImageIds = limited.turns.flatMap { $0.images?.map(\.imageId) ?? [] }
        XCTAssertEqual(windowedImageIds, [5])

        // Every window agrees with the unlimited response, turn for turn.
        for limit in 1...6 {
            let windowed = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
                snapshot: snapshot, images: images, limit: limit
            )))
            XCTAssertEqual(windowed.turns.count, limit)
            XCTAssertEqual(windowed.totalTurns, 6)
            for turn in windowed.turns {
                let original = try XCTUnwrap(full.turns.first { $0.id == turn.id })
                XCTAssertEqual(turn, original)
            }
        }

        // A window wider than the transcript returns everything, still tagged so
        // the client can tell "this is all of it" from "the host ignored me".
        let wide = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: 200
        )))
        XCTAssertEqual(wide.turns.map(\.id), full.turns.map(\.id))
        XCTAssertEqual(wide.totalTurns, 6)

        // The pure slice keeps the legacy default when constructed directly.
        XCTAssertNil(fixtureSnapshot(turnCount: 3).totalTurns)
        XCTAssertEqual(fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).totalTurns, 3)
        XCTAssertEqual(
            fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).turns.map(\.id),
            ["turn-2"]
        )
    }

}
