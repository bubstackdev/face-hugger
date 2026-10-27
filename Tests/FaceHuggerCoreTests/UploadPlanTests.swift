import Foundation
import CryptoKit
import Testing
@testable import FaceHuggerCore

private actor ReviewMock: NativeReviewedTransport {
    var head: String? = String(repeating: "a", count: 40)
    var account = "owner", privateRepo = false
    var entries: [NativeHubEntry] = []
    var negotiations = 0, uploads: [String] = [], guarded = 0, unguarded = 0, committed = 0
    var inlineBodies: [Data] = []
    var failCommit: Int?, changeDuringUpload = false, ambiguous = false, brokenTree = false, moveDuringTree = false
    var mutation: URL?
    var mode: NativeUploadMode = .lfs
    func configure(entries: [NativeHubEntry] = [], failCommit: Int? = nil, mode: NativeUploadMode = .lfs,
                   ambiguous: Bool = false, brokenTree: Bool = false, moveDuringTree: Bool = false,
                   changeDuringUpload: Bool = false, mutation: URL? = nil) {
        self.entries = entries; self.failCommit = failCommit; self.mode = mode; self.ambiguous = ambiguous
        self.brokenTree = brokenTree; self.moveDuringTree = moveDuringTree
        self.changeDuringUpload = changeDuringUpload; self.mutation = mutation
    }
    func setHead(_ value: String?) { head = value }
    func setAccount(_ value: String) { account = value }
    func setPrivate(_ value: Bool) { privateRepo = value }
    func state() -> (Int, [String], Int, Int, String?) { (negotiations, uploads, guarded, unguarded, head) }
    func bodies() -> [Data] { inlineBodies }
    func whoami() async throws -> NativeHubIdentity { NativeHubIdentity(name: account, organizations: []) }
    func info(repo: HubRepo) async throws -> HubRepo { HubRepo(name: repo.name, kind: repo.kind, isPrivate: privateRepo) }
    func headCommit(repo: HubRepo) async throws -> String? { head }
    func streamTree(repo: HubRepo, path: String, recursive: Bool, onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws {
        throw NativeHubError.invalidInput("Review must request a pinned revision")
    }
    func streamTree(repo: HubRepo, path: String, recursive: Bool, revision: String,
                    onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws {
        guard revision == head else { throw NativeHubError.invalidInput("Wrong pinned revision") }
        for entry in entries { try await onEntry(entry) }
        if brokenTree { throw URLError(.networkConnectionLost) }
        if moveDuringTree { head = String(repeating: "f", count: 40) }
    }
    func preupload(repo: HubRepo, files: [NativeUploadDescriptor]) async throws -> [Data: NativeUploadMode] {
        negotiations += 1
        return Dictionary(uniqueKeysWithValues: files.map { (Data($0.path.utf8), mode == .ignored ? .ignored : $0.size == 0 ? .regular : mode) })
    }
    func uploadLFS(repo: HubRepo, file: URL, descriptor: NativeUploadDescriptor, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        uploads.append(descriptor.path)
        if let mutation { try Data("changed".utf8).write(to: mutation, options: .atomic) }
        onBytes(descriptor.size)
        if changeDuringUpload { head = String(repeating: "f", count: 40) }
    }
    func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String) async throws -> NativeCommitResult {
        unguarded += 1; throw NativeHubError.invalidInput("An unguarded commit is forbidden")
    }
    func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String, expectedParent: String) async throws -> NativeCommitResult {
        guarded += 1
        guard expectedParent == head else { throw NativeHubError.http(status: 409, message: "Moved") }
        if guarded == failCommit { throw URLError(.networkConnectionLost) }
        inlineBodies += additions.compactMap(\.content)
        committed += 1; head = String(format: "%040x", committed)
        return NativeCommitResult(commitOID: ambiguous ? "" : head!, url: repo.url)
    }
}
private final class PlanEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = NativeUploadProgress(), completions = 0
    func record(_ event: NativeUploadEvent) {
        lock.withLock {
            if case .progress(let progress) = event { latest = progress }
            if case .completed = event { completions += 1 }
        }
    }
    var progress: NativeUploadProgress { lock.withLock { latest } }
    var completed: Int { lock.withLock { completions } }
}

struct UploadPlanTests {
    private func fixture(_ files: [String: Data] = ["a.txt": Data("hello\n".utf8), "b.bin": Data("world\n".utf8)]) throws -> (URL, URL, UploadJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        var job = UploadJob(source: source.path, repo: HubRepo(name: "owner/repo", kind: .dataset))
        job.planID = UUID()
        return (root, root.appendingPathComponent("plans"), job)
    }
    @Test func gitAndLFSContentIdentityProduceAnAllIdenticalPlanWithoutAnyMutation() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        let lfs = SHA256.hash(data: Data("world\n".utf8)).map { String(format: "%02x", $0) }.joined()
        await mock.configure(entries: [
            NativeHubEntry(path: "a.txt", size: 6, isDirectory: false, gitBlobOID: "ce013625030ba8dba906f756967f9e9ca394464a"),
            NativeHubEntry(path: "b.bin", size: 6, isDirectory: false, gitBlobOID: String(repeating: "b", count: 40), lfsSHA256: lfs)])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.identical] == 2)
        #expect(try store.plan().summary.candidateBytes == 0)
        #expect(await mock.state().0 == 0)
        try store.approve(allowUnknownComparisons: false)
        let events = PlanEvents()
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, onEvent: events.record)
        let state = await mock.state()
        #expect(state.0 == 0); #expect(state.1.isEmpty); #expect(state.2 == 0); #expect(state.3 == 0)
        #expect(events.completed == 1)
        #expect(events.progress.identicalFiles == 2)
        #expect(events.progress.commits == 0)
        let history = try TransferHistoryStore(archive: TransferHistoryArchive(url: root.appendingPathComponent("history.json")))
        let recorder = try history.begin(job: job)
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { event in try? recorder.record(event) }
        #expect(!recorder.persistenceFailed)
        try recorder.finish(.completed)
        let receipt = try #require(history.receipts.first)
        #expect(receipt.verifiedRevision == String(repeating: "a", count: 40))
        #expect(receipt.confirmedCommitCount == 0)
        #expect(receipt.verifiedRevisionURL?.query == nil)
        #expect(receipt.text.contains("Verified repository revision:"))
    }
    @Test func missingOrOpaqueMetadataStaysUnknownAndRequiresExplicitApproval() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        await mock.configure(entries: [NativeHubEntry(path: "a.txt", size: 6, isDirectory: false),
            NativeHubEntry(path: "b.bin", size: 6, isDirectory: false, gitBlobOID: String(repeating: "b", count: 40), xetHash: "opaque")])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.needsComparison] == 2)
        #expect(throws: NativeUploadError.self) { try store.approve(allowUnknownComparisons: false) }
        await #expect(throws: NativeUploadError.self) {
            try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in }
        }
        #expect(await mock.state().0 == 0)
        try store.approve(allowUnknownComparisons: true)
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in }
        #expect(await mock.state().1.count == 2)
        #expect(await mock.state().3 == 0)
    }
    @Test func differentIdentityIsReplacementAndFiltersRemainExcluded() async throws {
        let (root, directory, original) = try fixture(["a.txt": Data("hello\n".utf8), "ignore.txt": Data("private".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        var job = original; job.excludes = ["ignore.txt"]
        let mock = ReviewMock()
        await mock.configure(entries: [NativeHubEntry(path: "a.txt", size: 6, isDirectory: false, gitBlobOID: String(repeating: "b", count: 40))])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.replace] == 1)
        #expect(try store.plan().summary.counts[.excluded] == 1)
        #expect(try store.rows(action: .excluded).first?.entry == nil)
        #expect(try store.rows(action: .excluded).first?.sha256 == nil)
        try store.approve(allowUnknownComparisons: false)
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in }
        #expect(await mock.state().1 == ["a.txt"])
    }
    @Test func aBlockingRemoteFileMarksEveryDescendantConflict() async throws {
        let (root, directory, job) = try fixture(["blocked/a": Data([1]), "blocked/b": Data([2])])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        await mock.configure(entries: [NativeHubEntry(path: "blocked", size: 1, isDirectory: false)])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.conflict] == 2)
        #expect(throws: NativeUploadError.self) { try store.approve(allowUnknownComparisons: true) }
        #expect(await mock.state().0 == 0)
    }
    @Test func plansCoverMoreThanThePreviewLimitWithBoundedPages() async throws {
        var files: [String: Data] = [:]
        for index in 0..<2_105 { files[String(format: "file-%04d.txt", index)] = Data([1]) }
        let (root, directory, job) = try fixture(files); defer { try? FileManager.default.removeItem(at: root) }
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: ReviewMock())
        #expect(try store.plan().summary.includedCount == 2_105)
        #expect(try store.rows(offset: 2_000).count == 100)
        #expect(try store.rows(limit: 100_000).count == 200)
        #expect(try store.rows(offset: 2_104).contains { $0.path == "file-2104.txt" })
    }
    @Test func byteDistinctRemoteNamesDoNotMatchByUnicodeNormalization() async throws {
        let (root, directory, job) = try fixture(["é.txt": Data("hello\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(NativeScanner.scan(source: URL(fileURLWithPath: job.source)).files.first?.path)
        let composed = path.precomposedStringWithCanonicalMapping, decomposed = path.decomposedStringWithCanonicalMapping
        let other = Data(path.utf8) == Data(composed.utf8) ? decomposed : composed
        #expect(Data(path.utf8) != Data(other.utf8))
        let mock = ReviewMock()
        await mock.configure(entries: [NativeHubEntry(path: other, size: 6, isDirectory: false,
                                                     gitBlobOID: "ce013625030ba8dba906f756967f9e9ca394464a")])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.add] == 1)
        #expect(try store.plan().summary.counts[.identical] == nil)
    }
    @Test func incompleteOrMovedRemoteComparisonNeverLeavesAnExecutablePlan() async throws {
        for broken in [true, false] {
            let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let mock = ReviewMock(); await mock.configure(brokenTree: broken, moveDuringTree: !broken)
            await #expect(throws: (any Error).self) { try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
    @Test func noConfirmedRevisionIsExplainedAndCannotBeApproved() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock(); await mock.setHead(nil)
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().blockedReason != nil)
        #expect(try store.plan().complete == false)
        #expect(try store.plan().summary.counts[.add] == nil)
        #expect(throws: NativeUploadError.self) { try store.approve(allowUnknownComparisons: true) }
        #expect(await mock.state().0 == 0)
    }
    @Test func changedSourceAccountVisibilityAndRevisionRefuseBeforeUpload() async throws {
        for change in 0..<4 {
            let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let mock = ReviewMock()
            let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
            try store.approve(allowUnknownComparisons: false)
            switch change {
            case 0: try Data("different".utf8).write(to: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"), options: .atomic)
            case 1: await mock.setAccount("someone-else")
            case 2: await mock.setPrivate(true)
            default: await mock.setHead(String(repeating: "f", count: 40))
            }
            await #expect(throws: (any Error).self) { try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in } }
            let state = await mock.state()
            #expect(state.0 == 0); #expect(state.1.isEmpty); #expect(state.2 == 0)
        }
    }
    @Test func additionalIncludedFilesInvalidateTheApprovedSet() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        try store.approve(allowUnknownComparisons: false)
        try Data([1]).write(to: URL(fileURLWithPath: job.source).appendingPathComponent("new.txt"))
        await #expect(throws: NativeUploadError.self) { try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in } }
        #expect(await mock.state().0 == 0)
    }
    @Test func partialRecoveryAdvancesOnlyAcknowledgedParentsAndSkipsTheirFiles() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        try store.approve(allowUnknownComparisons: false)
        await mock.configure(failCommit: 2)
        await #expect(throws: URLError.self) {
            try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, maximumFilesPerCommit: 1) { _ in }
        }
        #expect(try store.plan().expectedHead == String(format: "%040x", 1))
        await mock.configure()
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, maximumFilesPerCommit: 1) { _ in }
        let state = await mock.state()
        #expect(state.1 == ["a.txt", "b.bin", "b.bin"])
        #expect(state.2 == 3); #expect(state.3 == 0)
    }
    @Test func concurrentWriterOrAmbiguousCommitRequiresReviewWithoutReplay() async throws {
        for ambiguous in [false, true] {
            let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let mock = ReviewMock()
            let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
            try store.approve(allowUnknownComparisons: false)
            await mock.configure(ambiguous: ambiguous, changeDuringUpload: !ambiguous)
            await #expect(throws: (any Error).self) { try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in } }
            let before = await mock.state()
            await #expect(throws: NativeUploadError.self) { try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in } }
            let after = await mock.state()
            #expect(before.2 == after.2); #expect(before.1 == after.1)
        }
    }
    @Test func cancellationDuringHashingRemovesThePartialPlan() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await UploadPlanBuilder.build(job: job, directory: directory, transport: ReviewMock()) { status in
                if status.hasPrefix("Hashing ") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
    @Test func jobRouteChangesAndUnapprovedPlansNeverReachNegotiation() async throws {
        let (root, directory, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        let store = try await UploadPlanBuilder.build(job: original, directory: directory, transport: mock)
        await #expect(throws: NativeUploadError.self) { try await ReviewedUploader.upload(job: original, plansDirectory: directory, transport: mock) { _ in } }
        try store.approve(allowUnknownComparisons: false)
        var changed = original; changed.destination = "different"
        await #expect(throws: NativeUploadError.self) { try await ReviewedUploader.upload(job: changed, plansDirectory: directory, transport: mock) { _ in } }
        #expect(await mock.state().0 == 0)
    }
    @Test func gitSHA256IdentityUsesTheFramedBlobRatherThanRawContentHash() async throws {
        let (root, directory, job) = try fixture(["a.txt": Data("hello\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        await mock.configure(entries: [NativeHubEntry(path: "a.txt", size: 6, isDirectory: false,
            gitBlobOID: "2cf8d83d9ee29543b34a87727421fdecb7e3f3a183d337639025de576db9ebb4")])
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        #expect(try store.plan().summary.counts[.identical] == 1)
    }
    @Test func inlineAndEmptyFilesCommitTheirExactReviewedContents() async throws {
        let data = Data("hello\n".utf8)
        let (root, directory, job) = try fixture(["a.txt": data, "empty.txt": Data()])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock(); await mock.configure(mode: .regular)
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        try store.approve(allowUnknownComparisons: false)
        let events = PlanEvents()
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, onEvent: events.record)
        #expect(await mock.bodies() == [data, Data()])
        #expect(await mock.state().1.isEmpty)
        #expect(events.progress.transferredBytes == 6)
        #expect(events.progress.commits == 1)
    }
    @Test func repositoryIgnoredFilesAreRecordedWithoutCommitsOrSuccessClaimsForUploadedFiles() async throws {
        let (root, directory, job) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock(); await mock.configure(mode: .ignored)
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        try store.approve(allowUnknownComparisons: false)
        let events = PlanEvents()
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, onEvent: events.record)
        #expect(events.progress.ignoredFiles == 2)
        #expect(events.progress.uploaded == 0)
        #expect(events.progress.commits == 0)
        #expect(events.completed == 1)
        #expect(try store.rows().allSatisfy { $0.state == "ignored" })
        let before = await mock.state()
        try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock) { _ in }
        #expect(await mock.state().0 == before.0)
    }
    @Test func sourceMutationDuringTransferNeverCommitsThatContent() async throws {
        let (root, directory, job) = try fixture(["a.txt": Data("hello\n".utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock()
        let store = try await UploadPlanBuilder.build(job: job, directory: directory, transport: mock)
        try store.approve(allowUnknownComparisons: false)
        await mock.configure(mutation: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"))
        let events = PlanEvents()
        await #expect(throws: NativeUploadError.self) {
            try await ReviewedUploader.upload(job: job, plansDirectory: directory, transport: mock, onEvent: events.record)
        }
        #expect(await mock.state().2 == 0)
        #expect(events.completed == 0)
    }
    @Test func aFreshReviewUsesCurrentVisibilityAndRequiresTheApprovedJobToMatchIt() async throws {
        let (root, directory, original) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let mock = ReviewMock(); await mock.setPrivate(true)
        let store = try await UploadPlanBuilder.build(job: original, directory: directory, transport: mock)
        #expect(try store.plan().repo.isPrivate == true)
        try store.approve(allowUnknownComparisons: false)
        await #expect(throws: NativeUploadError.self) {
            try await ReviewedUploader.upload(job: original, plansDirectory: directory, transport: mock) { _ in }
        }
        #expect(await mock.state().0 == 0)
        var approved = original; approved.repo = try store.plan().repo
        try await ReviewedUploader.upload(job: approved, plansDirectory: directory, transport: mock) { _ in }
        #expect(await mock.state().2 == 1)
    }
}
