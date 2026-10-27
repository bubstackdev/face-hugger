import AppKit
import Foundation
import Security

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Face Hugger")
    #if STORE_BUILD
    static let isStoreEdition = true
    #else
    static let isStoreEdition = false
    #endif
    static let runtimeReady = true
    static let checkpoints = support.appendingPathComponent("native-uploads", isDirectory: true)
    static let uploadPlans = support.appendingPathComponent("upload-plans", isDirectory: true)

}

enum CredentialStore {
    static let service = "dev.zakkeown.FaceHugger"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "huggingface", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "huggingface"]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            return
        }
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        var item = query; item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Owns one structured native operation; stop also handles cancellation before start.
final class NativeOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: (@Sendable () -> Void)?
    func stop() {
        let cancel = lock.withLock { cancelled = true; return cancellation }
        cancel?()
    }
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try await operation() }
        lock.withLock {
            cancellation = { task.cancel() }
            if cancelled { task.cancel() }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

struct HubIdentity: Codable, Sendable {
    var name: String
    var organizations: [String]
}
struct RepoResponse: Codable, Sendable {
    var id: String
    var type: String
    var `private`: Bool
    var repo: HubRepo { HubRepo(name: id, kind: RepoKind(rawValue: type) ?? .model, isPrivate: self.private) }
}
struct RemoteEntry: Codable, Identifiable, Hashable, Sendable {
    var id: Data { Data(path.utf8) }
    var path: String
    var type: String
    var size: Int64?
    var isDirectory: Bool { type == "directory" }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

enum HubService {
    /// Adapter for the existing UI commands. All work now uses the native client.
    static func request<T: Decodable & Sendable>(_ args: [String], token: String?, process: NativeOperation? = nil) async throws -> T {
        let operation = process ?? NativeOperation()
        return try await operation.run {
            func value(_ flag: String, fallback: String = "") -> String {
                guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return fallback }
                return args[index + 1]
            }
            func values(_ flag: String) -> [String] {
                args.indices.compactMap { args[$0] == flag && args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            }
            func encoded<E: Encodable>(_ result: E) throws -> Data { try JSONEncoder().encode(result) }
            func response(_ repo: HubRepo) -> RepoResponse { RepoResponse(id: repo.name, type: repo.kind.rawValue, private: repo.isPrivate) }
            let hub = NativeHubClient(token: token)
            let repo = HubRepo(name: value("--repo"), kind: RepoKind(rawValue: value("--type")) ?? .model)
            let data: Data
            switch args.first {
            case "whoami":
                let result = try await hub.whoami()
                data = try encoded(HubIdentity(name: result.name, organizations: result.organizations))
            case "repos": data = try encoded(try await hub.repos(owner: value("--owner")).map(response))
            case "info": data = try encoded(response(try await hub.info(repo: repo)))
            case "create":
                let created = HubRepo(name: repo.name, kind: repo.kind, isPrivate: value("--private") == "true")
                data = try encoded(response(try await hub.create(repo: created)))
            case "tree":
                let entries = try await hub.tree(repo: repo, path: value("--path"), allowMissingPath: args.contains("--allow-missing-path"))
                data = try encoded(entries.map { RemoteEntry(path: $0.path, type: $0.isDirectory ? "directory" : "file", size: $0.size) })
            case "delete":
                _ = try await hub.deleteFile(repo: repo, path: value("--path"))
                data = try encoded(["path": value("--path")])
            case "scan":
                data = try encoded(NativeScanner.scan(source: URL(fileURLWithPath: value("--source")), includes: values("--include"), excludes: values("--exclude")))
            case "compare":
                let manifest = URL(fileURLWithPath: value("--manifest"))
                let handle = try FileHandle(forReadingFrom: manifest); defer { try? handle.close() }
                let raw = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                guard raw.count <= 16 * 1024 * 1024 else { throw NativeHubError.invalidInput("Comparison manifest is too large.") }
                let paths = try JSONDecoder().decode([String].self, from: raw)
                guard paths.count <= 2000 else { throw NativeHubError.invalidInput("Compare at most 2000 staged paths.") }
                var comparison = NativePathComparison(paths: paths, destination: value("--destination"))
                for entry in try await hub.tree(repo: repo, recursive: true) {
                    try Task.checkCancellation()
                    comparison.observe(path: entry.path, isDirectory: entry.isDirectory)
                }
                data = try encoded(comparison.result(complete: true))
            default: throw NativeHubError.invalidInput("Unsupported repository operation.")
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }
}
