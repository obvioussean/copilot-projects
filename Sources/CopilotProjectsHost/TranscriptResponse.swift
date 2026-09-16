import Foundation
import CopilotProjectsProtocol

enum TranscriptResponse {
    static func encodedResponse(
        snapshot: TranscriptSnapshot,
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        limit: Int?
    ) -> Data? {
        // Associate before windowing so dropped turns cannot donate images to
        // the oldest visible turn.
        let augmented = TranscriptImageAssociation.attach(images: images, to: snapshot)
        let windowed = limit.map { augmented.limitedToMostRecentTurns($0) } ?? augmented
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(windowed)
    }
}
