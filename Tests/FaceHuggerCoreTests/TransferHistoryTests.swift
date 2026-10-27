import Foundation
import Testing
@testable import FaceHuggerCore

struct TransferHistoryTests: Sendable {
    private func fixture() throws -> (URL, TransferHistoryArchive, UploadJob) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let job = UploadJob(source: "/private/source/secret-parent/dataset", repo: HubRepo(name: "owner/repo", kind: .dataset),
                            destination: "training", sourceBookmark: Data("private-bookmark".utf8))
        return (base, TransferHistoryArchive(url: base.appendingPathComponent("history/receipts.json")), job)
    }
    private func commit(_ number: Int = 1) -> NativeCommitResult {
        NativeCommitResult(commitOID: String(format: "%040x", number), url: URL(string: "https://storage.example/file?signature=private")!)
    }

    @Test func orderedEventsRejectDuplicatesGapsWrongAttemptsAndEventsAfterFinish() throws {
        let (base, _, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var attempt = TransferAttempt(job: job)
        func event(_ sequence: UInt64, attemptID: UUID? = nil, jobID: UUID? = nil) -> TransferEvent {
            TransferEvent(jobID: jobID ?? job.id, attemptID: attemptID ?? attempt.receipt.id,
                          sequence: sequence, timestamp: Date(), payload: .committed(commit(), fileCount: 2))
        }
        let wrongAttempt = attempt.apply(event(1, attemptID: UUID())); #expect(!wrongAttempt)
        let wrongJob = attempt.apply(event(1, jobID: UUID())); #expect(!wrongJob)
        let gap = attempt.apply(event(2)); #expect(!gap)
        let accepted = attempt.apply(event(1)); #expect(accepted)
        let duplicate = attempt.apply(event(1)); #expect(!duplicate)
        #expect(attempt.receipt.confirmedCommitCount == 1)
        #expect(attempt.receipt.confirmedFileCount == 2)
        let stopped = attempt.finish(.stopped); #expect(stopped)
        let finishedAgain = attempt.finish(.completed); #expect(!finishedAgain)
        let late = attempt.apply(event(2)); #expect(!late)
        #expect(attempt.receipt.outcome == .stopped)
    }

    @Test func partialCommitEvidenceAndRawMeasurementsSurviveRestart() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try TransferHistoryStore(archive: archive)
        let recorder = try store.begin(job: job)
        var value = NativeUploadProgress()
        value.total = 4; value.checked = 2; value.transferredBytes = 9_876_543
        try recorder.record(.progress(value))
        try recorder.record(.committed(commit(), fileCount: 2))
        let recovered = try TransferHistoryStore(archive: archive)
        let receipt = try #require(recovered.receipts.first)
        #expect(receipt.outcome == .interrupted)
        #expect(receipt.startedAt != nil)
        #expect(receipt.finishedAt == nil)
        #expect(receipt.progress == value)
        #expect(receipt.confirmedCommitCount == 1)
        #expect(receipt.confirmedFileCount == 2)
        #expect(receipt.lastCommitURL?.host == "huggingface.co")
        #expect(receipt.lastCommitURL?.query == nil)
        #expect(receipt.text.contains("final outcome is unknown"))
        #expect(receipt.text.contains(receipt.lastCommitURL!.absoluteString))
    }

    @Test func legacyQueueMigrationPreservesUnknownsAndNeverReimportsClearedHistory() throws {
        let (base, archive, original) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var completed = original; completed.state = .completed; completed.finishedAt = Date()
        completed.fileCount = 10; completed.byteCount = 1234
        let queued = UploadJob(source: "/queue", repo: original.repo)
        let store = try TransferHistoryStore(archive: archive, legacyJobs: [completed, queued])
        let receipt = try #require(store.receipts.first)
        #expect(store.receipts.count == 1)
        #expect(receipt.isLegacy)
        #expect(receipt.progress == nil)
        #expect(receipt.startedAt == nil)
        #expect(receipt.finishedAt == completed.finishedAt)
        #expect(receipt.recentCommits.isEmpty)
        #expect(receipt.text.contains("Not recorded"))
        try store.clearTerminalReceipts()
        #expect(try TransferHistoryStore(archive: archive, legacyJobs: [completed]).receipts.isEmpty)
    }

    @Test func finalizationIsIdempotentAndResumingCreatesANewAttempt() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try TransferHistoryStore(archive: archive)
        let first = try store.begin(job: job)
        try first.record(.committed(commit(), fileCount: 1))
        try first.finish(.failed, error: URLError(.networkConnectionLost))
        try first.finish(.completed)
        try first.record(.committed(commit(2), fileCount: 1))
        let second = try store.begin(job: job)
        #expect(first.snapshot.receipt.id != second.snapshot.receipt.id)
        #expect(first.snapshot.receipt.jobID == second.snapshot.receipt.jobID)
        #expect(store.receipts.count == 2)
        #expect(first.snapshot.receipt.outcome == .failed)
        #expect(first.snapshot.receipt.confirmedCommitCount == 1)
        #expect(second.snapshot.receipt.progress == nil)
    }

    @Test func historyClearKeepsTheActiveAttemptAndItsLaterCommit() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try TransferHistoryStore(archive: archive)
        let first = try store.begin(job: job); try first.finish(.completed)
        let active = try store.begin(job: job)
        try store.clearTerminalReceipts()
        #expect(store.receipts.map(\.id) == [active.snapshot.receipt.id])
        try active.record(.committed(commit(), fileCount: 3))
        try active.finish(.completed)
        let restored = try TransferHistoryStore(archive: archive)
        #expect(restored.receipts.count == 1)
        #expect(restored.receipts.first?.confirmedFileCount == 3)
    }

    @Test func retentionBoundsReceiptsAndCommitReferencesWithoutLosingTotals() throws {
        let (base, archive, original) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let legacy = (0..<205).map { number in
            var job = UploadJob(source: "/folder-\(number)", repo: original.repo)
            job.state = .completed; job.createdAt = Date(timeIntervalSince1970: Double(number))
            return job
        }
        let store = try TransferHistoryStore(archive: archive, legacyJobs: legacy)
        #expect(store.receipts.count == 200)
        let active = try store.begin(job: original)
        #expect(store.receipts.count == 201)
        for number in 1...25 { try active.record(.committed(commit(number), fileCount: 2)) }
        try active.finish(.completed)
        #expect(store.receipts.count == 200)
        #expect(active.snapshot.receipt.recentCommits.count == 20)
        #expect(active.snapshot.receipt.confirmedCommitCount == 25)
        #expect(active.snapshot.receipt.confirmedFileCount == 50)
    }

    @Test func archiveAndCopiedReceiptExcludeCredentialsBookmarksAndAbsoluteSource() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        try recorder.record(.status("Response hf_topsecret https://storage.example/?signature=topsecret"))
        try recorder.record(.committed(commit(), fileCount: 1))
        try recorder.finish(.failed, error: NativeHubError.http(status: 403, message: "hf_topsecret https://storage.example/?signature=topsecret"))
        let data = try String(contentsOf: archive.url, encoding: .utf8)
        for forbidden in ["hf_topsecret", "signature", "private-bookmark", "secret-parent", "storage.example"] {
            #expect(!data.contains(forbidden))
            #expect(!recorder.snapshot.receipt.text.contains(forbidden))
        }
        #expect(recorder.snapshot.receipt.failure?.category == "http-403")
        #expect(!recorder.snapshot.log.joined().contains("hf_topsecret"))
        #expect(!recorder.snapshot.log.joined().contains("signature"))
    }

    @Test func anUnsupportedArchiveIsNotOverwritten() throws {
        let (base, archive, _) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: archive.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(#"{"version":99,"importedLegacyQueue":true,"receipts":[]}"#.utf8)
        try data.write(to: archive.url)
        #expect(throws: (any Error).self) { try TransferHistoryStore(archive: archive) }
        #expect(try Data(contentsOf: archive.url) == data)
    }

    @Test func failedAttemptCreationRollsBackAndFailedCommitPersistenceKeepsEvidenceInMemory() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let store = try TransferHistoryStore(archive: archive)
        let folder = archive.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        #expect(throws: (any Error).self) { try store.begin(job: job) }
        #expect(store.receipts.isEmpty)
        try FileManager.default.removeItem(at: folder)
        let recorder = try store.begin(job: job)
        try FileManager.default.removeItem(at: folder)
        try Data("blocked again".utf8).write(to: folder)
        #expect(throws: (any Error).self) { try recorder.record(.committed(commit(), fileCount: 1)) }
        #expect(recorder.persistenceFailed)
        #expect(recorder.snapshot.receipt.confirmedCommitCount == 1)
        #expect(store.receipts.first?.confirmedCommitCount == 1)
    }

    @Test func progressCallbacksDoNotGrowAnEventQueueAndLogsAreBounded() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        for number in 1...1_000 {
            var progress = NativeUploadProgress(); progress.checked = number
            try recorder.record(.progress(progress))
            try recorder.record(.status(String(repeating: "x", count: 2_000)))
        }
        #expect(recorder.snapshot.sequence == 2_000)
        #expect(recorder.snapshot.receipt.progress?.checked == 1_000)
        #expect(recorder.snapshot.log.count == 200)
        #expect(recorder.snapshot.log.allSatisfy { $0.count <= 512 })
    }
    @Test func concurrentProgressCallbacksHaveOneOrderedReduction() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        DispatchQueue.concurrentPerform(iterations: 200) { number in
            var progress = NativeUploadProgress(); progress.checked = number
            try? recorder.record(.progress(progress))
        }
        #expect(recorder.snapshot.sequence == 200)
        #expect(recorder.snapshot.receipt.progress != nil)
        #expect(!recorder.persistenceFailed)
        try recorder.finish(.stopped)
        #expect(try TransferHistoryStore(archive: archive).receipts.first?.outcome == .stopped)
    }
    @Test func aFailedFinalWriteCanBeRetriedWithoutChangingTheOutcome() throws {
        let (base, archive, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        let folder = archive.url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        try Data("blocked".utf8).write(to: folder)
        #expect(throws: (any Error).self) { try recorder.finish(.completed) }
        try FileManager.default.removeItem(at: folder)
        try recorder.finish(.failed)
        #expect(!recorder.persistenceFailed)
        #expect(try TransferHistoryStore(archive: archive).receipts.first?.outcome == .completed)
    }
}
