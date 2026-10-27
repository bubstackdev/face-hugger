import Foundation

public enum RepoKind: String, Codable, CaseIterable, Sendable {
    case model, dataset
    public var plural: String { self == .model ? "models" : "datasets" }
}

public struct HubRepo: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(name)" }
    public var name: String
    public var kind: RepoKind
    public var isPrivate: Bool
    public init(name: String, kind: RepoKind, isPrivate: Bool = false) {
        self.name = name; self.kind = kind; self.isPrivate = isPrivate
    }
    public var url: URL { URL(string: "https://huggingface.co/\(kind == .dataset ? "datasets/" : "")\(name)")! }
}

public enum JobState: String, Codable, Sendable {
    case queued, running, interrupted, failed, completed, stopped
    public var label: String { rawValue.capitalized }
}

/// Native transfer stage counts; these are not an overall completion percentage.
public struct UploadProgress: Decodable, Sendable {
    public var checked: Int
    public var total: Int
    public var uploaded: Int
    public var uploadTotal: Int
    public var transferred: String
    public var committed: Int
    public var commits: Int
    enum CodingKeys: String, CodingKey {
        case checked, total, uploaded, transferred, committed, commits
        case uploadTotal = "upload_total"
    }
    public var summary: String { "\(checked)/\(total) checked · \(uploaded)/\(uploadTotal) uploaded or reused · \(committed) committed" }
    public init(native: NativeUploadProgress) {
        checked = native.checked; total = native.total; uploaded = native.uploaded
        uploadTotal = native.uploadTotal; committed = native.committed; commits = native.commits
        transferred = ByteCountFormatter.string(fromByteCount: native.transferredBytes, countStyle: .file)
    }
}

public struct UploadJob: Identifiable, Codable, Sendable {
    public var id: UUID
    public var source: String
    public var sourceBookmark: Data?
    public var repo: HubRepo
    public var destination: String
    public var includes: [String]
    public var excludes: [String]
    public var state: JobState
    public var createdAt: Date
    public var finishedAt: Date?
    public var message: String
    public var fileCount: Int
    public var byteCount: Int64
    public var planID: UUID?
    public init(source: String, repo: HubRepo, destination: String = "", includes: [String] = [], excludes: [String] = [], fileCount: Int = 0, byteCount: Int64 = 0, sourceBookmark: Data? = nil) {
        self.sourceBookmark = sourceBookmark
        id = UUID(); self.source = source; self.repo = repo; self.destination = destination
        self.includes = includes; self.excludes = excludes; self.fileCount = fileCount; self.byteCount = byteCount
        state = .queued; createdAt = Date(); message = "Ready to upload"
    }
    public var title: String { URL(fileURLWithPath: source).lastPathComponent }
}

public enum UploadValidation {
    public static func error(source: String, repo: String, destination: String) -> String? {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &directory), directory.boolValue else { return "Choose an existing local folder." }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }) else { return "Use a repository ID such as username/my-model." }
        guard !destination.hasPrefix("/"), !destination.contains("\\"), !destination.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }), destination.rangeOfCharacter(from: .controlCharacters) == nil else { return "Use a relative repo folder without '.' or '..'. Leave it blank for the root." }
        return nil
    }
}

public struct QueueArchive: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [UploadJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([UploadJob].self, from: Data(contentsOf: url)).map { job in
            var recovered = job
            if recovered.state == .running { recovered.state = .interrupted; recovered.message = "Interrupted. Resume when you’re ready." }
            return recovered
        }
    }
    public func save(_ jobs: [UploadJob]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
    }
}
