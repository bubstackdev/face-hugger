import Foundation

public enum TransferOutcome: String, Codable, Sendable {
    case running, completed, failed, stopped, interrupted
    public var label: String { rawValue.capitalized }
}

public struct TransferFailure: Codable, Equatable, Sendable {
    public let category: String
    public let message: String

    /// Persistent diagnostics use fixed messages, never arbitrary response bodies or URLs.
    public init(_ error: any Error) {
        switch error {
        case NativeHubError.http(let status, _):
            category = "http-\(status)"
            switch status {
            case 401, 403: message = "Authentication failed or permission was denied. Check the token’s repository write access."
            case 409: message = "The repository changed or the operation conflicts with existing content."
            case 429: message = "The service rate limit was reached. Retry later."
            default: message = "The service rejected the request."
            }
        case NativeHubError.network, is URLError:
            category = "network"; message = "The network request failed. Check the connection before resuming."
        case NativeUploadError.sourceChanged, NativeHubError.sourceChanged:
            category = "source-changed"; message = "Source files changed. Review the folder and start a new upload."
        case NativeUploadError.unconfirmedCommit:
            category = "unconfirmed-commit"; message = "A commit was not confirmed. Remote state must be checked before retrying."
        case NativeUploadError.reviewRequired:
            category = "review-required"; message = "The source, account, or repository needs a fresh upload review before resuming."
        default:
            category = "upload"; message = "The upload could not finish. Review the session log and source before resuming."
        }
    }
}

public struct TransferCommit: Codable, Equatable, Sendable {
    public let oid: String
    public let fileCount: Int
    public let acknowledgedAt: Date
}

public struct TransferReceipt: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let jobID: UUID
    public let planID: UUID?
    public let sourceLabel: String
    public let repo: HubRepo
    public let destination: String
    public let recordedAt: Date
    public let startedAt: Date?
    public fileprivate(set) var finishedAt: Date?
    public fileprivate(set) var outcome: TransferOutcome
    public let isLegacy: Bool
    public fileprivate(set) var progress: NativeUploadProgress?
    public fileprivate(set) var confirmedCommitCount = 0
    public fileprivate(set) var confirmedFileCount = 0
    public fileprivate(set) var recentCommits: [TransferCommit] = []
    public fileprivate(set) var verifiedRevision: String?
    public fileprivate(set) var failure: TransferFailure?
    public fileprivate(set) var lastPhase: TransferPhase?
    public fileprivate(set) var lastEventAt: Date?
    public fileprivate(set) var transport: TransferTransportSummary?

    fileprivate init(job: UploadJob, id: UUID, date: Date, legacy: Bool = false, outcome: TransferOutcome = .running) {
        self.id = id; jobID = job.id; planID = job.planID
        sourceLabel = TransferRedaction.clean(job.title)
        repo = job.repo; destination = job.destination
        recordedAt = date; startedAt = legacy ? nil : date
        finishedAt = legacy ? job.finishedAt : nil
        self.outcome = outcome; isLegacy = legacy
    }

    public var destinationURL: URL { repo.url }
    public var lastCommitURL: URL? {
        recentCommits.last.map { repo.url.appendingPathComponent("commit").appendingPathComponent($0.oid) }
    }
    public var verifiedRevisionURL: URL? {
        verifiedRevision.map { repo.url.appendingPathComponent("commit").appendingPathComponent($0) }
    }

    /// A shareable summary deliberately excludes absolute source paths and bookmarks.
    public var text: String {
        var lines = ["Face Hugger transfer receipt", "Outcome: \(outcome.label)",
                     "Folder: \(sourceLabel)", "Repository: \(TransferRedaction.clean(repo.name)) (\(repo.kind.rawValue))",
                     "Destination: /\(TransferRedaction.clean(destination))", "Attempt: \(id.uuidString)"]
        lines.append("Started: \(startedAt?.ISO8601Format() ?? "Not recorded")")
        lines.append("Finished: \(finishedAt?.ISO8601Format() ?? "Not recorded")")
        if let lastPhase { lines.append("Last phase: \(lastPhase.label)") }
        if let lastEventAt { lines.append("Last activity observed: \(lastEventAt.ISO8601Format())") }
        if let planID { lines.append("Reviewed plan: \(planID.uuidString)") }
        if let progress {
            lines.append("Files checked: \(progress.checked) / \(progress.total)")
            lines.append("Files uploaded or reused: \(progress.uploaded) / \(progress.uploadTotal)")
            if let count = progress.identicalFiles { lines.append("Files verified identical: \(count)") }
            if let count = progress.ignoredFiles { lines.append("Files skipped by repository rules: \(count)") }
            lines.append("Reported file-content bytes sent: \(progress.transferredBytes)")
            lines.append("Byte counts exclude protocol overhead and may exclude retransmissions.")
        } else { lines.append("Transfer measurements: Not recorded") }
        if let transport {
            lines.append("Observed request-body bytes: \(transport.requestBodyBytes)")
            lines.append("Of those, file/commit-body bytes: \(transport.uploadBodyBytes)")
            lines.append("Body counts include observed explicit retries and encoding, excluding headers and transport overhead.")
            lines.append("Request attempts: \(transport.requestAttempts); retry attempts: \(transport.retryAttempts)")
            lines.append("Retry waits: \(transport.retryWaits); cancelled waits: \(transport.cancelledRetryWaits)")
            for reason in transport.retryReasons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("\(reason.label): \(transport.retryReasons[reason] ?? 0) retry waits")
            }
        }
        if isLegacy {
            lines.append("Imported from the saved queue. Commit references and attempt measurements were not recorded.")
        } else {
            lines.append("Commits acknowledged this attempt: \(confirmedCommitCount)")
            lines.append("Files in those commits: \(confirmedFileCount)")
        }
        if !recentCommits.isEmpty {
            lines.append("Recent confirmed commits (up to 20):")
            lines += recentCommits.map { "\($0.oid) · \($0.fileCount) files" }
        }
        if let lastCommitURL { lines.append("Last confirmed commit: \(lastCommitURL.absoluteString)") }
        if let verifiedRevisionURL { lines.append("Verified repository revision: \(verifiedRevisionURL.absoluteString)") }
        if let failure { lines.append("Issue (\(failure.category)): \(failure.message)") }
        if outcome == .interrupted { lines.append("The final outcome is unknown. Confirmed commits above remain recorded.") }
        return lines.joined(separator: "\n")
    }
}

public struct TransferEvent: Sendable {
    public let jobID: UUID
    public let attemptID: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let payload: NativeUploadEvent
    public var monotonicSeconds: Double? = nil
}

/// One ordered reduction, used directly by the native recorder and by lifecycle tests.
public struct TransferAttempt: Sendable {
    public private(set) var receipt: TransferReceipt
    public private(set) var sequence: UInt64 = 0
    public private(set) var status = "Starting upload…"
    public private(set) var log: [String] = []
    private var workPhase: TransferPhase?
    private var currentFile: String?
    private var transportTracker = TransferTransportTracker()
    public var activity: TransferLiveActivity {
        TransferLiveActivity(phase: transportTracker.retry == nil ? workPhase : .retryWaiting,
            currentFile: currentFile, retry: transportTracker.retry, transport: receipt.transport,
            uploadBodyBytesPerSecond: transportTracker.rate)
    }
    mutating func refreshRate(at seconds: Double) { transportTracker.refresh(at: seconds) }

    public init(job: UploadJob, id: UUID = UUID(), date: Date = Date()) {
        receipt = TransferReceipt(job: job, id: id, date: date)
    }

    @discardableResult
    public mutating func apply(_ event: TransferEvent) -> Bool {
        guard receipt.outcome == .running, event.jobID == receipt.jobID, event.attemptID == receipt.id,
              event.sequence == sequence + 1 else { return false }
        sequence = event.sequence
        receipt.lastEventAt = event.timestamp
        switch event.payload {
        case .phase(let phase, let file):
            workPhase = phase; currentFile = file.map { TransferRedaction.clean($0) }
            receipt.lastPhase = phase
            status = phase.label + (currentFile.map { " · " + $0 } ?? "")
            appendLog(status)
            if phase != .uploading && phase != .committing { transportTracker.suspendRate() }
        case .transport(let transport):
            transportTracker.apply(transport, at: event.monotonicSeconds)
            receipt.transport = transportTracker.summary
            receipt.lastPhase = transportTracker.retry == nil ? workPhase : .retryWaiting
            if case .waiting(let retry) = transport {
                appendLog("\(retry.reason.label); waiting for request attempt \(retry.nextAttempt) of \(retry.request.maximumAttempts).")
            }
        case .status(let message):
            status = TransferRedaction.clean(message); appendLog(status)
        case .progress(let progress):
            receipt.progress = progress
        case .committed(let result, let count):
            // The native HTTP client validates OIDs; never persist an arbitrary provider URL.
            guard result.commitOID.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil,
                  count > 0 else { return true }
            receipt.confirmedCommitCount += 1; receipt.confirmedFileCount += count
            receipt.recentCommits.append(TransferCommit(oid: result.commitOID, fileCount: count, acknowledgedAt: event.timestamp))
            receipt.recentCommits = Array(receipt.recentCommits.suffix(20))
        case .completed:
            status = "Upload complete"; appendLog(status)
        case .verifiedRevision(let oid):
            if oid.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil {
                receipt.verifiedRevision = oid
            }
        }
        return true
    }

    @discardableResult
    public mutating func finish(_ outcome: TransferOutcome, error: (any Error)? = nil, date: Date = Date()) -> Bool {
        guard receipt.outcome == .running, outcome != .running else { return false }
        receipt.outcome = outcome; receipt.finishedAt = date
        transportTracker.finish()
        if let error { receipt.failure = TransferFailure(error); appendLog(TransferRedaction.clean(error.localizedDescription)) }
        return true
    }

    private mutating func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

enum TransferRedaction {
    static func clean(_ text: String, limit: Int = 512) -> String {
        let safe = text.replacingOccurrences(of: "hf_[A-Za-z0-9]+", with: "[redacted]", options: .regularExpression)
            .replacingOccurrences(of: "https?://[^\\s<>\"']+", with: "[URL redacted]", options: .regularExpression)
        return String(safe.prefix(limit))
    }
}

fileprivate struct TransferHistoryDocument: Codable {
    var version = 1
    var importedLegacyQueue = false
    var receipts: [TransferReceipt] = []
}

public struct TransferHistoryArchive: Sendable {
    public let url: URL
    public static let retainedTerminalReceipts = 200
    public init(url: URL) { self.url = url }

    fileprivate func read() throws -> TransferHistoryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return TransferHistoryDocument() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let result = try JSONDecoder().decode(TransferHistoryDocument.self, from: Data(contentsOf: url))
        guard result.version == 1, Set(result.receipts.map(\.id)).count == result.receipts.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
    fileprivate func write(_ document: TransferHistoryDocument) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// All archive mutation is serialized, including worker-thread commit acknowledgements.
public final class TransferHistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let archive: TransferHistoryArchive
    private var document: TransferHistoryDocument

    public init(archive: TransferHistoryArchive, legacyJobs: [UploadJob] = []) throws {
        self.archive = archive
        document = try archive.read()
        for index in document.receipts.indices where document.receipts[index].outcome == .running {
            document.receipts[index].outcome = .interrupted
            // The crash time is unknown; preserve the last confirmed evidence.
        }
        if !document.importedLegacyQueue {
            let knownJobs = Set(document.receipts.map(\.jobID))
            for job in legacyJobs where !knownJobs.contains(job.id) {
                guard let outcome = TransferOutcome(rawValue: job.state.rawValue), outcome != .running else { continue }
                document.receipts.append(TransferReceipt(job: job, id: job.id, date: job.createdAt, legacy: true, outcome: outcome))
            }
            document.importedLegacyQueue = true
        }
        prune()
        try archive.write(document)
    }

    public var receipts: [TransferReceipt] { lock.withLock { document.receipts } }

    public func begin(job: UploadJob, date: Date = Date()) throws -> TransferAttemptRecorder {
        try lock.withLock {
            guard !document.receipts.contains(where: { $0.outcome == .running }) else { throw CocoaError(.fileLocking) }
            let attempt = TransferAttempt(job: job, date: date)
            let previous = document
            document.receipts.insert(attempt.receipt, at: 0)
            do { try archive.write(document) }
            catch { document = previous; throw error }
            return TransferAttemptRecorder(attempt: attempt, store: self)
        }
    }

    fileprivate func checkpoint(_ receipt: TransferReceipt) throws {
        try lock.withLock {
            guard let index = document.receipts.firstIndex(where: { $0.id == receipt.id }) else { return }
            document.receipts[index] = receipt
            prune()
            try archive.write(document)
        }
    }

    public func clearTerminalReceipts() throws {
        try lock.withLock {
            let previous = document
            document.receipts.removeAll { $0.outcome != .running }
            do { try archive.write(document) }
            catch { document = previous; throw error }
        }
    }

    private func prune() {
        document.receipts.sort { $0.recordedAt == $1.recordedAt ? $0.id.uuidString < $1.id.uuidString : $0.recordedAt > $1.recordedAt }
        var terminalCount = 0
        document.receipts = document.receipts.filter { receipt in
            guard receipt.outcome != .running else { return true }
            terminalCount += 1
            return terminalCount <= TransferHistoryArchive.retainedTerminalReceipts
        }
    }
}

/// Synchronous reduction avoids one UI task per progress callback. The UI samples snapshots;
/// confirmed commits are persisted before the callback returns and before more upload work.
public final class TransferAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let store: TransferHistoryStore
    private var attempt: TransferAttempt
    private var failedPersistence = false
    private let started = ContinuousClock.now
    fileprivate init(attempt: TransferAttempt, store: TransferHistoryStore) { self.attempt = attempt; self.store = store }
    public var snapshot: TransferAttempt {
        lock.withLock {
            var copy = attempt
            copy.refreshRate(at: TransferRetryPolicy.seconds(started.duration(to: .now)))
            return copy
        }
    }
    public var persistenceFailed: Bool { lock.withLock { failedPersistence } }

    public func record(_ payload: NativeUploadEvent, date: Date = Date()) throws {
        try lock.withLock {
            var event = TransferEvent(jobID: attempt.receipt.jobID, attemptID: attempt.receipt.id,
                                      sequence: attempt.sequence + 1, timestamp: date, payload: payload)
            event.monotonicSeconds = TransferRetryPolicy.seconds(started.duration(to: .now))
            guard attempt.apply(event) else { return }
            let checkpoint: Bool
            switch payload {
            case .committed, .transport(.waiting), .transport(.waitCancelled): checkpoint = true
            case .transport(.started(let request)): checkpoint = request.attempt > 1
            default: checkpoint = false
            }
            if checkpoint {
                do { try store.checkpoint(attempt.receipt) }
                catch { failedPersistence = true; throw error }
            }
        }
    }

    public func finish(_ outcome: TransferOutcome, error: (any Error)? = nil, date: Date = Date()) throws {
        try lock.withLock {
            let finalized = attempt.finish(outcome, error: error, date: date)
            guard finalized || failedPersistence else { return }
            do { try store.checkpoint(attempt.receipt); failedPersistence = false }
            catch { failedPersistence = true; throw error }
        }
    }
}
