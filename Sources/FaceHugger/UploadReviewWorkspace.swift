import Foundation
import Observation

private final class ReviewFeedback: @unchecked Sendable {
    private let lock = NSLock()
    private var text = "Preparing review…"
    private var phase: TransferPhase?
    private var retry: TransferRetry?
    func update(_ value: String) { lock.withLock { text = value } }
    func updatePhase(_ value: TransferPhase) { lock.withLock { phase = value } }
    func transport(_ event: NativeTransferEvent) {
        lock.withLock {
            switch event {
            case .waiting(let value): retry = value
            case .started, .waitCancelled: retry = nil
            default: break
            }
        }
    }
    var latest: (String, TransferPhase?, TransferRetry?) { lock.withLock { (text, phase, retry) } }
}

@MainActor @Observable
final class UploadReviewWorkspace: Identifiable {
    let id: UUID
    let startWhenApproved: Bool
    let replacesJob: Bool
    private(set) var job: UploadJob
    private let directory: URL
    private let operation = NativeOperation()
    private let feedback = ReviewFeedback()
    private var store: UploadPlanStore?
    private var closed = false
    var building = true
    var status = "Preparing review…"
    var phase: TransferPhase?
    var retry: TransferRetry?
    var error: String?
    var plan: UploadPlan?
    var rows: [UploadPlanRow] = []
    var offset = 0
    var filter: PlannedFileAction?
    var allowUnknownComparisons = false

    init(job: UploadJob, directory: URL, start: Bool, replacesJob: Bool) {
        let id = UUID()
        self.id = id; var proposed = job; proposed.planID = id; self.job = proposed
        self.directory = directory; startWhenApproved = start; self.replacesJob = replacesJob
    }
    var filteredCount: Int { filter.map { plan?.summary.counts[$0] ?? 0 } ?? plan?.summary.totalCount ?? 0 }
    var canApprove: Bool {
        !building && error == nil && plan?.canApprove == true && ((plan?.summary.counts[.needsComparison] ?? 0) == 0 || allowUnknownComparisons)
    }
    func prepare(token: String?) async {
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                let value = feedback.latest
                status = value.0; phase = value.1; retry = value.2
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        defer { observer.cancel(); building = false; retry = nil }
        do {
            let access = try FolderAccess.restore(path: job.source, bookmark: job.sourceBookmark)
            defer { access.close() }
            job.source = access.url.path; job.sourceBookmark = access.bookmark
            let job = job, directory = directory, feedback = feedback
            let result = try await operation.run {
                try await UploadPlanBuilder.build(job: job, directory: directory,
                    transport: NativeHubClient(token: token, onTransferEvent: feedback.transport),
                    onPhase: feedback.updatePhase, onStatus: feedback.update)
            }
            guard !closed else { try? result.discard(); return }
            store = result; plan = try result.plan()
            if let plan { self.job.repo = plan.repo }
            loadPage()
        } catch is CancellationError { }
        catch { if !closed { self.error = error.localizedDescription } }
    }
    func loadPage() {
        do { rows = try store?.rows(offset: offset, action: filter) ?? [] }
        catch { self.error = error.localizedDescription; rows = [] }
    }
    func approve() throws -> UploadJob {
        guard !closed, canApprove, let store, let plan else { throw NativeUploadError.reviewRequired("Complete and approve the upload review first.") }
        try store.approve(allowUnknownComparisons: allowUnknownComparisons)
        var approved = job
        approved.fileCount = plan.summary.includedCount; approved.byteCount = plan.summary.includedBytes
        approved.state = .queued; approved.finishedAt = nil; approved.message = "Reviewed and ready to upload"
        return approved
    }
    func keepPlan() { closed = true; store?.close(); store = nil }
    func cancel() {
        closed = true; operation.stop()
        if let store { try? store.discard() }; store = nil
    }
}
