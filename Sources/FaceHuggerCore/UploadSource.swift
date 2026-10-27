import Foundation
import CryptoKit
import Darwin

// These Codable fields are also the existing uploader's checkpoint fingerprint format.
struct UploadFileStamp: Codable, Equatable, Sendable {
    var device: Int32, inode: UInt64, size: Int64, modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
    init(_ url: URL) throws {
        var value = stat()
        guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw NativeUploadError.invalid("Cannot read source file: \(url.lastPathComponent)")
        }
        self.init(value)
    }
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modified = Int64(value.st_mtimespec.tv_sec); modifiedNS = Int64(value.st_mtimespec.tv_nsec)
        changed = Int64(value.st_ctimespec.tv_sec); changedNS = Int64(value.st_ctimespec.tv_nsec)
    }
}
struct UploadSourceEntry: Codable, Sendable { var path: String; var stamp: UploadFileStamp }
struct UploadSourceDigest: Sendable {
    var descriptor: NativeUploadDescriptor
    var gitSHA1: String
    var gitSHA256: String
}

enum UploadSource {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func file(root: URL, path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw NativeUploadError.invalid("Invalid source path.") }
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { throw NativeUploadError.invalid("Source link leaves the selected folder: \(path)") }
        return file
    }
    static func verify(_ entry: UploadSourceEntry, root: URL) throws -> URL {
        let file = try file(root: root, path: entry.path)
        guard try UploadFileStamp(file) == entry.stamp else { throw NativeUploadError.sourceChanged(entry.path) }
        return file
    }
    static func hash(_ entry: UploadSourceEntry, root: URL, destination: String, includeGit: Bool = true) throws -> UploadSourceDigest {
        let file = try verify(entry, root: root)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var opened = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, UploadFileStamp(opened) == entry.stamp else { throw NativeUploadError.sourceChanged(entry.path) }
        var actualPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle.fileDescriptor, F_GETPATH, &actualPath) == 0,
              URL(fileURLWithPath: String(decoding: actualPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).standardizedFileURL.path.hasPrefix(root.path + "/") else { throw NativeUploadError.sourceChanged(entry.path) }
        var content = SHA256(), gitSHA1 = Insecure.SHA1(), gitSHA256 = SHA256()
        let header = Data("blob \(entry.stamp.size)\0".utf8)
        if includeGit { gitSHA1.update(data: header); gitSHA256.update(data: header) }
        var sample = Data(), count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            if sample.isEmpty { sample = Data(data.prefix(512)) }
            content.update(data: data)
            if includeGit { gitSHA1.update(data: data); gitSHA256.update(data: data) }
            count += Int64(data.count)
        }
        _ = try verify(entry, root: root)
        guard fstat(handle.fileDescriptor, &opened) == 0, UploadFileStamp(opened) == entry.stamp,
              count == entry.stamp.size else { throw NativeUploadError.sourceChanged(entry.path) }
        return UploadSourceDigest(
            descriptor: NativeUploadDescriptor(path: destination.isEmpty ? entry.path : destination + "/" + entry.path,
                size: count, sha256: hex(content.finalize()), sample: sample),
            gitSHA1: includeGit ? hex(gitSHA1.finalize()) : "", gitSHA256: includeGit ? hex(gitSHA256.finalize()) : "")
    }
    static func fingerprint(_ entry: UploadSourceEntry, into bytes: inout [UInt8]) throws {
        let hash = Array(SHA256.hash(data: try encode(entry)))
        for index in bytes.indices { bytes[index] ^= hash[index] }
    }
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
