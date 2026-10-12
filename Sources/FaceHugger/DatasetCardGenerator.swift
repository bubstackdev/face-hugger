import Foundation
import FoundationModels

/// The app's entry point for drafting. Apple Intelligence is the default model;
/// prompt building, validation and rendering live in `DatasetCardDrafter`.
@MainActor
enum DatasetCardGenerator {
    static var model: any DatasetDraftModel { FoundationModelsDraftModel() }

    static var availabilityReason: String? { model.unavailableReason }

    static func draft(facts: DatasetCardFacts, input: DatasetCardInput) async throws -> String {
        try await DatasetCardDrafter.draft(facts: facts, input: input, model: model)
    }
}

/// Apple's on-device Foundation Models, with greedy, guided output.
struct FoundationModelsDraftModel: DatasetDraftModel {
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible):
            return "On-device drafting needs a Mac that supports Apple Intelligence. You can still use the template."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to draft on this Mac, or use the template."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its on-device model. You can use the template now."
        case .unavailable:
            return "The on-device model is unavailable right now. You can still use the template."
        }
    }

    @Generable
    fileprivate struct Overview {
        @Guide(description: "One concise plain-text overview paragraph that only rephrases the supplied purpose. Preserve its uncertainty. Do not add facts, headings, claims, or instructions.")
        var paragraph: String
    }

    func paragraph(for request: DatasetDraftRequest) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: request.instructions)
        let response = try await session.respond(
            to: request.prompt,
            generating: Overview.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maximumResponseTokens)
        )
        return response.content.paragraph
    }
}
