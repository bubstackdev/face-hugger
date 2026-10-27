import Foundation
import XCTest
@testable import FaceHuggerCore

final class PairingTests: XCTestCase {
    func testRoundTripPreservesUnicodeRoutesFiltersAndVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = PairingArchive(url: directory.appendingPathComponent("nested/pairings.json"))
        let pairings = [
            SavedPairing(
                name: "Évaluation · 日本語 🫂",
                source: "/Users/example/Model runs/評価 v2",
                repo: HubRepo(name: "owner/private-data", kind: .dataset, isPrivate: true),
                destination: "results/評価 final",
                includes: ["**/*.json", "weights/*.safetensors"],
                excludes: [".DS_Store", "**/.DS_Store", "**/logs/**"]
            ),
            SavedPairing(
                name: "Public model root",
                source: "/tmp/checkpoint",
                repo: HubRepo(name: "owner/public-model", kind: .model, isPrivate: false),
                destination: "",
                includes: [],
                excludes: []
            )
        ]
        try archive.save(pairings)
        XCTAssertEqual(try archive.load(), pairings)
        // Loading a route preserves its identity instead of minting a new preset.
        XCTAssertEqual(try archive.load().map(\.id), pairings.map(\.id))
        // Removing presets and saving must replace the archive, not append to it.
        try archive.save([pairings[1]])
        XCTAssertEqual(try archive.load(), [pairings[1]])
    }

    func testMissingArchiveLoadsEmptyWithoutCreatingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pairings.json")
        XCTAssertEqual(try PairingArchive(url: url).load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedArchiveThrowsInsteadOfSilentlyLosingPresets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pairings.json")
        for contents in ["{broken JSON", "{}", "[{\"name\":\"missing required route fields\"}]"] {
            let bytes = Data(contents.utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try PairingArchive(url: url).load()) { error in
                XCTAssertTrue(error is DecodingError)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes, "A failed read must preserve the original archive for recovery")
        }
    }
    private func pairing(_ name: String = "Training") -> SavedPairing {
        SavedPairing(name: name, source: "/tmp/評価 runs", repo: HubRepo(name: "owner/data", kind: .dataset),
                     destination: "results/final", includes: ["**/*.json"], excludes: ["**/logs/**"], sourceBookmark: Data([1, 2, 3]))
    }
    func testLegacyArchiveDefaultsAndNewMetadataRoundTripPreserveRoute() throws {
        let original = pairing()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "isPinned"); object.removeValue(forKey: "sortOrder")
        let legacy = try JSONDecoder().decode(SavedPairing.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy, original); XCTAssertFalse(legacy.isPinned); XCTAssertNil(legacy.sortOrder)
        var edited = legacy; edited.name = "Renamed"; edited.isPinned = true; edited.sortOrder = 42
        let decoded = try JSONDecoder().decode(SavedPairing.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded, edited)
        XCTAssertEqual(decoded.id, original.id); XCTAssertEqual(decoded.sourceBookmark, original.sourceBookmark)
        XCTAssertEqual(decoded.repo, original.repo); XCTAssertEqual(decoded.destination, original.destination)
        XCTAssertEqual(decoded.includes, original.includes); XCTAssertEqual(decoded.excludes, original.excludes)
    }
    func testSearchCoversAllRouteLabelsAndRequiresEveryTerm() {
        let saved = pairing("Évaluation 日本語")
        for query in ["evaluation", "日本語", "評価", "owner/data", "results/final", "ÉVALUATION final", "  "] {
            XCTAssertTrue(saved.matches(search: query), query)
        }
        XCTAssertFalse(saved.matches(search: "evaluation absent"))
        XCTAssertFalse(saved.matches(search: "tmp"), "Search uses the source label, not private parent paths")
    }
    func testPinAndOrderAreStableWithMixedLegacyRecords() {
        let a = pairing("A"), b = pairing("B")
        var c = pairing("C"), d = pairing("D")
        c.isPinned = true; d.sortOrder = -1
        XCTAssertEqual(SavedPairing.ordered([a, b, c, d]).map(\.name), ["C", "D", "A", "B"])
        XCTAssertEqual(SavedPairing.ordered([a, b, c, d], search: "B").map(\.id), [b.id])
        d.sortOrder = 0
        XCTAssertEqual(SavedPairing.ordered([a, b, d]).map(\.name), ["A", "D", "B"])
        XCTAssertEqual(SavedPairing.ordered([a, b]).map(\.id), [a.id, b.id])
    }
    func testFolderIdentitySurvivesMoveAndAliasButNotReplacementAtSamePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let identity = try PairingFolderIdentity(url: source)
        try FileManager.default.moveItem(at: source, to: moved)
        XCTAssertEqual(identity, try PairingFolderIdentity(url: moved))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
        XCTAssertEqual(identity, try PairingFolderIdentity(url: alias))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertNotEqual(identity, try PairingFolderIdentity(url: source))
    }
    func testActivePairingRequiresFolderAndEntireRouteButIgnoresDisplayName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = pairing(), folder = try PairingFolderIdentity(url: root)
        let active = ActivePairing(pairing: saved, folder: folder)
        XCTAssertTrue(active.matches(folder: folder, repo: saved.repo, destination: saved.destination, includes: saved.includes, excludes: saved.excludes))
        XCTAssertFalse(active.matches(folder: nil, repo: saved.repo, destination: saved.destination, includes: saved.includes, excludes: saved.excludes))
        XCTAssertFalse(active.matches(folder: folder, repo: HubRepo(name: saved.repo.name, kind: .model), destination: saved.destination, includes: saved.includes, excludes: saved.excludes))
        XCTAssertFalse(active.matches(folder: folder, repo: saved.repo, destination: "elsewhere", includes: saved.includes, excludes: saved.excludes))
        XCTAssertFalse(active.matches(folder: folder, repo: saved.repo, destination: saved.destination, includes: [], excludes: saved.excludes))
        XCTAssertFalse(active.matches(folder: folder, repo: saved.repo, destination: saved.destination, includes: saved.includes, excludes: []))
        let unicode = SavedPairing(name: "Unicode", source: saved.source, repo: saved.repo, destination: "é", includes: [], excludes: [])
        XCTAssertFalse(ActivePairing(pairing: unicode, folder: folder).matches(folder: folder, repo: saved.repo, destination: "e\u{301}", includes: [], excludes: []))
    }
    func testFolderEntryCapturesAllFoldersAndDeduplicatesIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("one"), b = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let entries = try FolderEntry.capture([a, b, a, alias])
        XCTAssertEqual(entries.map { $0.url.lastPathComponent }, ["one", "two"])
        XCTAssertTrue(entries.allSatisfy { $0.access.bookmark != nil })
        for entry in entries {
            let identity = try PairingFolderIdentity(url: entry.url)
            entry.access.close(); entry.access.close()
            let restored = try FolderAccess.restore(path: "/unused-fallback", bookmark: entry.access.bookmark)
            defer { restored.close() }
            XCTAssertEqual(identity, try PairingFolderIdentity(url: restored.url))
        }
    }
    func testFolderEntryRejectsMixedFilesPackagesAndRemoteURLs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("data.json"), package = root.appendingPathComponent("Example.app")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for urls in [[root, file], [package], [URL(string: "https://example.com/folder")!]] {
            XCTAssertThrowsError(try FolderEntry.capture(urls)) { error in
                XCTAssertTrue(error.localizedDescription.contains("local folders"))
            }
        }
        XCTAssertTrue(try FolderEntry.capture([]).isEmpty)
    }
}
