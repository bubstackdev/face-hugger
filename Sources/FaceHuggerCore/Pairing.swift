import Foundation

/// A manually invoked route. Credentials and transfer state are never stored here.
public struct SavedPairing: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var source: String
    public var sourceBookmark: Data?
    public var repo: HubRepo
    public var destination: String
    public var includes: [String]
    public var excludes: [String]
    public var isPinned = false
    public var sortOrder: Int?
    public init(name: String, source: String, repo: HubRepo, destination: String, includes: [String], excludes: [String], sourceBookmark: Data? = nil) {
        self.sourceBookmark = sourceBookmark
        id = UUID(); self.name = name; self.source = source; self.repo = repo
        self.destination = destination; self.includes = includes; self.excludes = excludes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, sourceBookmark, repo, destination, includes, excludes, isPinned, sortOrder
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        source = try values.decode(String.self, forKey: .source)
        sourceBookmark = try values.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        repo = try values.decode(HubRepo.self, forKey: .repo)
        destination = try values.decode(String.self, forKey: .destination)
        includes = try values.decode([String].self, forKey: .includes)
        excludes = try values.decode([String].self, forKey: .excludes)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sortOrder = try values.decodeIfPresent(Int.self, forKey: .sortOrder)
    }

    public func matches(search: String) -> Bool {
        let terms = search.split(whereSeparator: { $0.isWhitespace })
        let text = [name, URL(fileURLWithPath: source).lastPathComponent, repo.name, destination].joined(separator: " ")
        return terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }

    /// Stable legacy array order is the fallback; pinning never rewrites route identity.
    public static func ordered(_ pairings: [SavedPairing], search: String = "") -> [SavedPairing] {
        pairings.enumerated().sorted { a, b in
            if a.element.isPinned != b.element.isPinned { return a.element.isPinned }
            let left = a.element.sortOrder ?? a.offset, right = b.element.sortOrder ?? b.offset
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element).filter { $0.matches(search: search) }
    }
}

/// Device and inode identify the resolved folder, including through aliases and moves.
/// This is a live workspace identity, not a replacement for a security bookmark.
public struct PairingFolderIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
        guard values[.type] as? FileAttributeType == .typeDirectory,
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        self.device = device.uint64Value; self.inode = inode.uint64Value
    }
}

public struct ActivePairing: Sendable {
    public let id: UUID
    private let folder: PairingFolderIdentity
    private let repoID: String
    private let destination: Data
    private let includes: [Data]
    private let excludes: [Data]
    public init(pairing: SavedPairing, folder: PairingFolderIdentity) {
        id = pairing.id; self.folder = folder; repoID = pairing.repo.id
        destination = Data(pairing.destination.utf8)
        includes = pairing.includes.map { Data($0.utf8) }; excludes = pairing.excludes.map { Data($0.utf8) }
    }
    public func matches(folder: PairingFolderIdentity?, repo: HubRepo?, destination: String, includes: [String], excludes: [String]) -> Bool {
        self.folder == folder && repoID == repo?.id && self.destination == Data(destination.utf8) &&
            self.includes == includes.map { Data($0.utf8) } && self.excludes == excludes.map { Data($0.utf8) }
    }
}

public struct PairingArchive: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [SavedPairing] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedPairing].self, from: Data(contentsOf: url))
    }
    public func save(_ pairings: [SavedPairing]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pairings).write(to: url, options: .atomic)
    }
}
