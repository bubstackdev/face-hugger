import Foundation
import Testing
@testable import FaceHuggerCore

struct TransferActivityTests {
    private func request(_ kind: TransferBodyKind = .file, id: UUID = UUID(), attempt: Int = 1) -> TransferRequest {
        TransferRequest(id: id, attempt: attempt, maximumAttempts: 3, bodyKind: kind)
    }
    @Test func explicitRetrySendsAreCountedSeparatelyAndDuplicateCallbacksDoNotAddBytes() {
        var tracker = TransferTransportTracker()
        let first = request()
        tracker.apply(.started(first), at: 0)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: 1_000), at: 1)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: 1_000), at: 1.1)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: 800), at: 1.2)
        #expect(tracker.summary.uploadBodyBytes == 1_000)
        #expect(tracker.rate == 1_000)
        tracker.apply(.finished(requestID: first.id, attempt: 1), at: 2)
        #expect(tracker.rate == nil)
        let retry = TransferRetry(request: first, reason: .connection, resumesAt: Date())
        tracker.apply(.waiting(retry), at: 2)
        tracker.apply(.started(request(id: first.id, attempt: 2)), at: 3)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 2, cumulative: 600), at: 4)
        #expect(tracker.summary.requestBodyBytes == 1_600)
        #expect(tracker.summary.uploadBodyBytes == 1_600)
        #expect(tracker.summary.retryAttempts == 1)
        #expect(tracker.summary.retryWaits == 1)
        #expect(tracker.rate == 600)
        #expect(tracker.retry == nil)
    }
    @Test func metadataAndUploadBodiesHaveSeparateTotalsAndRates() {
        var tracker = TransferTransportTracker()
        let metadata = request(.metadata), commit = request(.commit)
        tracker.apply(.started(metadata), at: 0)
        tracker.apply(.bodyBytes(requestID: metadata.id, attempt: 1, cumulative: 300), at: 1)
        #expect(tracker.rate == nil)
        #expect(tracker.summary.uploadBodyBytes == 0)
        tracker.apply(.finished(requestID: metadata.id, attempt: 1), at: 1)
        tracker.apply(.started(commit), at: 2)
        tracker.apply(.bodyBytes(requestID: commit.id, attempt: 1, cumulative: 2_000), at: 3)
        #expect(tracker.summary.requestBodyBytes == 2_300)
        #expect(tracker.summary.uploadBodyBytes == 2_000)
        #expect(tracker.rate == 2_000)
    }
    @Test func staleCallbacksAndMissingMonotonicTimeCannotInventThroughput() {
        var tracker = TransferTransportTracker()
        let first = request(), second = request()
        tracker.apply(.started(first), at: nil)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: 1_000), at: nil)
        #expect(tracker.rate == nil)
        tracker.apply(.finished(requestID: first.id, attempt: 1), at: 1)
        tracker.apply(.started(second), at: 2)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: 8_000), at: 3)
        tracker.apply(.bodyBytes(requestID: second.id, attempt: 2, cumulative: 9_000), at: 3)
        #expect(tracker.summary.requestBodyBytes == 1_000)
        #expect(tracker.rate == nil)
    }
    @Test func throughputExpiresWhenIdleAndResetsAcrossRetryAndPhaseChanges() {
        var tracker = TransferTransportTracker()
        let current = request()
        tracker.apply(.started(current), at: 0)
        tracker.apply(.bodyBytes(requestID: current.id, attempt: 1, cumulative: 1_000), at: 1)
        #expect(tracker.rate == 1_000)
        tracker.refresh(at: 3.01); #expect(tracker.rate == nil)
        tracker.apply(.bodyBytes(requestID: current.id, attempt: 1, cumulative: 2_000), at: 4)
        #expect(tracker.rate != nil)
        tracker.suspendRate(); #expect(tracker.rate == nil)
        tracker.apply(.waiting(TransferRetry(request: current, reason: .serverError, resumesAt: Date())), at: 4)
        #expect(tracker.rate == nil)
        tracker.finish(); #expect(tracker.retry == nil); #expect(tracker.rate == nil)
    }
    @Test func byteCountersSaturateRatherThanOverflow() {
        var tracker = TransferTransportTracker()
        let first = request(), second = request()
        tracker.apply(.started(first), at: 0)
        tracker.apply(.bodyBytes(requestID: first.id, attempt: 1, cumulative: Int64.max), at: 1)
        tracker.apply(.finished(requestID: first.id, attempt: 1), at: 1)
        tracker.apply(.started(second), at: 2)
        tracker.apply(.bodyBytes(requestID: second.id, attempt: 1, cumulative: 500), at: 3)
        #expect(tracker.summary.requestBodyBytes == Int64.max)
        #expect(tracker.summary.uploadBodyBytes == Int64.max)
    }
    @Test func retryAfterAcceptsHttpDatesAndBoundedSeconds() {
        let now = Date(timeIntervalSince1970: 0)
        for header in ["10", "Thu, 01 Jan 1970 00:00:10 GMT", "Thursday, 01-Jan-70 00:00:10 GMT", "Thu Jan  1 00:00:10 1970"] {
            #expect(TransferRetryPolicy.delay(base: .seconds(1), failedAttempt: 1, header: header, now: now) == .seconds(10))
        }
        #expect(TransferRetryPolicy.delay(base: .seconds(1), failedAttempt: 1, header: "120", now: now) == .seconds(30))
        for invalid in ["-1", "NaN", "inf", "1.5", ""] {
            #expect(TransferRetryPolicy.delay(base: .seconds(1), failedAttempt: 2, header: invalid, now: now) == .seconds(2))
        }
    }
    @Test func retryCheckpointSurvivesRestartWithoutPersistingCountdownOrFileNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = TransferHistoryArchive(url: root.appendingPathComponent("history.json"))
        let job = UploadJob(source: "/private/source/dataset", repo: HubRepo(name: "owner/repo", kind: .dataset))
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        let info = request()
        try recorder.record(.phase(.uploading, file: "secret-file.bin"))
        try recorder.record(.transport(.started(info)))
        try recorder.record(.transport(.bodyBytes(requestID: info.id, attempt: 1, cumulative: 500)))
        try recorder.record(.transport(.finished(requestID: info.id, attempt: 1)))
        try recorder.record(.transport(.waiting(TransferRetry(request: info, reason: .rateLimit, resumesAt: Date().addingTimeInterval(30)))))
        let recovered = try TransferHistoryStore(archive: archive)
        let receipt = try #require(recovered.receipts.first)
        #expect(receipt.outcome == .interrupted)
        #expect(receipt.lastPhase == .retryWaiting)
        #expect(receipt.transport?.requestBodyBytes == 500)
        #expect(receipt.transport?.retryWaits == 1)
        #expect(receipt.transport?.retryAttempts == 0)
        let text = try String(contentsOf: archive.url, encoding: .utf8)
        for forbidden in ["secret-file.bin", "resumesAt", "requestID", "/private/source"] { #expect(!text.contains(forbidden)) }
    }
    @Test func terminalEventsClearLiveWaitAndOldArchivesKeepMetricsUnknown() throws {
        let job = UploadJob(source: "/source", repo: HubRepo(name: "owner/repo", kind: .model))
        var attempt = TransferAttempt(job: job)
        let retry = TransferRetry(request: request(), reason: .connection, resumesAt: Date())
        let event = TransferEvent(jobID: job.id, attemptID: attempt.receipt.id, sequence: 1, timestamp: Date(), payload: .transport(.waiting(retry)))
        let applied = attempt.apply(event); #expect(applied)
        let stopped = attempt.finish(.stopped); #expect(stopped)
        #expect(attempt.activity.retry == nil)
        #expect(attempt.activity.uploadBodyBytesPerSecond == nil)
        let encoded = try JSONEncoder().encode(attempt.receipt)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["transport", "lastPhase", "lastEventAt"] { object.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(TransferReceipt.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.transport == nil); #expect(restored.lastPhase == nil); #expect(restored.lastEventAt == nil)
    }
}
