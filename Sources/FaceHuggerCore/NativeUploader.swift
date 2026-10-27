import Foundation
import CryptoKit
import Darwin

public struct NativeUploadProgress: Codable, Equatable, Sendable {
    public var checked = 0, total = 0, uploaded = 0, uploadTotal = 0, committed = 0, commits = 0
    public var transferredBytes: Int64 = 0
    public var identicalFiles: Int?
    public var ignoredFiles: Int?
}
public enum NativeUploadEvent: Sendable {
    case phase(TransferPhase, file: String?)
    case transport(NativeTransferEvent)
    case status(String)
    case progress(NativeUploadProgress)
    case committed(NativeCommitResult, fileCount: Int)
    case verifiedRevision(String)
    case completed(URL)
}
public protocol NativeUploadTransport: Sendable {
    func info(repo: HubRepo) async throws -> HubRepo
    func streamTree(repo: HubRepo, path: String, recursive: Bool, onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws
    func headCommit(repo: HubRepo) async throws -> String?
    func preupload(repo: HubRepo, files: [NativeUploadDescriptor]) async throws -> [Data: NativeUploadMode]
    func uploadLFS(repo: HubRepo, file: URL, descriptor: NativeUploadDescriptor, onBytes: @escaping @Sendable (Int64) -> Void) async throws
    func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String) async throws -> NativeCommitResult
}
public enum NativeUploadError: LocalizedError, Equatable {
    case invalid(String), sourceChanged(String), checkpoint(String), unconfirmedCommit, reviewRequired(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .checkpoint(let text), .reviewRequired(let text): return text
        case .sourceChanged(let path): return "Source changed: \(path). Start a new upload to use the updated files."
        case .unconfirmedCommit: return "The server did not confirm the commit. Resume to check and retry safely."
        }
    }
}

/// File-level checkpoints deliberately contain neither credentials nor signed upload URLs.
/// A failed or ambiguous commit is replayed; only a confirmed, still-current remote head permits skipping.
public enum NativeUploader {
    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock(); private var bytes: Int64 = 0
        func update(_ value: Int64) -> Int64 { lock.withLock { bytes = max(bytes, value); return bytes } }
        var value: Int64 { lock.withLock { bytes } }
    }
    private static let blockSize = 1024 * 1024
    private static let regularLimit = 16 * 1024 * 1024
    private typealias Stamp = UploadFileStamp
    private typealias Entry = UploadSourceEntry
    private struct Summary: Codable { var version = 1; var fingerprint: String; var head: String?; var epoch = UUID() }
    private struct Receipt: Codable { var path: String; var sha256: String; var epoch: UUID }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    private static func sourceFile(root: URL, path: String) throws -> URL { try UploadSource.file(root: root, path: path) }
    private static func verify(_ entry: Entry, root: URL) throws -> URL { try UploadSource.verify(entry, root: root) }
    private static func descriptor(_ entry: Entry, root: URL, destination: String) throws -> NativeUploadDescriptor {
        try UploadSource.hash(entry, root: root, destination: destination, includeGit: false).descriptor
    }
    /// The line reader holds at most one metadata record, even for millions of source files.
    private final class Lines {
        let handle: FileHandle; var buffer = Data(); var ended = false
        init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
        deinit { try? handle.close() }
        func next() throws -> Entry? {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                    return try JSONDecoder().decode(Entry.self, from: line)
                }
                if ended { return nil }
                let chunk = try handle.read(upToCount: 65536) ?? Data()
                if chunk.isEmpty { ended = true } else { buffer.append(chunk) }
                guard buffer.count < 1024 * 1024 else { throw NativeUploadError.checkpoint("Invalid upload manifest.") }
            }
        }
    }
    public static func upload(job: UploadJob, token: String?, checkpointDirectory: URL, onEvent: @escaping @Sendable (NativeUploadEvent) -> Void) async throws {
        try await upload(job: job, transport: NativeHubClient(token: token), checkpointDirectory: checkpointDirectory, onEvent: onEvent)
    }
    public static func upload(job: UploadJob, transport: any NativeUploadTransport, checkpointDirectory: URL, maximumFilesPerCommit: Int = 100, onEvent: @escaping @Sendable (NativeUploadEvent) -> Void) async throws {
        if let error = UploadValidation.error(source: job.source, repo: job.repo.name, destination: job.destination) { throw NativeUploadError.invalid(error) }
        let root = URL(fileURLWithPath: job.source).standardizedFileURL.resolvingSymlinksInPath()
        let base = checkpointDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard base != root, !base.path.hasPrefix(root.path + "/") else { throw NativeUploadError.invalid("Upload checkpoints must be outside the source folder.") }
        let route = try encode([[root.path, job.repo.id, job.destination], job.includes, job.excludes])
        let folder = base.appendingPathComponent(job.id.uuidString + "-" + digest(route))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only our generated transient files are removed; receipts survive interruption.
        for stale in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let name = stale.lastPathComponent
            if name.range(of: "^(scan-[A-Fa-f0-9-]{36}\\.ndjson|paths-[A-Fa-f0-9-]{36}\\.sqlite(-journal|-wal|-shm)?)$", options: .regularExpression) != nil { try FileManager.default.removeItem(at: stale) }
        }
        let manifest = folder.appendingPathComponent("scan-\(UUID().uuidString).ndjson")
        FileManager.default.createFile(atPath: manifest.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: manifest) }
        let indexURL = folder.appendingPathComponent("paths-\(UUID().uuidString).sqlite")
        let index = try NativeUploadPathIndex(url: indexURL, destination: job.destination)
        defer { try? index.close(); try? FileManager.default.removeItem(at: indexURL) }
        let writer = try FileHandle(forWritingTo: manifest)
        var fingerprint = [UInt8](repeating: 0, count: 32), progress = NativeUploadProgress()
        onEvent(.status("Checking source files…"))
        do {
            try NativeScanner.walk(source: root, includes: job.includes, excludes: job.excludes) { file in
                guard file.included else { return }
                let entry = Entry(path: file.path, stamp: try Stamp(sourceFile(root: root, path: file.path)))
                try index.add(path: entry.path)
                let data = try encode(entry), hash = Array(SHA256.hash(data: data))
                for index in fingerprint.indices { fingerprint[index] ^= hash[index] }
                try writer.write(contentsOf: data + Data([10])); progress.total += 1
            }
            try writer.synchronize(); try writer.close()
        } catch { try? writer.close(); throw error }
        guard progress.total > 0 else { throw NativeUploadError.invalid("No files match this upload’s filters.") }
        let signature = fingerprint.map { String(format: "%02x", $0) }.joined() + ":\(progress.total)"
        let summaryURL = folder.appendingPathComponent("summary.json")
        var summary = Summary(fingerprint: signature)
        if FileManager.default.fileExists(atPath: summaryURL.path) {
            summary = try JSONDecoder().decode(Summary.self, from: Data(contentsOf: summaryURL))
            guard summary.version == 1, summary.fingerprint == signature else { throw NativeUploadError.sourceChanged("folder contents") }
        } else { try encode(summary).write(to: summaryURL, options: .atomic) }
        onEvent(.status("Checking repository paths…"))
        let freshRepo = try await transport.info(repo: job.repo)
        guard freshRepo.isPrivate == job.repo.isPrivate else { throw NativeUploadError.invalid("Repository visibility changed. Review the destination and start a new upload.") }
        try await transport.streamTree(repo: job.repo, path: "", recursive: true) { remote in
            try Task.checkCancellation()
            if let conflict = try index.observe(path: remote.path, isDirectory: remote.isDirectory) {
                throw NativeUploadError.invalid(conflict.reason)
            }
        }
        let head = try await transport.headCommit(repo: job.repo)
        let reuseConfirmed = head != nil && head == summary.head
        if !reuseConfirmed {
            summary.epoch = UUID(); summary.head = nil
            try encode(summary).write(to: summaryURL, options: .atomic)
        }
        let reader = try Lines(manifest)
        progress.uploadTotal = progress.total
        var pending: [(Entry, NativeCommitFile, URL)] = []
        var inlineBytes = 0
        let batchLimit = min(100, max(1, maximumFilesPerCommit))
        func flush() async throws {
            guard !pending.isEmpty else { return }
            try Task.checkCancellation()
            for (entry, _, _) in pending { _ = try verify(entry, root: root) }
            let result = try await transport.commit(repo: job.repo, additions: pending.map { $0.1 }, deletions: [], message: "Upload files with Face Hugger")
            guard result.commitOID.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil else { throw NativeUploadError.unconfirmedCommit }
            // Record the acknowledgement before local checkpoint writes can fail.
            onEvent(.committed(result, fileCount: pending.count))
            for (entry, addition, receiptURL) in pending {
                try encode(Receipt(path: entry.path, sha256: addition.descriptor.sha256, epoch: summary.epoch)).write(to: receiptURL, options: .atomic)
            }
            summary.head = result.commitOID
            try encode(summary).write(to: summaryURL, options: .atomic)
            progress.committed += pending.count; progress.commits += 1
            progress.uploaded += pending.filter { $0.1.content != nil }.count
            progress.transferredBytes += Int64(inlineBytes)
            pending.removeAll(keepingCapacity: true); inlineBytes = 0
            onEvent(.progress(progress))
        }
        while let entry = try reader.next() {
            try Task.checkCancellation()
            let file = try verify(entry, root: root)
            onEvent(.status("Hashing \(entry.path)"))
            let descriptor = try descriptor(entry, root: root, destination: job.destination)
            progress.checked += 1; onEvent(.progress(progress))
            let receiptURL = folder.appendingPathComponent(digest(Data(entry.path.utf8)) + ".json")
            if reuseConfirmed, let data = try? Data(contentsOf: receiptURL), let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.epoch == summary.epoch, Data(receipt.path.utf8) == Data(entry.path.utf8), receipt.sha256 == descriptor.sha256 {
                progress.uploaded += 1; progress.committed += 1; onEvent(.progress(progress)); continue
            }
            let modes = try await transport.preupload(repo: job.repo, files: [descriptor])
            guard let mode = modes[Data(descriptor.path.utf8)] else { throw NativeUploadError.invalid("The server did not specify an upload mode for \(entry.path).") }
            let addition: NativeCommitFile
            switch mode {
            case .ignored:
                progress.uploadTotal -= 1; onEvent(.status("Skipped \(entry.path) (repository ignore rules)")); onEvent(.progress(progress)); continue
            case .regular:
                guard descriptor.size <= regularLimit else { throw NativeUploadError.invalid("The server selected an inline upload for a file larger than 16 MiB: \(entry.path). Configure this file for LFS and retry.") }
                if inlineBytes + Int(descriptor.size) > regularLimit { try await flush() }
                let contentHandle = try FileHandle(forReadingFrom: file)
                let data: Data
                do { data = try contentHandle.read(upToCount: regularLimit + 1) ?? Data(); try contentHandle.close() }
                catch { try? contentHandle.close(); throw error }
                guard Int64(data.count) == descriptor.size, digest(data) == descriptor.sha256 else { throw NativeUploadError.sourceChanged(entry.path) }
                addition = NativeCommitFile(descriptor: descriptor, content: data)
                inlineBytes += data.count
            case .lfs:
                onEvent(.status("Uploading \(entry.path)"))
                let baseline = progress, sent = ByteCounter()
                try await transport.uploadLFS(repo: job.repo, file: file, descriptor: descriptor, onBytes: { value in
                    var latest = baseline
                    latest.transferredBytes += sent.update(max(0, min(descriptor.size, value)))
                    onEvent(.progress(latest))
                })
                progress.transferredBytes += sent.value
                addition = NativeCommitFile(descriptor: descriptor)
            }
            _ = try verify(entry, root: root)
            if addition.content == nil { progress.uploaded += 1 }; onEvent(.progress(progress))
            pending.append((entry, addition, receiptURL))
            if pending.count >= batchLimit { try await flush() }
        }
        try await flush()
        try Task.checkCancellation()
        let finalReader = try Lines(manifest)
        while let entry = try finalReader.next() { try Task.checkCancellation(); _ = try verify(entry, root: root) }
        onEvent(.completed(job.repo.url))
    }
}
extension NativeHubClient: NativeUploadTransport {}
