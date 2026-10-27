import Foundation
import CryptoKit

public struct NativeHubIdentity: Sendable, Equatable {
    public let name: String
    public let organizations: [String]
}

public struct NativeHubEntry: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let gitBlobOID: String?
    public let lfsSHA256: String?
    /// Opaque storage identity; it is not a SHA-256 content hash.
    public let xetHash: String?
    public init(path: String, size: Int64, isDirectory: Bool, gitBlobOID: String? = nil,
                lfsSHA256: String? = nil, xetHash: String? = nil) {
        self.path = path; self.size = size; self.isDirectory = isDirectory
        self.gitBlobOID = gitBlobOID; self.lfsSHA256 = lfsSHA256; self.xetHash = xetHash
    }
}

public struct NativeUploadDescriptor: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let sha256: String
    public let sample: Data
    public init(path: String, size: Int64, sha256: String, sample: Data) {
        self.path = path; self.size = size; self.sha256 = sha256; self.sample = sample
    }
}

public enum NativeUploadMode: String, Sendable { case regular, lfs, ignored }

public struct NativeCommitFile: Sendable {
    public let descriptor: NativeUploadDescriptor
    /// nil means an LFS object; non-nil is the complete regular-file content.
    public let content: Data?
    public init(descriptor: NativeUploadDescriptor, content: Data? = nil) {
        self.descriptor = descriptor; self.content = content
    }
}

public struct NativeCommitResult: Sendable, Equatable {
    public let commitOID: String
    public let url: URL
}

public enum NativeHubError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput(String)
    case invalidResponse(String)
    case responseTooLarge
    case http(status: Int, message: String)
    case network(code: Int)
    case unsafeURL
    case sourceChanged
    case entryNotFound
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let value), .invalidResponse(let value): return value
        case .responseTooLarge: return "The Hub response exceeded the safety limit. Narrow the requested folder."
        case .http(let status, let message): return "Hub HTTP \(status): \(message)"
        case .network(let code): return "The network request failed (URLSession error \(code)). Retry when the connection is available."
        case .unsafeURL: return "The server supplied an unsupported or unsafe network address."
        case .sourceChanged: return "A source file changed during upload. Scan the folder and retry."
        case .entryNotFound: return "The requested repository path does not exist."
        }
    }
}

struct NativeHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
}

protocol NativeHTTPTransport: Sendable {
    func execute(_ request: URLRequest, uploadFile: URL?, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> NativeHTTPResponse
}

/// Response data is bounded while arriving, including responses to file uploads.
/// File bodies are streamed by URLSession, never collected into a Data object.
final class NativeURLSessionTransport: NSObject, NativeHTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<NativeHTTPResponse, any Error>
        let onBytes: @Sendable (Int64) -> Void
        var response: HTTPURLResponse?
        var data = Data()
        var failure: NativeHubError?
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maximumResponseBytes: Int
    private let configuration: URLSessionConfiguration
    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: NativeURLSessionTransport?
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let owner else { completionHandler(.cancel); return }
            owner.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { owner?.urlSession(session, dataTask: dataTask, didReceive: data) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            owner?.urlSession(session, task: task, didSendBodyData: bytesSent, totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) { owner?.urlSession(session, task: task, didCompleteWithError: error) }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let owner else { completionHandler(nil); return }
            owner.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
        }
    }
    private let delegate = Delegate()
    private lazy var session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    init(maximumResponseBytes: Int = 8 * 1024 * 1024, configuration: URLSessionConfiguration = .ephemeral) {
        self.maximumResponseBytes = maximumResponseBytes
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        self.configuration = configuration
        super.init()
        delegate.owner = self
        // Initialize before concurrent execute calls; URLSession itself is thread safe.
        _ = session
    }
    deinit { session.invalidateAndCancel() }

    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var task: URLSessionTask?
        func install(_ value: URLSessionTask) {
            lock.lock(); task = value; let stop = cancelled; lock.unlock()
            if stop { value.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let value = task; lock.unlock(); value?.cancel()
        }
    }

    func execute(_ request: URLRequest, uploadFile: URL?, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> NativeHTTPResponse {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task: URLSessionTask
                if let uploadFile { task = session.uploadTask(with: request, fromFile: uploadFile) }
                else if let body = request.httpBody {
                    var upload = request; upload.httpBody = nil
                    task = session.uploadTask(with: upload, from: body)
                }
                else { task = session.dataTask(with: request) }
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation, onBytes: onBytes)
                lock.unlock()
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard var value = pending[dataTask.taskIdentifier] else { lock.unlock(); completionHandler(.cancel); return }
        value.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maximumResponseBytes) { value.failure = .responseTooLarge }
        pending[dataTask.taskIdentifier] = value
        let cancel = value.failure != nil
        lock.unlock()
        completionHandler(cancel ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var value = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        if data.count > maximumResponseBytes - value.data.count { value.failure = .responseTooLarge }
        else { value.data.append(data) }
        pending[dataTask.taskIdentifier] = value
        let cancel = value.failure != nil
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let callback = pending[task.taskIdentifier]?.onBytes; lock.unlock()
        callback?(totalBytesSent)
    }

    static func redirectedRequest(from original: URLRequest?, to request: URLRequest) -> URLRequest? {
        guard let target = request.url, NativeHubClient.isSafeHTTPS(target) else { return nil }
        var next = request
        if original?.url.map({ NativeHubClient.sameOrigin($0, target) }) != true {
            // Only preserve innocuous representation headers across origins. Never
            // forward Hub tokens, provider action credentials, or cookies elsewhere.
            let allowed = Set(["accept", "content-type", "content-length", "user-agent", "accept-encoding"])
            for name in next.allHTTPHeaderFields?.keys.map({ $0 }) ?? [] where !allowed.contains(name.lowercased()) {
                next.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let next = Self.redirectedRequest(from: task.currentRequest, to: request)
        if next == nil {
            lock.lock(); pending[task.taskIdentifier]?.failure = .unsafeURL; lock.unlock()
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let value = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let value else { return }
        // Observe the task's actual final body count, including brief or failed sends
        // that did not produce an intermediate progress callback. Never infer from size.
        value.onBytes(task.countOfBytesSent)
        if let failure = value.failure { value.continuation.resume(throwing: failure); return }
        if let error {
            let code = (error as NSError).code
            value.continuation.resume(throwing: code == NSURLErrorCancelled ? CancellationError() : NativeHubError.network(code: code))
            return
        }
        guard let response = value.response else {
            value.continuation.resume(throwing: NativeHubError.invalidResponse("The server did not return an HTTP response.")); return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
        value.continuation.resume(returning: NativeHTTPResponse(status: response.statusCode, headers: headers, data: value.data))
    }
}

/// Native Hub/LFS client. Successful commits require a returned commit OID.
/// Only reads, preupload/LFS negotiation, and idempotent PUTs receive bounded retries.
public final class NativeHubClient: Sendable {
    public let endpoint: URL
    private let token: String?
    private let transport: any NativeHTTPTransport
    private let retryDelay: Duration
    private let onTransferEvent: @Sendable (NativeTransferEvent) -> Void
    public init(token: String?, endpoint: URL = URL(string: "https://huggingface.co")!,
                onTransferEvent: @escaping @Sendable (NativeTransferEvent) -> Void = { _ in }) {
        self.token = token; self.endpoint = endpoint
        transport = NativeURLSessionTransport(); retryDelay = .seconds(1)
        self.onTransferEvent = onTransferEvent
    }
    init(token: String?, endpoint: URL = URL(string: "https://huggingface.co")!, transport: any NativeHTTPTransport, retryDelay: Duration = .zero,
         onTransferEvent: @escaping @Sendable (NativeTransferEvent) -> Void = { _ in }) {
        self.token = token; self.endpoint = endpoint; self.transport = transport; self.retryDelay = retryDelay
        self.onTransferEvent = onTransferEvent
    }

    static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
    private func route(_ parts: [String], query: [URLQueryItem] = []) throws -> URL {
        guard Self.isSafeHTTPS(endpoint), endpoint.query == nil, endpoint.path.isEmpty || endpoint.path == "/" else { throw NativeHubError.unsafeURL }
        var url = endpoint
        for part in parts { url.appendPathComponent(part) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
    private func repoParts(_ repo: HubRepo) throws -> [String] {
        let parts = repo.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil && $0 != "." && $0 != ".." }) else {
            throw NativeHubError.invalidInput("Use a repository ID such as username/my-model.")
        }
        return parts
    }
    static func validatePath(_ path: String, allowEmpty: Bool = false) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (allowEmpty && path.isEmpty) || (!path.isEmpty && !path.contains("\\") && path.rangeOfCharacter(from: .controlCharacters) == nil && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })) else {
            throw NativeHubError.invalidInput("Use a relative repository path without empty, '.' or '..' components.")
        }
    }
    private func descriptorCheck(_ file: NativeUploadDescriptor) throws {
        try Self.validatePath(file.path)
        guard file.size >= 0, file.sample.count <= 512, file.sample.count <= file.size,
              file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw NativeHubError.invalidInput("Invalid file size, sample, or SHA-256 descriptor.")
        }
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeHubError.invalidResponse("Malformed Hub response.") }
        return value
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String = "application/json", headers: [String: String] = [:], hubAuth: Bool = true, retryable: Bool = false, uploadFile: URL? = nil, bodyKind: TransferBodyKind = .metadata, onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) async throws -> NativeHTTPResponse {
        guard Self.isSafeHTTPS(url), !hubAuth || Self.sameOrigin(url, endpoint) else { throw NativeHubError.unsafeURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("FaceHugger/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil || uploadFile != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (key, value) in headers {
            guard key.rangeOfCharacter(from: .controlCharacters) == nil, value.rangeOfCharacter(from: .controlCharacters) == nil,
                  !["host", "cookie", "proxy-authorization", "content-length"].contains(key.lowercased()) else { throw NativeHubError.unsafeURL }
            if let token, !token.isEmpty, value.contains(token), !Self.sameOrigin(url, endpoint) { throw NativeHubError.unsafeURL }
            request.setValue(value, forHTTPHeaderField: key)
        }
        if hubAuth, let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let id = UUID(), maximum = retryable ? 3 : 1
        let observe = onTransferEvent
        for attempt in 1...maximum {
            try Task.checkCancellation()
            let info = TransferRequest(id: id, attempt: attempt, maximumAttempts: maximum, bodyKind: bodyKind)
            observe(.started(info))
            let response: NativeHTTPResponse
            do {
                response = try await transport.execute(request, uploadFile: uploadFile) { bytes in
                    observe(.bodyBytes(requestID: id, attempt: attempt, cumulative: bytes))
                    onBytes(bytes)
                }
            } catch {
                observe(.finished(requestID: id, attempt: attempt))
                guard case NativeHubError.network(let code) = error, retryable, attempt < maximum,
                      [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost,
                       NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed].contains(code) else { throw error }
                let delay = TransferRetryPolicy.delay(base: retryDelay, failedAttempt: attempt, header: nil, now: Date())
                try await waitToRetry(info, reason: code == NSURLErrorTimedOut ? .timeout : .connection, delay: delay)
                continue
            }
            observe(.finished(requestID: id, attempt: attempt))
            try Task.checkCancellation()
            if (200..<300).contains(response.status) { return response }
            if response.status == 404 && response.header("X-Error-Code") == "EntryNotFound" { throw NativeHubError.entryNotFound }
            if retryable && attempt < maximum && ([408, 429].contains(response.status) || (500...599).contains(response.status)) {
                let delay = TransferRetryPolicy.delay(base: retryDelay, failedAttempt: attempt,
                                                     header: response.header("Retry-After"), now: Date())
                let reason: TransferRetryReason = response.status == 429 ? .rateLimit : response.status == 408 ? .timeout : .serverError
                try await waitToRetry(info, reason: reason, delay: delay)
                continue
            }
            let message: String
            switch response.status {
            case 401: message = "Authentication failed. Check your Hugging Face token."
            case 403: message = "Permission denied. Check the token's repository access."
            case 404: message = "The repository or path was not found, or access is unavailable."
            case 409: message = "The repository changed or the operation conflicts with existing content."
            case 429: message = "The service rate limit was reached. Try again later."
            default: message = "The service rejected the request."
            }
            throw NativeHubError.http(status: response.status, message: message)
        }
        throw NativeHubError.invalidResponse("The request did not complete.")
    }

    private func waitToRetry(_ request: TransferRequest, reason: TransferRetryReason, delay: Duration) async throws {
        let retry = TransferRetry(request: request, reason: reason,
            resumesAt: Date().addingTimeInterval(TransferRetryPolicy.seconds(delay)))
        onTransferEvent(.waiting(retry))
        do { try await Task.sleep(for: delay) }
        catch {
            onTransferEvent(.waitCancelled(requestID: request.id, attempt: request.attempt))
            throw error
        }
    }

    public func whoami() async throws -> NativeHubIdentity {
        let response = try await request(route(["api", "whoami-v2"]), retryable: true)
        let value = try object(response.data)
        guard let name = value["name"] as? String, !name.isEmpty else { throw NativeHubError.invalidResponse("The identity response has no account name.") }
        let organizations = (value["orgs"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return NativeHubIdentity(name: name, organizations: organizations)
    }

    private func pages(_ initial: URL, expectedPath: String? = nil) async throws -> [[String: Any]] {
        var next: URL? = initial
        var visited = Set<URL>()
        var rows: [[String: Any]] = []
        var received = 0
        while let url = next {
            try Task.checkCancellation()
            guard Self.sameOrigin(url, endpoint), url.path.hasPrefix("/api/"), visited.insert(url).inserted, visited.count <= 1000 else { throw NativeHubError.invalidResponse("Unsafe or cyclic Hub pagination.") }
            if let expectedPath, Data(url.path.utf8) != Data(expectedPath.utf8) {
                throw NativeHubError.invalidResponse("Repository pagination changed the requested path or revision.")
            }
            let response = try await request(url, retryable: true)
            received += response.data.count
            guard received <= 32 * 1024 * 1024 else { throw NativeHubError.responseTooLarge }
            guard let page = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw NativeHubError.invalidResponse("Malformed paginated Hub response.") }
            guard page.count <= 100_000 - rows.count else { throw NativeHubError.responseTooLarge }
            rows.append(contentsOf: page)
            next = try Self.nextPage(response.header("Link"), relativeTo: url)
        }
        return rows
    }

    static func nextPage(_ link: String?, relativeTo url: URL) throws -> URL? {
        guard let link else { return nil }
        var found: URL?
        // Hub links are URI references enclosed in angle brackets; commas inside
        // those brackets must not be mistaken for separators.
        let regex = try NSRegularExpression(pattern: #"<([^>]*)>\s*;\s*rel\s*=\s*"?next"?(?:\s*;[^,]*)?(?=,|$)"#)
        let source = link as NSString
        for match in regex.matches(in: link, range: NSRange(location: 0, length: source.length)) {
            guard found == nil, let target = URL(string: source.substring(with: match.range(at: 1)), relativeTo: url)?.absoluteURL,
                  Self.isSafeHTTPS(target), Self.sameOrigin(target, url) else { throw NativeHubError.invalidResponse("Unsafe Hub pagination link.") }
            found = target
        }
        if found == nil && link.contains("next") { throw NativeHubError.invalidResponse("Malformed Hub pagination link.") }
        return found
    }

    public func repos(owner: String) async throws -> [HubRepo] {
        guard owner.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { throw NativeHubError.invalidInput("Invalid repository owner.") }
        var result: [HubRepo] = []
        for kind in RepoKind.allCases {
            let rows = try await pages(route(["api", kind.plural], query: [.init(name: "author", value: owner), .init(name: "limit", value: "100")]))
            for row in rows {
                guard let id = row["id"] as? String, let privacy = row["private"] as? Bool else { throw NativeHubError.invalidResponse("Malformed repository listing.") }
                result.append(HubRepo(name: id, kind: kind, isPrivate: privacy))
            }
        }
        return result
    }

    public func info(repo: HubRepo) async throws -> HubRepo {
        let response = try await request(route(["api", repo.kind.plural] + repoParts(repo)), retryable: true)
        let value = try object(response.data)
        guard let id = value["id"] as? String, id == repo.name, let privacy = value["private"] as? Bool else { throw NativeHubError.invalidResponse("Malformed repository information.") }
        return HubRepo(name: id, kind: repo.kind, isPrivate: privacy)
    }

    public func headCommit(repo: HubRepo) async throws -> String? {
        let response = try await request(route(["api", repo.kind.plural] + repoParts(repo)), retryable: true)
        let value = try object(response.data)
        guard value["id"] as? String == repo.name else { throw NativeHubError.invalidResponse("Repository identity changed.") }
        guard let sha = value["sha"], !(sha is NSNull) else { return nil }
        guard let oid = sha as? String, Self.isFullOID(oid) else { throw NativeHubError.invalidResponse("Invalid branch revision.") }
        return oid
    }

    public func tree(repo: HubRepo, path: String = "", recursive: Bool = false, allowMissingPath: Bool = false,
                     revision: String = "main") async throws -> [NativeHubEntry] {
        try Self.validatePath(path, allowEmpty: true)
        try Self.validateTreeRevision(revision)
        if allowMissingPath && !path.isEmpty { _ = try await info(repo: repo) }
        let url = try route(["api", repo.kind.plural] + repoParts(repo) + ["tree", revision] + path.split(separator: "/").map(String.init), query: [.init(name: "recursive", value: recursive ? "true" : "false"), .init(name: "expand", value: "false")])
        let rows: [[String: Any]]
        do { rows = try await pages(url, expectedPath: url.path) }
        catch NativeHubError.entryNotFound where allowMissingPath && !path.isEmpty {
            // Confirm the repository still exists: a removed/private repo is not
            // an empty destination. Only path absence may be treated as empty.
            _ = try await info(repo: repo)
            return []
        }
        return try rows.map(Self.treeEntry)
    }

    private static func validateTreeRevision(_ revision: String) throws {
        guard revision == "main" || isFullOID(revision) else {
            throw NativeHubError.invalidInput("Use main or a complete commit revision for repository comparison.")
        }
    }
    private static func isFullOID(_ value: String) -> Bool {
        value.range(of: "^(?:[a-fA-F0-9]{40}|[a-fA-F0-9]{64})$", options: .regularExpression) != nil
    }
    private static func treeEntry(_ row: [String: Any]) throws -> NativeHubEntry {
        guard let path = row["path"] as? String, let type = row["type"] as? String,
              ["file", "directory"].contains(type) else { throw NativeHubError.invalidResponse("Malformed repository tree entry.") }
        try validatePath(path)
        let size = (row["size"] as? NSNumber)?.int64Value ?? 0
        guard size >= 0 else { throw NativeHubError.invalidResponse("Invalid remote file size.") }
        var blob: String?, lfs: String?
        if type == "file" {
            if let raw = row["oid"], !(raw is NSNull) {
                guard let value = raw as? String, isFullOID(value) else { throw NativeHubError.invalidResponse("Invalid Git blob identity.") }
                blob = value.lowercased()
            }
            if let raw = row["lfs"], !(raw is NSNull) {
                guard let value = raw as? [String: Any], let hash = value["oid"] as? String,
                      hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
                    throw NativeHubError.invalidResponse("Invalid LFS content identity.")
                }
                lfs = hash.lowercased()
            }
        }
        return NativeHubEntry(path: path, size: size, isDirectory: type == "directory",
                              gitBlobOID: blob, lfsSHA256: lfs, xetHash: row["xetHash"] as? String)
    }

    /// Full recursive preflight without accumulating entries in memory. Each page
    /// remains bounded. Cyclic pagination fails, and cancellation propagates.
    public func streamTree(repo: HubRepo, path: String = "", recursive: Bool = true, onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws {
        try await streamTree(repo: repo, path: path, recursive: recursive, revision: "main", onEntry: onEntry)
    }

    public func streamTree(repo: HubRepo, path: String = "", recursive: Bool = true, revision: String,
                           onEntry: @escaping @Sendable (NativeHubEntry) async throws -> Void) async throws {
        try Self.validatePath(path, allowEmpty: true)
        try Self.validateTreeRevision(revision)
        let initial = try route(["api", repo.kind.plural] + repoParts(repo) + ["tree", revision] + path.split(separator: "/").map(String.init), query: [.init(name: "recursive", value: recursive ? "true" : "false"), .init(name: "expand", value: "false")])
        var next: URL? = initial
        var visited = Set<URL>()
        while let url = next {
            try Task.checkCancellation()
            guard Self.sameOrigin(url, endpoint), url.path.hasPrefix("/api/"), visited.insert(url).inserted else { throw NativeHubError.invalidResponse("Unsafe or cyclic Hub pagination.") }
            guard Data(url.path.utf8) == Data(initial.path.utf8) else { throw NativeHubError.invalidResponse("Repository pagination changed the requested path or revision.") }
            let response = try await request(url, retryable: true)
            guard let rows = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw NativeHubError.invalidResponse("Malformed repository tree page.") }
            for row in rows {
                try Task.checkCancellation()
                try await onEntry(Self.treeEntry(row))
            }
            next = try Self.nextPage(response.header("Link"), relativeTo: url)
        }
    }

    public func create(repo: HubRepo) async throws -> HubRepo {
        let parts = try repoParts(repo)
        let body = try json(["name": parts[1], "organization": parts[0], "type": repo.kind.rawValue, "private": repo.isPrivate] as [String: Any])
        _ = try await request(route(["api", "repos", "create"]), method: "POST", body: body)
        return try await info(repo: repo)
    }

    public func deleteFile(repo: HubRepo, path: String) async throws -> NativeCommitResult {
        try await commit(repo: repo, additions: [], deletions: [path], message: "Delete file with Face Hugger")
    }

    public func preupload(repo: HubRepo, files: [NativeUploadDescriptor]) async throws -> [Data: NativeUploadMode] {
        guard files.count <= 256 else { throw NativeHubError.invalidInput("Preupload batches are limited to 256 files.") }
        var expected: [Data: NativeUploadDescriptor] = [:]
        for file in files {
            try descriptorCheck(file)
            guard expected.updateValue(file, forKey: Data(file.path.utf8)) == nil else { throw NativeHubError.invalidInput("Duplicate upload path.") }
        }
        if files.isEmpty { return [:] }
        let body = try json(["files": files.map { ["path": $0.path, "size": $0.size, "sample": $0.sample.base64EncodedString()] as [String: Any] }])
        let response = try await request(route(["api", repo.kind.plural] + repoParts(repo) + ["preupload", "main"]), method: "POST", body: body, retryable: true)
        guard let entries = try object(response.data)["files"] as? [[String: Any]], entries.count == files.count else { throw NativeHubError.invalidResponse("Preupload response omitted file decisions.") }
        var result: [Data: NativeUploadMode] = [:]
        for entry in entries {
            guard let path = entry["path"] as? String, let file = expected[Data(path.utf8)], let modeString = entry["uploadMode"] as? String,
                  let mode = NativeUploadMode(rawValue: modeString), mode != .ignored, let ignored = entry["shouldIgnore"] as? Bool, result[Data(path.utf8)] == nil else { throw NativeHubError.invalidResponse("Malformed preupload file decision.") }
            result[Data(path.utf8)] = ignored ? .ignored : (file.size == 0 ? .regular : mode)
        }
        return result
    }

    public func uploadLFS(repo: HubRepo, file: URL, descriptor: NativeUploadDescriptor, onBytes: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        try descriptorCheck(descriptor)
        guard descriptor.size > 0, file.isFileURL else { throw NativeHubError.invalidInput("LFS requires a nonempty local file.") }
        let before = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard before.isRegularFile == true, Int64(before.fileSize ?? -1) == descriptor.size else { throw NativeHubError.sourceChanged }
        var parts = try repoParts(repo)
        parts[1] += ".git"
        if repo.kind == .dataset { parts.insert("datasets", at: 0) }
        let body = try json(["operation": "upload", "transfers": ["basic", "multipart"], "objects": [["oid": descriptor.sha256, "size": descriptor.size]], "hash_algo": "sha256", "ref": ["name": "main"]] as [String: Any])
        let response = try await request(route(parts + ["info", "lfs", "objects", "batch"]), method: "POST", body: body, contentType: "application/vnd.git-lfs+json", headers: ["Accept": "application/vnd.git-lfs+json"], retryable: true)
        guard let objects = try object(response.data)["objects"] as? [[String: Any]], objects.count == 1, let item = objects.first,
              item["oid"] as? String == descriptor.sha256, (item["size"] as? NSNumber)?.int64Value == descriptor.size else { throw NativeHubError.invalidResponse("LFS batch returned a different object.") }
        guard item["error"] == nil else { throw NativeHubError.invalidResponse("The Hub rejected the LFS object. Check repository access and storage limits.") }
        if item["actions"] == nil || item["actions"] is NSNull { return }
        guard let actions = item["actions"] as? [String: Any], let upload = actions["upload"] as? [String: Any] else { throw NativeHubError.invalidResponse("LFS batch omitted upload instructions.") }
        let (uploadURL, headers) = try action(upload)
        if let chunkText = headers["chunk_size"] {
            guard let chunkSize = Int64(chunkText), chunkSize > 0, chunkSize <= 5 * 1024 * 1024 * 1024 else { throw NativeHubError.invalidResponse("Invalid multipart chunk size.") }
            let expectedParts = (descriptor.size - 1) / chunkSize + 1
            guard expectedParts <= 10_000 else { throw NativeHubError.invalidResponse("Too many multipart pieces.") }
            let numbered = headers.compactMap { key, value -> (Int, URL)? in
                guard let number = Int(key), let url = URL(string: value) else { return nil }
                return (number, url)
            }.sorted { $0.0 < $1.0 }
            guard numbered.count == expectedParts, numbered.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 && Self.isSafeHTTPS($0.element.1) }) else { throw NativeHubError.invalidResponse("Multipart instructions have missing or unsafe parts.") }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("face-hugger-part-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            var completed: Int64 = 0
            var completions: [[String: Any]] = []
            for (number, url) in numbered {
                try Task.checkCancellation()
                let length = min(chunkSize, descriptor.size - completed)
                let part = temporary.appendingPathComponent("part")
                FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let output = try FileHandle(forWritingTo: part)
                do {
                    var remaining = length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                        guard !data.isEmpty else { throw NativeHubError.sourceChanged }
                        try output.write(contentsOf: data); remaining -= Int64(data.count)
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                let offset = completed
                let partResponse = try await request(url, method: "PUT", contentType: "application/octet-stream", hubAuth: false, retryable: true, uploadFile: part, bodyKind: .file) { sent in onBytes(offset + min(length, sent)) }
                guard let etag = partResponse.header("ETag"), !etag.isEmpty else { throw NativeHubError.invalidResponse("The storage service omitted a multipart ETag.") }
                completions.append(["partNumber": number, "etag": etag])
                completed += length; onBytes(completed)
                try FileManager.default.removeItem(at: part)
            }
            let completion = try json(["oid": descriptor.sha256, "parts": completions])
            _ = try await request(uploadURL, method: "POST", body: completion, hubAuth: Self.sameOrigin(uploadURL, endpoint))
        } else {
            _ = try await request(uploadURL, method: "PUT", contentType: "application/octet-stream", headers: headers, hubAuth: false, retryable: true, uploadFile: file, bodyKind: .file) { sent in onBytes(min(descriptor.size, sent)) }
        }
        if let rawVerify = actions["verify"], !(rawVerify is NSNull) {
            guard let verify = rawVerify as? [String: Any] else { throw NativeHubError.invalidResponse("Malformed LFS verification instructions.") }
            let (url, headers) = try action(verify)
            _ = try await request(url, method: "POST", body: json(["oid": descriptor.sha256, "size": descriptor.size]), headers: headers, hubAuth: Self.sameOrigin(url, endpoint), retryable: true)
        }
        let after = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw NativeHubError.sourceChanged }
    }

    private func action(_ value: [String: Any]) throws -> (URL, [String: String]) {
        guard let href = value["href"] as? String, let url = URL(string: href), Self.isSafeHTTPS(url) else { throw NativeHubError.invalidResponse("LFS action has an unsafe address.") }
        if let raw = value["header"], !(raw is NSNull) {
            guard let headers = raw as? [String: String] else { throw NativeHubError.invalidResponse("Malformed LFS action headers.") }
            return (url, headers)
        }
        return (url, [:])
    }

    public func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String] = [], message: String = "Upload files with Face Hugger") async throws -> NativeCommitResult {
        try await commitRequest(repo: repo, additions: additions, deletions: deletions, message: message, expectedParent: nil)
    }

    public func commit(repo: HubRepo, additions: [NativeCommitFile], deletions: [String] = [],
                       message: String = "Upload files with Face Hugger", expectedParent: String) async throws -> NativeCommitResult {
        guard Self.isFullOID(expectedParent) else { throw NativeHubError.invalidInput("The expected parent must be a complete commit revision.") }
        return try await commitRequest(repo: repo, additions: additions, deletions: deletions, message: message, expectedParent: expectedParent)
    }

    private func commitRequest(repo: HubRepo, additions: [NativeCommitFile], deletions: [String], message: String,
                               expectedParent: String?) async throws -> NativeCommitResult {
        guard !additions.isEmpty || !deletions.isEmpty, additions.count + deletions.count <= 256, message.utf8.count <= 1024 else { throw NativeHubError.invalidInput("Commit batches must contain 1 to 256 changes and a short message.") }
        var header = ["summary": message, "description": ""]
        if let expectedParent { header["parentCommit"] = expectedParent }
        var body = try json(["key": "header", "value": header]); body.append(10)
        var paths = Set<Data>()
        for file in additions {
            try descriptorCheck(file.descriptor)
            guard paths.insert(Data(file.descriptor.path.utf8)).inserted else { throw NativeHubError.invalidInput("Duplicate commit path.") }
            let line: [String: Any]
            if let content = file.content {
                guard content.count <= 16 * 1024 * 1024, Int64(content.count) == file.descriptor.size,
                      SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == file.descriptor.sha256 else { throw NativeHubError.sourceChanged }
                line = ["key": "file", "value": ["path": file.descriptor.path, "encoding": "base64", "content": content.base64EncodedString()]]
            } else {
                line = ["key": "lfsFile", "value": ["path": file.descriptor.path, "algo": "sha256", "oid": file.descriptor.sha256, "size": file.descriptor.size]]
            }
            body.append(try json(line)); body.append(10)
            guard body.count <= 24 * 1024 * 1024 else { throw NativeHubError.invalidInput("The commit payload is too large. Use a smaller batch.") }
        }
        for path in deletions {
            try Self.validatePath(path)
            guard paths.insert(Data(path.utf8)).inserted else { throw NativeHubError.invalidInput("Conflicting commit paths.") }
            body.append(try json(["key": "deletedFile", "value": ["path": path]])); body.append(10)
        }
        let response = try await request(route(["api", repo.kind.plural] + repoParts(repo) + ["commit", "main"]), method: "POST", body: body, contentType: "application/x-ndjson", bodyKind: .commit)
        let value = try object(response.data)
        guard let oid = value["commitOid"] as? String, Self.isFullOID(oid) else { throw NativeHubError.invalidResponse("The commit was not acknowledged with a valid revision. Refresh the repository before retrying.") }
        let url = try route((repo.kind == .dataset ? ["datasets"] : []) + repoParts(repo) + ["commit", oid])
        return NativeCommitResult(commitOID: oid, url: url)
    }
}
