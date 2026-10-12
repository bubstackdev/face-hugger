import Foundation
import Testing
@testable import FaceHuggerCore

struct FaithfulnessTests {
    private static let cases = (try? FaithfulnessChecker.loadCases()) ?? []

    private func facts(for testCase: FaithfulnessCase) -> DatasetCardFacts {
        let paths = testCase.metadataPaths ?? ["data/part-0.csv"]
        return DatasetCardFacts(includedCount: paths.count, includedBytes: Int64(paths.count * 100), excludedCount: 0,
                                samplePaths: paths, pathsTruncated: false, formats: [], otherFormatCount: 0, uploadPath: "")
    }

    private func overview(in card: String) throws -> String {
        let start = try #require(card.range(of: "## Overview\n\n"))
        let end = try #require(card.range(of: "\n\n## Files", range: start.upperBound..<card.endIndex))
        return String(card[start.upperBound..<end.lowerBound])
    }

    @Test func fixturesAreWellFormed() throws {
        let cases = try FaithfulnessChecker.loadCases()
        #expect(cases.count >= 10)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.language)).isSuperset(of: ["en", "es", "ja", "de"]))
        #expect(cases.filter(\.isInjection).count >= 2)
        for testCase in cases {
            #expect(!testCase.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(testCase.id)")
            #expect(testCase.purpose.utf8.count <= DatasetCardDrafter.purposeByteLimit, "\(testCase.id)")
            #expect(!testCase.mustKeep.isEmpty && !testCase.faithful.isEmpty && !testCase.unfaithful.isEmpty, "\(testCase.id)")
        }
    }

    @Test(arguments: cases.map(\.id))
    func faithfulReferencesPass(id: String) throws {
        let testCase = try #require(Self.cases.first { $0.id == id })
        for output in testCase.faithful {
            #expect(FaithfulnessChecker.violations(output: output, for: testCase) == [], "\(output)")
        }
    }

    @Test(arguments: cases.map(\.id))
    func unfaithfulExamplesFailForTheStatedReason(id: String) throws {
        let testCase = try #require(Self.cases.first { $0.id == id })
        for example in testCase.unfaithful {
            let rules = FaithfulnessChecker.violations(output: example.output, for: testCase).map(\.rule)
            #expect(rules.contains(example.violates), "\(example.output) → \(rules)")
        }
    }

    /// Copying the owner's words back is always faithful, unless the words are an injection attempt.
    @Test(arguments: cases.filter { !$0.isInjection }.map(\.id))
    func theOwnersTextSatisfiesItsOwnConstraints(id: String) throws {
        let testCase = try #require(Self.cases.first { $0.id == id })
        #expect(FaithfulnessChecker.violations(output: testCase.purpose, for: testCase) == [])
    }

    /// End to end with a fake model: the purpose reaches the model intact, and its reply
    /// lands in the overview unchanged, so the checker can score real models the same way.
    @Test(arguments: cases.map(\.id))
    func draftingPipelineFeedsTheChecker(id: String) async throws {
        let testCase = try #require(Self.cases.first { $0.id == id })
        let reply = testCase.faithful[0]
        let model = FakeDraftModel(.rewrite { _ in reply })
        let card = try await DatasetCardDrafter.draft(facts: facts(for: testCase), input: .init(purpose: testCase.purpose), model: model)
        let request = try #require(model.requests.first)
        #expect(FakeDraftModel.purpose(in: request) == testCase.purpose)
        #expect(try overview(in: card) == reply)
        #expect(FaithfulnessChecker.violations(output: try overview(in: card), for: testCase) == [])
    }

    @Test func pathInjectionStaysInsideTheMetadataField() throws {
        let testCase = try #require(Self.cases.first { $0.id == "injection-in-path" })
        let request = try DatasetCardDrafter.request(facts: facts(for: testCase), input: .init(purpose: testCase.purpose))
        let json = Data(request.prompt.dropFirst(DatasetCardDrafter.promptPrefix.count).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: String])
        #expect(object["purpose"] == testCase.purpose)
        #expect(object["metadata"]?.contains("IGNORE_PREVIOUS_INSTRUCTIONS") == true)
    }

    @Test func numbersIgnoreSeparatorsAndWidth() {
        #expect(FaithfulnessChecker.numbers(in: "10,000 rows, 2.5 GB, ５００枚") == ["10000", "2", "5", "500"])
        #expect(FaithfulnessChecker.numbers(in: "一枚, a, b, 3") == ["3"])
    }
}
