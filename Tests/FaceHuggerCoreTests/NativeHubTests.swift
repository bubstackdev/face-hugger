import Foundation
import CryptoKit
import XCTest
@testable import FaceHuggerCore

private actor HubMock: NativeHTTPTransport {
    struct Call: Sendable { let request: URLRequest; let upload: Data? }
    var replies: [NativeHTTPResponse]
    private(set) var calls: [Call] = []
    init(_ replies: [NativeHTTPResponse]) { self.replies = replies }
    func execute(_ request: URLRequest, uploadFile: URL?, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> NativeHTTPResponse {
        let bytes = try uploadFile.map { try Data(contentsOf: $0) }
        calls.append(Call(request: request, upload: bytes))
        if let sent = bytes ?? request.httpBody { onBytes(Int64(sent.count)) }
        guard !replies.isEmpty else { throw NativeHubError.invalidResponse("Unexpected test request") }
        return replies.removeFirst()
    }
}
private final class TransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = TransferTransportTracker()
    private var logicalBytes: Int64 = 0
    let onWait: (@Sendable () -> Void)?
    init(onWait: (@Sendable () -> Void)? = nil) { self.onWait = onWait }
    func record(_ event: NativeTransferEvent) {
        lock.lock(); tracker.apply(event, at: ProcessInfo.processInfo.systemUptime); lock.unlock()
        if case .waiting = event { onWait?() }
    }
    func logical(_ bytes: Int64) { lock.lock(); logicalBytes = max(logicalBytes, bytes); lock.unlock() }
    var summary: TransferTransportSummary { lock.lock(); defer { lock.unlock() }; return tracker.summary }
    var progress: Int64 { lock.lock(); defer { lock.unlock() }; return logicalBytes }
}
private actor TreeEntries {
    var values: [NativeHubEntry] = []
    func append(_ entry: NativeHubEntry) { values.append(entry) }
}
private actor PartialSendMock: NativeHTTPTransport {
    let responses: [NativeHTTPResponse]
    private var index = 0
    init(_ responses: [NativeHTTPResponse]) { self.responses = responses }
    func execute(_ request: URLRequest, uploadFile: URL?, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> NativeHTTPResponse {
        if let uploadFile {
            let count = try Data(contentsOf: uploadFile).count
            if index == 1 {
                index += 1; onBytes(2)
                throw NativeHubError.network(code: NSURLErrorNetworkConnectionLost)
            }
            onBytes(Int64(count))
        } else if let body = request.httpBody { onBytes(Int64(body.count)) }
        defer { index += 1 }
        return responses[index]
    }
}
private final class LargeResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 64))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
final class NativeHubTests: XCTestCase, @unchecked Sendable {
    let repo = HubRepo(name: "owner/repo", kind: .dataset, isPrivate: true)
    func reply(_ object: Any, status: Int = 200, headers: [String:String] = [:]) throws -> NativeHTTPResponse {
        NativeHTTPResponse(status: status, headers: headers, data: try JSONSerialization.data(withJSONObject: object))
    }
    func file(_ bytes: Data, path: String = "folder/ü space.bin") -> NativeUploadDescriptor {
        NativeUploadDescriptor(path: path, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sample: Data(bytes.prefix(512)))
    }
    func testRedirectStripsCredentialsAndRejectsDowngrade() throws {
        var original = URLRequest(url: URL(string: "https://huggingface.co/path")!)
        original.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        var next = original; next.url = URL(string: "https://storage.example/file")!
        next.setValue("secret", forHTTPHeaderField: "X-Provider-Token")
        next.setValue("secret", forHTTPHeaderField: "Cookie")
        next.setValue("application/json", forHTTPHeaderField: "Accept")
        let safe = try XCTUnwrap(NativeURLSessionTransport.redirectedRequest(from: original, to: next))
        for header in ["Authorization", "X-Provider-Token", "Cookie"] { XCTAssertNil(safe.value(forHTTPHeaderField: header)) }
        XCTAssertEqual(safe.value(forHTTPHeaderField: "Accept"), "application/json")
        next.url = URL(string: "http://huggingface.co/path")!
        XCTAssertNil(NativeURLSessionTransport.redirectedRequest(from: original, to: next))
        next.url = URL(string: "https://huggingface.co:444/path")!
        XCTAssertNil(NativeURLSessionTransport.redirectedRequest(from: original, to: next)?.value(forHTTPHeaderField: "Authorization"))
    }
    func testPaginationHandlesCommaAndRejectsForeignOrigin() throws {
        let url = URL(string: "https://huggingface.co/api/models")!
        XCTAssertEqual(try NativeHubClient.nextPage("<?cursor=a,b>; rel=\"next\"", relativeTo: url)?.query, "cursor=a,b")
        XCTAssertThrowsError(try NativeHubClient.nextPage("<https://evil.example/>; rel=next", relativeTo: url))
        XCTAssertThrowsError(try NativeHubClient.nextPage("<http://huggingface.co/api>; rel=next", relativeTo: url))
    }
    func testSafeReadsRetryAndErrorsDoNotEchoSecrets() async throws {
        let mock = HubMock([try reply([:], status: 503), try reply(["name":"owner", "orgs":[["name":"team"]]])])
        let identity = try await NativeHubClient(token: "hf_secret", transport: mock).whoami()
        XCTAssertEqual(identity.name, "owner"); XCTAssertEqual(identity.organizations, ["team"])
        let calls = await mock.calls; XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_secret")
        let bad = HubMock([try reply(["error":"hf_secret signed?secret=yes"], status: 403)])
        do { _ = try await NativeHubClient(token: "hf_secret", transport: bad).whoami(); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
    func testReposFollowAllPages() async throws {
        let mock = HubMock([try reply([["id":"owner/a", "private":true]], headers:["Link":"<?cursor=2>; rel=\"next\""]), try reply([["id":"owner/b", "private":false]]), try reply([["id":"owner/c", "private":true]])])
        let repos = try await NativeHubClient(token: nil, transport: mock).repos(owner: "owner")
        XCTAssertEqual(repos.map(\.name), ["owner/a", "owner/b", "owner/c"])
        XCTAssertEqual(repos.map(\.kind), [.model, .model, .dataset])
    }
    func testOnlyEntryNotFoundBecomesEmptyDestination() async throws {
        let info: [String:Any] = ["id":repo.name, "private":true]
        let mock = HubMock([try reply(info), try reply([:], status:404, headers:["X-Error-Code":"EntryNotFound"]), try reply(info)])
        let tree = try await NativeHubClient(token:nil, transport:mock).tree(repo:repo, path:"new", allowMissingPath:true)
        XCTAssertTrue(tree.isEmpty)
        let bad = HubMock([try reply(info), try reply([:], status:404)])
        do { _ = try await NativeHubClient(token:nil, transport:bad).tree(repo:repo, path:"new", allowMissingPath:true); XCTFail() }
        catch NativeHubError.http(let code, _) { XCTAssertEqual(code,404) }
    }
    func testPreuploadPreservesByteDistinctUnicodeNames() async throws {
        let a = file(Data("a".utf8), path:"é.bin"), b = file(Data("b".utf8), path:"e\u{301}.bin")
        XCTAssertEqual(a.path,b.path); XCTAssertNotEqual(Data(a.path.utf8),Data(b.path.utf8))
        let mock = HubMock([try reply(["files":[["path":a.path,"uploadMode":"regular","shouldIgnore":false],["path":b.path,"uploadMode":"lfs","shouldIgnore":false]]])])
        let modes = try await NativeHubClient(token:nil,transport:mock).preupload(repo:repo,files:[a,b])
        XCTAssertEqual(modes.count,2); XCTAssertEqual(modes[Data(a.path.utf8)],.regular); XCTAssertEqual(modes[Data(b.path.utf8)],.lfs)
        let missing = HubMock([try reply(["files":[]])])
        do { _ = try await NativeHubClient(token:nil,transport:missing).preupload(repo:repo,files:[a]); XCTFail() }
        catch NativeHubError.invalidResponse { }
    }
    func testEmptyPreuploadIsRegular() async throws {
        let empty = file(Data(),path:"empty")
        let mock = HubMock([try reply(["files":[["path":"empty","uploadMode":"lfs","shouldIgnore":false]]])])
        let modes = try await NativeHubClient(token:nil,transport:mock).preupload(repo:repo,files:[empty])
        XCTAssertEqual(modes[Data("empty".utf8)],.regular)
    }
    func testMultipartHasExactSlicesAndNoHubTokenOnStorage() async throws {
        let bytes = Data("0123456789".utf8), desc = file(Data("0123456789".utf8))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:local); defer { try? FileManager.default.removeItem(at:local) }
        let action: [String:Any] = ["href":"https://huggingface.co/complete", "header":["chunk_size":"6","1":"https://storage.example/1","2":"https://storage.example/2"]]
        let mock = HubMock([try reply(["objects":[["oid":desc.sha256,"size":desc.size,"actions":["upload":action]]]]), try reply([:],headers:["ETag":"one"]), try reply([:],headers:["ETag":"two"]), try reply([:])])
        try await NativeHubClient(token:"hf_secret",transport:mock).uploadLFS(repo:repo,file:local,descriptor:desc)
        let calls = await mock.calls; XCTAssertEqual(calls.count,4)
        XCTAssertEqual(calls[1].upload,Data(bytes.prefix(6))); XCTAssertEqual(calls[2].upload,Data(bytes.suffix(4)))
        XCTAssertNil(calls[1].request.value(forHTTPHeaderField:"Authorization"))
        XCTAssertNil(calls[2].request.value(forHTTPHeaderField:"Authorization"))
        let completion = try JSONSerialization.jsonObject(with:XCTUnwrap(calls[3].request.httpBody)) as! [String:Any]
        XCTAssertEqual(completion["oid"] as? String,desc.sha256)
        XCTAssertEqual((completion["parts"] as? [[String:Any]])?.count,2)
    }
    func testLFSReuseAndMismatchValidation() async throws {
        let bytes = Data("content".utf8), desc = file(Data("content".utf8))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to:local); defer { try? FileManager.default.removeItem(at:local) }
        let reused = HubMock([try reply(["objects":[["oid":desc.sha256,"size":desc.size]]])])
        try await NativeHubClient(token:nil,transport:reused).uploadLFS(repo:repo,file:local,descriptor:desc)
        let calls = await reused.calls; XCTAssertEqual(calls.count,1)
        let wrong = HubMock([try reply(["objects":[["oid":String(repeating:"0",count:64),"size":desc.size]]])])
        do { try await NativeHubClient(token:nil,transport:wrong).uploadLFS(repo:repo,file:local,descriptor:desc); XCTFail() }
        catch NativeHubError.invalidResponse { }
    }
    func testMultipartRetryCountsBodiesWithoutInflatingFileProgress() async throws {
        let bytes = Data("0123456789".utf8), desc = file(Data("0123456789".utf8))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: local); defer { try? FileManager.default.removeItem(at: local) }
        let action: [String: Any] = ["href": "https://huggingface.co/complete", "header": ["chunk_size": "6", "1": "https://storage.example/1", "2": "https://storage.example/2"]]
        let mock = HubMock([try reply(["objects": [["oid": desc.sha256, "size": desc.size, "actions": ["upload": action]]]]),
                            try reply([:], status: 503), try reply([:], headers: ["ETag": "one"]),
                            try reply([:], headers: ["ETag": "two"]), try reply([:])])
        let probe = TransportProbe()
        try await NativeHubClient(token: nil, transport: mock, onTransferEvent: probe.record)
            .uploadLFS(repo: repo, file: local, descriptor: desc, onBytes: probe.logical)
        let calls = await mock.calls
        let observed = calls.reduce(Int64(0)) { $0 + Int64(($1.upload ?? $1.request.httpBody)?.count ?? 0) }
        XCTAssertEqual(probe.summary.requestBodyBytes, observed)
        XCTAssertEqual(probe.summary.uploadBodyBytes, 16)
        XCTAssertEqual(probe.progress, 10)
        XCTAssertEqual(probe.summary.requestAttempts, 5)
        XCTAssertEqual(probe.summary.retryAttempts, 1)
        XCTAssertEqual(probe.summary.retryWaits, 1)
    }
    func testInlineCommitCountsEncodedBodyAndNeverRetriesMutation() async throws {
        let bytes = Data("abc".utf8), addition = NativeCommitFile(descriptor: file(Data("abc".utf8)), content: bytes)
        for status in [200, 503] {
            let mock = HubMock([try reply(["commitOid": String(repeating: "a", count: 40)], status: status)])
            let probe = TransportProbe()
            do { _ = try await NativeHubClient(token: nil, transport: mock, onTransferEvent: probe.record).commit(repo: repo, additions: [addition]) }
            catch { XCTAssertEqual(status, 503) }
            let calls = await mock.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(probe.summary.requestBodyBytes, Int64(try XCTUnwrap(calls.first?.request.httpBody).count))
            XCTAssertGreaterThan(probe.summary.uploadBodyBytes, Int64(bytes.count))
            XCTAssertEqual(probe.summary.uploadBodyBytes, probe.summary.requestBodyBytes)
            XCTAssertEqual(probe.summary.retryAttempts, 0)
            XCTAssertEqual(probe.summary.retryWaits, 0)
        }
    }
    func testPartialNetworkSendIsRetainedWhenWholeFileRetries() async throws {
        let bytes = Data("0123456789".utf8), desc = file(Data("0123456789".utf8))
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: local); defer { try? FileManager.default.removeItem(at: local) }
        let batch = try reply(["objects": [["oid": desc.sha256, "size": desc.size, "actions": ["upload": ["href": "https://storage.example/object"]]]]])
        let mock = PartialSendMock([batch, try reply([:]), try reply([:])])
        let probe = TransportProbe()
        try await NativeHubClient(token: nil, transport: mock, onTransferEvent: probe.record)
            .uploadLFS(repo: repo, file: local, descriptor: desc, onBytes: probe.logical)
        XCTAssertEqual(probe.summary.uploadBodyBytes, 12)
        XCTAssertEqual(probe.progress, 10)
        XCTAssertEqual(probe.summary.requestAttempts, 3)
        XCTAssertEqual(probe.summary.retryReasons[.connection], 1)
        XCTAssertEqual(probe.summary.retryAttempts, 1)
    }
    func testReadRetriesExhaustAtThreeAndAuthorizationErrorsDoNotRetry() async throws {
        for status in [401, 403, 409, 503] {
            let mock = HubMock(try (0..<3).map { _ in try reply([:], status: status) })
            let probe = TransportProbe()
            do { _ = try await NativeHubClient(token: nil, transport: mock, onTransferEvent: probe.record).whoami(); XCTFail() }
            catch NativeHubError.http(let actual, _) { XCTAssertEqual(actual, status) }
            let calls = await mock.calls
            XCTAssertEqual(calls.count, status == 503 ? 3 : 1)
            XCTAssertEqual(probe.summary.retryAttempts, status == 503 ? 2 : 0)
            XCTAssertEqual(probe.summary.retryWaits, status == 503 ? 2 : 0)
        }
    }
    func testCancellationDuringRetryWaitDoesNotStartAnotherRequest() async throws {
        let waiting = expectation(description: "Entered retry wait")
        let probe = TransportProbe(onWait: { waiting.fulfill() })
        let mock = HubMock([try reply([:], status: 429, headers: ["Retry-After": "30"])])
        let client = NativeHubClient(token: nil, transport: mock, onTransferEvent: probe.record)
        let task = Task { try await client.whoami() }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
        let calls = await mock.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(probe.summary.retryWaits, 1)
        XCTAssertEqual(probe.summary.cancelledRetryWaits, 1)
        XCTAssertEqual(probe.summary.retryAttempts, 0)
    }
    func testCommitRequiresAckAndDoesNotRetryAmbiguousMutation() async throws {
        let bytes = Data("abc".utf8), oid = String(repeating:"a",count:40)
        let first = NativeCommitFile(descriptor:file(bytes,path:"é.txt"),content:bytes)
        let second = NativeCommitFile(descriptor:file(bytes,path:"e\u{301}.txt"),content:bytes)
        let mock = HubMock([try reply(["commitOid":oid])])
        let result = try await NativeHubClient(token:nil,transport:mock).commit(repo:repo,additions:[first,second],deletions:["old"])
        XCTAssertEqual(result.commitOID,oid)
        let calls = await mock.calls; XCTAssertEqual(calls[0].request.httpBody?.split(separator:10).count,4)
        let rejected = HubMock([try reply([:],status:503),try reply(["commitOid":oid])])
        do { _ = try await NativeHubClient(token:nil,transport:rejected).commit(repo:repo,additions:[first]); XCTFail() }
        catch NativeHubError.http(let code,_) { XCTAssertEqual(code,503) }
        let attempts = await rejected.calls; XCTAssertEqual(attempts.count,1)
        let ambiguous = HubMock([try reply(["ok":true])])
        do { _ = try await NativeHubClient(token:nil,transport:ambiguous).commit(repo:repo,additions:[first]); XCTFail() }
        catch NativeHubError.invalidResponse { }
    }
    func testChangedRegularContentRejectedBeforeNetwork() async throws {
        let mock = HubMock([])
        let changed = NativeCommitFile(descriptor:file(Data("abc".utf8)),content:Data("xyz".utf8))
        do { _ = try await NativeHubClient(token:nil,transport:mock).commit(repo:repo,additions:[changed]); XCTFail() }
        catch NativeHubError.sourceChanged { }
        let calls = await mock.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testTreePreservesDistinctGitLFSAndOpaqueXetIdentities() async throws {
        let blob = String(repeating: "a", count: 40), content = String(repeating: "b", count: 64)
        let objects: [[String: Any]] = [
            ["path": "weights.bin", "type": "file", "size": 100, "oid": blob,
             "lfs": ["oid": content, "size": 100, "pointerSize": 130], "xetHash": "opaque-xet-id"],
            ["path": "unknown.txt", "type": "file", "size": 100]
        ]
        let mock = HubMock([try reply(objects)])
        let entries = try await NativeHubClient(token: nil, transport: mock).tree(repo: repo)
        XCTAssertEqual(entries[0].gitBlobOID, blob)
        XCTAssertEqual(entries[0].lfsSHA256, content)
        XCTAssertEqual(entries[0].xetHash, "opaque-xet-id")
        XCTAssertNil(entries[1].gitBlobOID); XCTAssertNil(entries[1].lfsSHA256)
        let invalid = HubMock([try reply([["path": "bad.bin", "type": "file", "size": 1, "lfs": ["oid": "not-a-hash"]]])])
        do { _ = try await NativeHubClient(token: nil, transport: invalid).tree(repo: repo); XCTFail() }
        catch NativeHubError.invalidResponse { }
    }
    func testRevisionBoundTreeAndStreamKeepIdentityAcrossPages() async throws {
        let revision = String(repeating: "c", count: 40)
        let first = try reply([["path": "a.txt", "type": "file", "size": 1]], headers: ["Link": "<?cursor=2>; rel=next"])
        let second = try reply([["path": "b.txt", "type": "file", "size": 2, "oid": String(repeating: "d", count: 40)]])
        let mock = HubMock([first, second])
        let entries = try await NativeHubClient(token: nil, transport: mock).tree(repo: repo, recursive: true, revision: revision)
        XCTAssertEqual(entries.map(\.path), ["a.txt", "b.txt"])
        let calls = await mock.calls
        XCTAssertTrue(calls.allSatisfy { $0.request.url?.path == "/api/datasets/owner/repo/tree/\(revision)" })
        let streamed = TreeEntries(), streamMock = HubMock([first, second])
        try await NativeHubClient(token: nil, transport: streamMock).streamTree(repo: repo, revision: revision) { entry in
            await streamed.append(entry)
        }
        let streamValues = await streamed.values
        XCTAssertEqual(streamValues, entries)
    }
    func testRevisionPaginationCannotSwitchToAnotherTree() async throws {
        let revision = String(repeating: "a", count: 40)
        let first = try reply([["path": "a.txt", "type": "file", "size": 1]],
                              headers: ["Link": "</api/datasets/owner/repo/tree/main?cursor=2>; rel=next"])
        for streaming in [false, true] {
            let mock = HubMock([first, try reply([])])
            do {
                let client = NativeHubClient(token: nil, transport: mock)
                if streaming { try await client.streamTree(repo: repo, revision: revision) { _ in } }
                else { _ = try await client.tree(repo: repo, revision: revision) }
                XCTFail("A revision switch must reject the comparison")
            } catch NativeHubError.invalidResponse { }
            let calls = await mock.calls; XCTAssertEqual(calls.count, 1)
        }
    }
    func testParentGuardIsInCommitHeaderAndConflictsAreNotRetried() async throws {
        let parent = String(repeating: "a", count: 40), next = String(repeating: "b", count: 40)
        let bytes = Data("abc".utf8)
        let addition = NativeCommitFile(descriptor: file(bytes), content: bytes)
        let mock = HubMock([try reply(["commitOid": next])])
        _ = try await NativeHubClient(token: nil, transport: mock).commit(repo: repo, additions: [addition], expectedParent: parent)
        let calls = await mock.calls
        let line = try XCTUnwrap(calls.first?.request.httpBody?.split(separator: 10).first)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        XCTAssertEqual((header["value"] as? [String: String])?["parentCommit"], parent)
        let conflict = HubMock([try reply([:], status: 409), try reply(["commitOid": next])])
        do { _ = try await NativeHubClient(token: nil, transport: conflict).commit(repo: repo, additions: [addition], expectedParent: parent); XCTFail() }
        catch NativeHubError.http(let status, _) { XCTAssertEqual(status, 409) }
        let attempts = await conflict.calls; XCTAssertEqual(attempts.count, 1)
    }
    func testInvalidRevisionAndParentNeverSendARequest() async throws {
        let mock = HubMock([])
        let guarded = NativeHubClient(token: nil, transport: mock)
        do { _ = try await guarded.tree(repo: repo, revision: "../main"); XCTFail() }
        catch NativeHubError.invalidInput { }
        do { _ = try await guarded.commit(repo: repo, additions: [], expectedParent: "short"); XCTFail() }
        catch NativeHubError.invalidInput { }
        let calls = await mock.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testMalformedCommitRevisionNeverCountsAsAcknowledged() async throws {
        let mock = HubMock([try reply(["commitOid": String(repeating: "a", count: 41)])])
        let bytes = Data("abc".utf8)
        do {
            _ = try await NativeHubClient(token: nil, transport: mock).commit(
                repo: repo, additions: [NativeCommitFile(descriptor: file(bytes), content: bytes)])
            XCTFail("An incomplete object identity must not acknowledge a commit")
        } catch NativeHubError.invalidResponse { }
        let calls = await mock.calls; XCTAssertEqual(calls.count, 1)
    }
    func testDelegateBoundsStreamingResponses() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LargeResponseProtocol.self]
        let transport = NativeURLSessionTransport(maximumResponseBytes:16,configuration:config)
        do { _ = try await transport.execute(URLRequest(url:URL(string:"https://huggingface.co/test")!),uploadFile:nil,onBytes:{_ in}); XCTFail() }
        catch NativeHubError.responseTooLarge { }
    }
    func testCancellationStopsURLSessionTask() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HangingProtocol.self]
        let transport = NativeURLSessionTransport(configuration:config)
        let task = Task { try await transport.execute(URLRequest(url:URL(string:"https://huggingface.co/test")!),uploadFile:nil,onBytes:{_ in}) }
        try await Task.sleep(for:.milliseconds(20)); task.cancel()
        do { _ = try await task.value; XCTFail() }
        catch is CancellationError { }
    }
    func testUnsafeEndpointAndRepoDoNotSendCredentials() async throws {
        let mock = HubMock([])
        do { _ = try await NativeHubClient(token:"secret",endpoint:URL(string:"http://huggingface.co")!,transport:mock).whoami(); XCTFail() }
        catch NativeHubError.unsafeURL { }
        do { _ = try await NativeHubClient(token:"secret",transport:mock).info(repo:HubRepo(name:"owner/../repo",kind:.model)); XCTFail() }
        catch NativeHubError.invalidInput { }
        let calls = await mock.calls; XCTAssertTrue(calls.isEmpty)
    }
}
