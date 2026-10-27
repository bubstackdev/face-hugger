import Foundation
import SQLite3

public protocol NativeReviewedTransport: NativeUploadTransport {
    func whoami() async throws -> NativeHubIdentity
    func streamTree(repo: HubRepo, path: String, recursive: Bool, revision: String,
                    onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws
    func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String,
                expectedParent: String) async throws -> NativeCommitResult
}
extension NativeHubClient: NativeReviewedTransport {}

public enum PlannedFileAction: String, Codable, CaseIterable, Sendable {
    case add, replace, identical, excluded, needsComparison, conflict
    public var label: String {
        switch self {
        case .add: "Add"
        case .replace: "Replace"
        case .identical: "Identical"
        case .excluded: "Excluded"
        case .needsComparison: "Could not compare"
        case .conflict: "Conflict"
        }
    }
}

public struct UploadPlanSummary: Codable, Equatable, Sendable {
    public var counts: [PlannedFileAction: Int] = [:]
    public var includedBytes: Int64 = 0
    public var candidateBytes: Int64 = 0
    public var totalCount: Int { counts.values.reduce(0, +) }
    public var includedCount: Int { totalCount - (counts[.excluded] ?? 0) }
}

public struct UploadPlan: Codable, Identifiable, Sendable {
    public var schema = 1
    public let id: UUID
    public let jobID: UUID
    public let source: String
    public let repo: HubRepo
    public let destination: String
    public let includes: [String]
    public let excludes: [String]
    public let account: String
    public let createdAt: Date
    public let originalHead: String?
    public fileprivate(set) var expectedHead: String?
    public fileprivate(set) var sourceFingerprint = ""
    public fileprivate(set) var summary = UploadPlanSummary()
    public fileprivate(set) var complete = false
    public fileprivate(set) var blockedReason: String?
    public fileprivate(set) var approvedAt: Date?
    public fileprivate(set) var approvedUnknownComparisons = false

    public var canApprove: Bool {
        complete && originalHead != nil && summary.includedCount > 0 && (summary.counts[.conflict] ?? 0) == 0
    }
    func matches(_ job: UploadJob) -> Bool {
        job.id == jobID && job.planID == id && Data(job.source.utf8) == Data(source.utf8) && job.repo == repo
            && Data(job.destination.utf8) == Data(destination.utf8)
            && job.includes.map { Data($0.utf8) } == includes.map { Data($0.utf8) }
            && job.excludes.map { Data($0.utf8) } == excludes.map { Data($0.utf8) }
    }
}

public struct UploadPlanRow: Identifiable, Sendable {
    public var id: Data { Data(path.utf8) }
    public let path: String
    public let size: Int64
    public let action: PlannedFileAction
    public let reason: String?
    let entry: UploadSourceEntry?
    let sha256: String?
    let state: String
}

/// A complete on-disk inventory, with bounded page reads and binary UTF-8 path identity.
public final class UploadPlanStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var database: OpaquePointer?
    private enum Value { case text(String), blob(Data), integer(Int64), null }

    public static func url(directory: URL, jobID: UUID, planID: UUID) -> URL {
        directory.appendingPathComponent("\(jobID.uuidString)-\(planID.uuidString).sqlite")
    }
    private init(url: URL, create: Bool) throws {
        self.url = url
        if create {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Self.failure() }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } else { guard FileManager.default.fileExists(atPath: url.path) else { throw NativeUploadError.reviewRequired("The saved upload plan is missing. Review the upload again.") } }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil; throw Self.failure()
        }
        do {
            try run("PRAGMA cache_size = -2048")
            if create {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                try run("CREATE TABLE metadata (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)")
                try run("CREATE TABLE files (path TEXT PRIMARY KEY COLLATE BINARY, full TEXT UNIQUE COLLATE BINARY, size INTEGER NOT NULL, entry BLOB, sha256 TEXT, git1 TEXT, git256 TEXT, action TEXT NOT NULL, reason TEXT, state TEXT NOT NULL DEFAULT 'pending') WITHOUT ROWID")
                try run("BEGIN IMMEDIATE")
            }
        } catch { if let database { sqlite3_close(database) }; database = nil; throw error }
    }
    deinit { close() }
    public func close() { lock.withLock { if let database { sqlite3_close(database) }; database = nil } }
    public func discard() throws {
        close()
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    public static func open(at url: URL) throws -> UploadPlanStore {
        let store = try UploadPlanStore(url: url, create: false)
        let plan = try store.plan()
        guard plan.schema == 1 else { throw NativeUploadError.reviewRequired("The saved upload plan has an unsupported version. Review it again.") }
        return store
    }
    fileprivate static func create(at url: URL, plan: UploadPlan) throws -> UploadPlanStore {
        let store = try UploadPlanStore(url: url, create: true)
        try store.savePlan(plan)
        return store
    }
    public func plan() throws -> UploadPlan {
        try lock.withLock {
            var plan: UploadPlan?
            try query("SELECT data FROM metadata WHERE id=1") { stmt in
                guard let data = Self.blob(stmt, 0), data.count <= 128 * 1024 else { throw Self.failure() }
                plan = try JSONDecoder().decode(UploadPlan.self, from: data)
            }
            guard let plan else { throw Self.failure() }; return plan
        }
    }
    public func rows(offset: Int = 0, limit: Int = 100, action: PlannedFileAction? = nil) throws -> [UploadPlanRow] {
        try lock.withLock {
            var result: [UploadPlanRow] = []
            var values: [Value] = []
            let condition = action.map { _ in " WHERE action=?" } ?? ""
            if let action { values.append(.text(action.rawValue)) }
            values += [.integer(Int64(max(1, min(200, limit)))), .integer(Int64(max(0, offset)))]
            try query("SELECT path,size,action,reason,entry,sha256,state FROM files" + condition + " ORDER BY path COLLATE BINARY LIMIT ? OFFSET ?", values) {
                result.append(try Self.row($0))
            }
            return result
        }
    }
    func executionPage(after: String?, limit: Int = 100) throws -> [UploadPlanRow] {
        try lock.withLock {
            var result: [UploadPlanRow] = []
            let condition = after == nil ? "" : " AND path > ? COLLATE BINARY"
            var values: [Value] = after.map { [.text($0)] } ?? []
            values.append(.integer(Int64(max(1, min(100, limit)))))
            try query("SELECT path,size,action,reason,entry,sha256,state FROM files WHERE action != 'excluded'" + condition + " ORDER BY path COLLATE BINARY LIMIT ?", values) {
                result.append(try Self.row($0))
            }
            return result
        }
    }
    func localRow(path: String) throws -> UploadPlanRow? {
        try lock.withLock {
            var result: UploadPlanRow?
            try query("SELECT path,size,action,reason,entry,sha256,state FROM files WHERE path=?", [.text(path)]) { result = try Self.row($0) }
            return result
        }
    }
    public func approve(allowUnknownComparisons: Bool) throws {
        var plan = try plan()
        guard plan.canApprove else { throw NativeUploadError.reviewRequired(plan.blockedReason ?? "Resolve the upload conflicts before approving this plan.") }
        guard (plan.summary.counts[.needsComparison] ?? 0) == 0 || allowUnknownComparisons else {
            throw NativeUploadError.reviewRequired("Approve the files whose contents could not be compared, or cancel this upload.")
        }
        plan.approvedAt = Date(); plan.approvedUnknownComparisons = allowUnknownComparisons
        try lock.withLock { try savePlan(plan) }
    }
    fileprivate func add(path: String, size: Int64, destination: String, entry: UploadSourceEntry?, digest: UploadSourceDigest?) throws {
        try lock.withLock {
            let full = destination.isEmpty ? path : destination + "/" + path
            try run("INSERT INTO files(path,full,size,entry,sha256,git1,git256,action) VALUES(?,?,?,?,?,?,?,?)", [
                .text(path), .text(full), .integer(size), try entry.map { .blob(try UploadSource.encode($0)) } ?? .null,
                digest.map { .text($0.descriptor.sha256) } ?? .null, digest.map { .text($0.gitSHA1) } ?? .null,
                digest.map { .text($0.gitSHA256) } ?? .null, .text(entry == nil ? "excluded" : "add")])
        }
    }
    fileprivate func observe(_ remote: NativeHubEntry) throws {
        try lock.withLock {
            try NativeHubClient.validatePath(remote.path)
            if remote.isDirectory {
                try run("UPDATE files SET action='conflict', reason=? WHERE full=? AND action!='excluded'", [
                    .text("A remote folder occupies this file path."), .text(remote.path)])
                return
            }
            try run("UPDATE files SET action='conflict', reason=? WHERE full>=? AND full<? AND action!='excluded'", [
                .text("A remote file blocks a required folder."), .text(remote.path + "/"), .text(remote.path + "0")])
            var action: PlannedFileAction?
            try query("SELECT size,sha256,git1,git256,action FROM files WHERE full=? AND action NOT IN ('excluded','conflict')", [.text(remote.path)]) { stmt in
                let local: String?, foreign: String?
                if let lfs = remote.lfsSHA256 {
                    local = Self.text(stmt, 1); foreign = lfs.lowercased()
                } else if remote.xetHash == nil, let blob = remote.gitBlobOID, [40, 64].contains(blob.count) {
                    local = Self.text(stmt, blob.count == 40 ? 2 : 3); foreign = blob.lowercased()
                } else { local = nil; foreign = nil }
                if let local, let foreign {
                    action = local == foreign ? (remote.size == sqlite3_column_int64(stmt, 0) ? .identical : .needsComparison) : .replace
                } else { action = .needsComparison }
            }
            if let action { try run("UPDATE files SET action=? WHERE full=? AND action!='conflict'", [.text(action.rawValue), .text(remote.path)]) }
        }
    }
    fileprivate func finishBuild(_ value: UploadPlan) throws -> UploadPlan {
        try lock.withLock {
            var plan = value
            if plan.originalHead == nil {
                try run("UPDATE files SET action='needsComparison' WHERE action!='excluded'")
                plan.blockedReason = "The repository has no confirmed revision. Create its initial commit on Hugging Face, then review again."
            }
            try query("SELECT action,COUNT(*),COALESCE(SUM(size),0) FROM files GROUP BY action") { stmt in
                guard let raw = Self.text(stmt, 0), let action = PlannedFileAction(rawValue: raw) else { throw Self.failure() }
                plan.summary.counts[action] = Int(sqlite3_column_int64(stmt, 1))
                if action != .excluded { plan.summary.includedBytes += sqlite3_column_int64(stmt, 2) }
                if [.add, .replace, .needsComparison].contains(action) { plan.summary.candidateBytes += sqlite3_column_int64(stmt, 2) }
            }
            plan.complete = plan.originalHead != nil
            try savePlan(plan); try run("COMMIT")
            return plan
        }
    }
    func recordIgnored(path: String) throws { try lock.withLock { try run("UPDATE files SET state='ignored' WHERE path=?", [.text(path)]) } }
    func recordCommit(_ result: NativeCommitResult, paths: [String]) throws {
        var plan = try plan(); plan.expectedHead = result.commitOID
        try lock.withLock {
            try run("BEGIN IMMEDIATE")
            do {
                for path in paths { try run("UPDATE files SET state='committed' WHERE path=?", [.text(path)]) }
                try savePlan(plan); try run("COMMIT")
            } catch { try? run("ROLLBACK"); throw error }
        }
    }
    private func savePlan(_ plan: UploadPlan) throws {
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 128 * 1024 else { throw Self.failure() }
        try run("INSERT OR REPLACE INTO metadata(id,data) VALUES(1,?)", [.blob(data)])
    }
    private static func row(_ stmt: OpaquePointer) throws -> UploadPlanRow {
        guard let path = text(stmt, 0), let raw = text(stmt, 2), let action = PlannedFileAction(rawValue: raw),
              let state = text(stmt, 6), ["pending", "committed", "ignored"].contains(state) else { throw failure() }
        return UploadPlanRow(path: path, size: sqlite3_column_int64(stmt, 1), action: action, reason: text(stmt, 3),
            entry: try blob(stmt, 4).map { try JSONDecoder().decode(UploadSourceEntry.self, from: $0) }, sha256: text(stmt, 5), state: state)
    }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        try statement(sql, values) { stmt in guard sqlite3_step(stmt) == SQLITE_DONE else { throw Self.failure() } }
    }
    private func query(_ sql: String, _ values: [Value] = [], _ receive: (OpaquePointer) throws -> Void) throws {
        try statement(sql, values) { stmt in
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW: try receive(stmt)
                case SQLITE_DONE: return
                default: throw Self.failure()
                }
            }
        }
    }
    private func statement(_ sql: String, _ values: [Value], _ body: (OpaquePointer) throws -> Void) throws {
        guard let database else { throw Self.failure() }
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &raw, nil) == SQLITE_OK, let stmt = raw else { throw Self.failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), transient) }
            case .integer(let number): result = sqlite3_bind_int64(stmt, index, number)
            case .null: result = sqlite3_bind_null(stmt, index)
            }
            guard result == SQLITE_OK else { throw Self.failure() }
        }
        try body(stmt)
    }
    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }
    private static func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL, let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }
    private static func failure() -> NativeUploadError { .checkpoint("Could not read or save the upload review. Check local storage and review again.") }
}

public enum UploadPlanBuilder {
    public static func build(job: UploadJob, directory: URL, transport: any NativeReviewedTransport,
                             onStatus: @escaping @Sendable (String) -> Void = { _ in }) async throws -> UploadPlanStore {
        try await build(job: job, directory: directory, transport: transport, onPhase: { _ in }, onStatus: onStatus)
    }

    public static func build(job: UploadJob, directory: URL, transport: any NativeReviewedTransport,
                             onPhase: @escaping @Sendable (TransferPhase) -> Void,
                             onStatus: @escaping @Sendable (String) -> Void = { _ in }) async throws -> UploadPlanStore {
        if let error = UploadValidation.error(source: job.source, repo: job.repo.name, destination: job.destination) { throw NativeUploadError.invalid(error) }
        let root = URL(fileURLWithPath: job.source).standardizedFileURL.resolvingSymlinksInPath()
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard base != root, !base.path.hasPrefix(root.path + "/"), let id = job.planID else { throw NativeUploadError.invalid("Upload reviews must be saved outside the source folder with a plan identity.") }
        onStatus("Checking account and repository…")
        onPhase(.validating)
        let account = try await transport.whoami()
        let repo = try await transport.info(repo: job.repo)
        guard Data(repo.name.utf8) == Data(job.repo.name.utf8), repo.kind == job.repo.kind else {
            throw NativeUploadError.reviewRequired("Repository identity changed. Select the destination again.")
        }
        let head = try await transport.headCommit(repo: repo)
        if let head, head.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) == nil {
            throw NativeHubError.invalidResponse("The repository did not provide a complete revision identity.")
        }
        var plan = UploadPlan(id: id, jobID: job.id, source: job.source, repo: repo, destination: job.destination,
                              includes: job.includes, excludes: job.excludes, account: account.name, createdAt: Date(),
                              originalHead: head, expectedHead: head)
        let store = try UploadPlanStore.create(at: UploadPlanStore.url(directory: base, jobID: job.id, planID: id), plan: plan)
        var keep = false
        defer { if !keep { try? store.discard() } }
        var fingerprint = [UInt8](repeating: 0, count: 32), count = 0
        onPhase(.scanning)
        try NativeScanner.walk(source: root, includes: job.includes, excludes: job.excludes) { file in
            try Task.checkCancellation()
            if file.included {
                try NativeHubClient.validatePath(job.destination.isEmpty ? file.path : job.destination + "/" + file.path)
                let entry = UploadSourceEntry(path: file.path, stamp: try UploadFileStamp(UploadSource.file(root: root, path: file.path)))
                guard entry.stamp.size == file.size else { throw NativeUploadError.sourceChanged(file.path) }
                onStatus("Hashing \(file.path)")
                onPhase(.hashing)
                let digest = try UploadSource.hash(entry, root: root, destination: job.destination)
                try store.add(path: file.path, size: file.size, destination: job.destination, entry: entry, digest: digest)
                try UploadSource.fingerprint(entry, into: &fingerprint); count += 1
            } else { try store.add(path: file.path, size: file.size, destination: job.destination, entry: nil, digest: nil) }
        }
        guard count > 0 else { throw NativeUploadError.invalid("No files match this upload’s filters.") }
        plan.sourceFingerprint = UploadSource.hex(fingerprint) + ":\(count)"
        if let head {
            onStatus("Comparing the complete repository revision…")
            onPhase(.comparing)
            try await transport.streamTree(repo: repo, path: "", recursive: true, revision: head) { entry in
                try Task.checkCancellation(); try store.observe(entry)
            }
            guard try await transport.headCommit(repo: repo) == head else { throw NativeUploadError.reviewRequired("The repository changed during review. Review it again.") }
        }
        onPhase(.verifying)
        try validateSource(job: job, store: store, fingerprint: plan.sourceFingerprint)
        try Task.checkCancellation()
        _ = try store.finishBuild(plan)
        keep = true; return store
    }

    static func validateSource(job: UploadJob, store: UploadPlanStore, fingerprint expected: String) throws {
        let root = URL(fileURLWithPath: job.source).standardizedFileURL.resolvingSymlinksInPath()
        var fingerprint = [UInt8](repeating: 0, count: 32), count = 0
        try NativeScanner.walk(source: root, includes: job.includes, excludes: job.excludes) { file in
            guard file.included else { return }
            try Task.checkCancellation()
            guard let row = try store.localRow(path: file.path), let entry = row.entry,
                  row.action != .excluded else { throw NativeUploadError.sourceChanged(file.path) }
            _ = try UploadSource.verify(entry, root: root)
            try UploadSource.fingerprint(entry, into: &fingerprint); count += 1
        }
        guard UploadSource.hex(fingerprint) + ":\(count)" == expected else { throw NativeUploadError.sourceChanged("folder contents") }
    }
}
