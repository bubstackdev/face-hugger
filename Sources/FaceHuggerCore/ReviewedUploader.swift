import Foundation
import CryptoKit

/// Executes only a persisted, explicitly approved action set. Recovery advances the expected
/// parent only after an acknowledged commit and atomically records its completed paths.
public enum ReviewedUploader {
    public static func upload(job: UploadJob, plansDirectory: URL, token: String?,
                              onEvent: @escaping @Sendable (NativeUploadEvent) -> Void) async throws {
        let transport = NativeHubClient(token: token, onTransferEvent: { onEvent(.transport($0)) })
        try await upload(job: job, plansDirectory: plansDirectory, transport: transport, onEvent: onEvent)
    }
    public static func upload(job: UploadJob, plansDirectory: URL, transport: any NativeReviewedTransport,
                              maximumFilesPerCommit: Int = 100,
                              onEvent: @escaping @Sendable (NativeUploadEvent) -> Void) async throws {
        guard let id = job.planID else { throw NativeUploadError.reviewRequired("Review this upload before starting it.") }
        let store = try UploadPlanStore.open(at: UploadPlanStore.url(directory: plansDirectory, jobID: job.id, planID: id))
        defer { store.close() }
        let plan = try store.plan()
        guard plan.matches(job), plan.canApprove, plan.approvedAt != nil,
              (plan.summary.counts[.needsComparison] ?? 0) == 0 || plan.approvedUnknownComparisons,
              var expected = plan.expectedHead else { throw NativeUploadError.reviewRequired("The saved review does not approve this upload. Review it again.") }
        onEvent(.phase(.validating, file: nil))
        let account = try await transport.whoami(), repo = try await transport.info(repo: job.repo)
        guard Data(account.name.utf8) == Data(plan.account.utf8), repo == plan.repo,
              try await transport.headCommit(repo: repo) == expected else {
            throw NativeUploadError.reviewRequired("The account, repository visibility, or remote revision changed. Review this upload again.")
        }
        onEvent(.phase(.scanning, file: nil))
        try UploadPlanBuilder.validateSource(job: job, store: store, fingerprint: plan.sourceFingerprint)
        let root = URL(fileURLWithPath: job.source).standardizedFileURL.resolvingSymlinksInPath()
        var progress = NativeUploadProgress()
        progress.total = plan.summary.includedCount; progress.uploadTotal = progress.total
        progress.identicalFiles = 0; progress.ignoredFiles = 0
        onEvent(.progress(progress))
        var pending: [(UploadSourceEntry, NativeCommitFile)] = []
        var inlineBytes = 0
        let limit = min(100, max(1, maximumFilesPerCommit))
        func flush() async throws {
            guard !pending.isEmpty else { return }
            try Task.checkCancellation()
            for (entry, _) in pending { _ = try UploadSource.verify(entry, root: root) }
            onEvent(.phase(.committing, file: nil))
            let result = try await transport.commit(repo: repo, additions: pending.map { $0.1 }, deletions: [],
                message: "Upload reviewed files with Face Hugger", expectedParent: expected)
            guard result.commitOID.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil else {
                throw NativeUploadError.unconfirmedCommit
            }
            onEvent(.committed(result, fileCount: pending.count))
            try store.recordCommit(result, paths: pending.map { $0.0.path })
            expected = result.commitOID
            progress.committed += pending.count; progress.commits += 1
            progress.uploaded += pending.filter { $0.1.content != nil }.count
            progress.transferredBytes += Int64(inlineBytes)
            pending.removeAll(keepingCapacity: true); inlineBytes = 0
            onEvent(.progress(progress))
        }
        var after: String?
        while true {
            let page = try store.executionPage(after: after)
            guard !page.isEmpty else { break }
            for row in page {
                try Task.checkCancellation()
                guard let entry = row.entry, let hash = row.sha256, row.action != .conflict else {
                    throw NativeUploadError.reviewRequired("The saved file plan is incomplete or has a conflict. Review it again.")
                }
                onEvent(.phase(.hashing, file: row.path))
                let digest = try UploadSource.hash(entry, root: root, destination: job.destination, includeGit: false)
                guard digest.descriptor.sha256 == hash else { throw NativeUploadError.sourceChanged(row.path) }
                progress.checked += 1
                if row.action == .identical || row.state == "committed" {
                    progress.uploaded += 1; progress.committed += 1
                    if row.action == .identical { progress.identicalFiles = (progress.identicalFiles ?? 0) + 1 }
                    onEvent(.progress(progress)); continue
                }
                if row.state == "ignored" {
                    progress.ignoredFiles = (progress.ignoredFiles ?? 0) + 1
                    progress.uploadTotal -= 1; onEvent(.progress(progress)); continue
                }
                let descriptor = digest.descriptor
                if inlineBytes > 0 && descriptor.size > Int64(16 * 1024 * 1024 - inlineBytes) { try await flush() }
                onEvent(.phase(.negotiating, file: row.path))
                let modes = try await transport.preupload(repo: repo, files: [descriptor])
                guard let mode = modes[Data(descriptor.path.utf8)] else { throw NativeUploadError.invalid("The server omitted an upload decision.") }
                let addition: NativeCommitFile
                switch mode {
                case .ignored:
                    try store.recordIgnored(path: row.path)
                    progress.ignoredFiles = (progress.ignoredFiles ?? 0) + 1
                    progress.uploadTotal -= 1
                    onEvent(.status("Skipped \(row.path) (repository ignore rules)")); onEvent(.progress(progress)); continue
                case .regular:
                    guard descriptor.size <= 16 * 1024 * 1024 else { throw NativeUploadError.invalid("A file larger than 16 MiB was designated for inline upload. Configure LFS before retrying.") }
                    if inlineBytes + Int(descriptor.size) > 16 * 1024 * 1024 { try await flush() }
                    let file = try UploadSource.verify(entry, root: root)
                    let handle = try FileHandle(forReadingFrom: file)
                    let data: Data
                    do { data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data(); try handle.close() }
                    catch { try? handle.close(); throw error }
                    guard data.count == descriptor.size, UploadSource.hex(SHA256.hash(data: data)) == hash else { throw NativeUploadError.sourceChanged(row.path) }
                    _ = try UploadSource.verify(entry, root: root)
                    addition = NativeCommitFile(descriptor: descriptor, content: data); inlineBytes += data.count
                case .lfs:
                    onEvent(.phase(.uploading, file: row.path))
                    let counter = ReviewedByteCounter(), baseline = progress
                    try await transport.uploadLFS(repo: repo, file: try UploadSource.verify(entry, root: root), descriptor: descriptor) { value in
                        var latest = baseline
                        latest.transferredBytes += counter.update(max(0, min(descriptor.size, value)))
                        onEvent(.progress(latest))
                    }
                    progress.transferredBytes += counter.value
                    progress.uploaded += 1
                    addition = NativeCommitFile(descriptor: descriptor)
                }
                _ = try UploadSource.verify(entry, root: root)
                pending.append((entry, addition))
                onEvent(.progress(progress))
                if pending.count >= limit { try await flush() }
            }
            after = page.last?.path
        }
        try await flush()
        onEvent(.phase(.verifying, file: nil))
        try UploadPlanBuilder.validateSource(job: job, store: store, fingerprint: plan.sourceFingerprint)
        guard try await transport.headCommit(repo: repo) == expected else { throw NativeUploadError.reviewRequired("The repository changed before verification completed. Review the remote state again.") }
        try Task.checkCancellation()
        onEvent(.verifiedRevision(expected))
        onEvent(.progress(progress)); onEvent(.completed(repo.url))
    }
}

private final class ReviewedByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    var value: Int64 { lock.withLock { bytes } }
    func update(_ count: Int64) -> Int64 { lock.withLock { bytes = max(bytes, count); return bytes } }
}
