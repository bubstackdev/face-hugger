import Foundation
import Testing
@testable import FaceHuggerCore

private actor UploadMock: NativeUploadTransport {
    var head: String? = "initial"
    var commits = 0, attempts = 0, uploads = 0
    var failAttempt: Int?
    var ambiguous = false
    var privateRepo = false
    var entries: [NativeHubEntry] = []
    var mode: NativeUploadMode = .lfs
    var mutation: URL?
    var reportBytes = true, cancelUpload = false
    var batchSizes: [Int] = []
    func behavior(mode: NativeUploadMode = .lfs, reportBytes: Bool = true, cancel: Bool = false) { self.mode = mode; self.reportBytes = reportBytes; cancelUpload = cancel }
    func batches() -> [Int] { batchSizes }
    func configure(fail: Int? = nil, ambiguous: Bool = false, head: String? = nil, entries: [NativeHubEntry] = [], privateRepo: Bool = false, mutation: URL? = nil) {
        failAttempt = fail; self.ambiguous = ambiguous; if let head { self.head = head }; self.entries = entries; self.privateRepo = privateRepo; self.mutation = mutation
    }
    func counts() -> (Int, Int, Int) { (commits, attempts, uploads) }
    func info(repo: HubRepo) async throws -> HubRepo { HubRepo(name: repo.name, kind: repo.kind, isPrivate: privateRepo) }
    func headCommit(repo: HubRepo) async throws -> String? { head }
    func streamTree(repo: HubRepo, path: String, recursive: Bool, onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws { for entry in entries { try await onEntry(entry) } }
    func preupload(repo: HubRepo, files: [NativeUploadDescriptor]) async throws -> [Data: NativeUploadMode] { Dictionary(uniqueKeysWithValues: files.map { (Data($0.path.utf8), mode) }) }
    func uploadLFS(repo: HubRepo, file: URL, descriptor: NativeUploadDescriptor, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        uploads += 1
        if let mutation { try Data("changed".utf8).write(to: mutation) }
        if reportBytes { onBytes(descriptor.size) }
        if cancelUpload { throw CancellationError() }
    }
    func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String) async throws -> NativeCommitResult {
        attempts += 1; batchSizes.append(additions.count)
        if attempts == failAttempt { throw URLError(.networkConnectionLost) }
        commits += 1; head = String(format: "%040x", commits)
        return NativeCommitResult(commitOID: ambiguous ? "" : head!, url: repo.url)
    }
}
private final class UploadEvents: @unchecked Sendable {
    private let lock = NSLock(); private var completed = 0
    private var bytes: Int64 = 0
    func receive(_ event: NativeUploadEvent) { lock.withLock { if case .completed = event { completed += 1 }; if case .progress(let value) = event { bytes = value.transferredBytes } } }
    var transferred: Int64 { lock.withLock { bytes } }
    var count: Int { lock.withLock { completed } }
}
struct NativeUploaderTests {
    private func fixture() throws -> (URL, URL, UploadJob) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["first.txt", "second.txt"] { try Data(name.utf8).write(to: source.appendingPathComponent(name)) }
        return (base, base.appendingPathComponent("checkpoints"), UploadJob(source: source.path, repo: HubRepo(name: "test/repo", kind: .model)))
    }
    @Test func resumeSkipsOnlyConfirmedFilesAtSameRemoteHead() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock(), events = UploadEvents()
        await mock.configure(fail: 2)
        await #expect(throws: URLError.self) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: events.receive) }
        #expect(events.count == 0)
        await mock.configure()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: events.receive)
        let counts = await mock.counts()
        #expect(counts.0 == 2); #expect(counts.1 == 3); #expect(counts.2 == 3); #expect(events.count == 1)
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: events.receive)
        #expect(await mock.counts().1 == 3)
    }
    @Test func acknowledgedCommitsReachHistoryBeforeALaterBatchFails() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let archive = TransferHistoryArchive(url: base.appendingPathComponent("history.json"))
        let recorder = try TransferHistoryStore(archive: archive).begin(job: job)
        let mock = UploadMock()
        await mock.configure(fail: 2)
        await #expect(throws: URLError.self) {
            try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints,
                                            maximumFilesPerCommit: 1) { event in try? recorder.record(event) }
        }
        #expect(!recorder.persistenceFailed)
        // Simulate process loss without finalization; acknowledgement was already persisted.
        let recovered = try TransferHistoryStore(archive: archive)
        #expect(recovered.receipts.first?.outcome == .interrupted)
        #expect(recovered.receipts.first?.confirmedCommitCount == 1)
        #expect(recovered.receipts.first?.confirmedFileCount == 1)
    }
    @Test func foreignRemoteHeadInvalidatesAllOldReceiptsEvenAfterInterruptedReplay() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in })
        await mock.configure(fail: 4, head: "foreign")
        await #expect(throws: URLError.self) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        await mock.configure()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in })
        #expect(await mock.counts().1 == 5)
    }
    @Test func ambiguousCommitNeverReportsCompletionAndIsReplayed() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock(), events = UploadEvents()
        await mock.configure(ambiguous: true)
        await #expect(throws: NativeUploadError.self) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: events.receive) }
        #expect(events.count == 0)
        await mock.configure()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: events.receive)
        #expect(await mock.counts().1 == 3); #expect(events.count == 1)
    }
    @Test func changedSourceCannotReuseCheckpoint() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock()
        await mock.configure(fail: 1)
        await #expect(throws: URLError.self) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        try Data("new contents".utf8).write(to: URL(fileURLWithPath: job.source).appendingPathComponent("first.txt"))
        await mock.configure()
        await #expect(throws: NativeUploadError.sourceChanged("folder contents")) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        #expect(await mock.counts().1 == 1)
    }
    @Test func allRemoteConflictsAndPrivacyAreCheckedBeforeAnyUpload() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock()
        await mock.configure(entries: [NativeHubEntry(path: "second.txt", size: 0, isDirectory: true)])
        await #expect(throws: NativeUploadError.invalid("Remote path 'second.txt' is a folder, but the staged path is a file.")) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        #expect(await mock.counts().2 == 0)
        await mock.configure(privateRepo: true)
        await #expect(throws: NativeUploadError.invalid("Repository visibility changed. Review the destination and start a new upload.")) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        #expect(await mock.counts().2 == 0)
    }
    @Test func sourceMutationDuringUploadIsNeverCommitted() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock()
        // The changed file must never commit, regardless of enumeration order.
        await mock.configure(mutation: URL(fileURLWithPath: job.source).appendingPathComponent("first.txt"))
        await #expect(throws: NativeUploadError.sourceChanged("first.txt")) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, maximumFilesPerCommit: 1, onEvent: { _ in }) }
        #expect(await mock.counts().0 <= 1)
    }
    @Test func boundedBatchesAndReusedObjectsReportZeroNetworkBytes() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<100 { try Data([1]).write(to: URL(fileURLWithPath: job.source).appendingPathComponent("file-\(index)")) }
        let mock = UploadMock(), events = UploadEvents()
        await mock.behavior(reportBytes: false)
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, onEvent: events.receive)
        #expect(await mock.batches() == [100, 2])
        #expect(events.transferred == 0); #expect(events.count == 1)
    }
    @Test func cancellationNeverCommitsIncompleteBatchAndResumeRechecks() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock(), events = UploadEvents()
        await mock.behavior(cancel: true)
        await #expect(throws: CancellationError.self) { try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, onEvent: events.receive) }
        #expect(await mock.counts().0 == 0); #expect(events.count == 0)
        await mock.behavior()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, onEvent: events.receive)
        #expect(await mock.batches() == [2]); #expect(events.count == 1)
        #expect(events.transferred == Int64("first.txt".utf8.count + "second.txt".utf8.count))
    }
    @Test func checkpointsContainOnlyMetadataAndTransientFilesAreCleaned() async throws {
        let (base, checkpoints, job) = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let mock = UploadMock()
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, onEvent: { _ in })
        let directory = try #require(FileManager.default.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: nil).first)
        let stale = directory.appendingPathComponent("scan-\(UUID().uuidString).ndjson")
        try Data("old manifest".utf8).write(to: stale)
        try await NativeUploader.upload(job: job, transport: mock, checkpointDirectory: checkpoints, onEvent: { _ in })
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        for file in files {
            #expect(file.pathExtension == "json")
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(Set(object.keys).isSubset(of: ["version", "fingerprint", "head", "epoch", "path", "sha256"]))
        }
    }

}
