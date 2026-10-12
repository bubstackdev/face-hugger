import Foundation
@testable import FaceHuggerCore

/// A scripted stand-in for an on-device model, so drafting tests never need Apple Intelligence.
final class FakeDraftModel: DatasetDraftModel, @unchecked Sendable {
    enum Behavior: Sendable {
        case reply(String)
        case rewrite(@Sendable (String) -> String)
        case fail(any Error)
        /// Waits in a throwing sleep, as a real model call does, until the task is cancelled.
        case waitForCancellation
        /// Keeps running after cancellation and then returns, like a model that ignores it.
        case replyAfterCancellation(String)
        /// Fails with a non-cancellation error once the task is cancelled.
        case failAfterCancellation(any Error)
    }

    let unavailableReason: String?
    private let behavior: Behavior
    private let lock = NSLock()
    private var received: [DatasetDraftRequest] = []

    init(_ behavior: Behavior, unavailableReason: String? = nil) {
        self.behavior = behavior
        self.unavailableReason = unavailableReason
    }

    var requests: [DatasetDraftRequest] { lock.withLock { received } }

    func paragraph(for request: DatasetDraftRequest) async throws -> String {
        lock.withLock { received.append(request) }
        switch behavior {
        case .reply(let text):
            return text
        case .rewrite(let transform):
            return transform(Self.purpose(in: request))
        case .fail(let error):
            throw error
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            return "unreachable"
        case .replyAfterCancellation(let text):
            await Self.untilCancelled()
            return text
        case .failAfterCancellation(let error):
            await Self.untilCancelled()
            throw error
        }
    }

    /// The owner's purpose, decoded from the prompt exactly as a model would see it.
    static func purpose(in request: DatasetDraftRequest) -> String {
        let json = Data(request.prompt.dropFirst(DatasetCardDrafter.promptPrefix.count).utf8)
        let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: String]
        return object?["purpose"] ?? ""
    }

    private static func untilCancelled() async {
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
    }
}
