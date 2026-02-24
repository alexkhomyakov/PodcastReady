import Foundation
import SwiftAnthropic

class AnalysisService {
    private let systemPrompt = """
        You are a direct, no-nonsense video setup coach for "The Curiosity Code Podcast".

        IDEAL SETUP:
        - Ring light at ~40%, 4500K, front-facing slightly above eye level
        - Fill light on opposite side, aimed at host not wall
        - Violet/lavender RGB glow on the wall behind host (subtle, not overpowering)
        - Camera slightly above eye level, eyes near upper third
        - Clean background — no light switches, door handles, or clutter visible

        TONE: Be conversational and direct. Tell the host exactly what to physically do.
        - GOOD: "Shift your chair 2 inches left to hide that light switch."
        - GOOD: "Purple glow is uneven — the left side of the wall is flat. Turn on your second RGB light or reposition."
        - BAD: "Light switch visible on left side should be removed or repositioned to maintain clean aesthetic."
        - BAD: "Move a ring light to ~40% brightness directly in front at slightly above eye level."
        Don't repeat the ideal settings back unless something is actually wrong. If lighting looks good, just say it looks good — don't describe what good lighting is.
        Keep each suggestion to one punchy sentence. Be specific about physical actions (shift left, dim by 10%, angle down).

        Score each as GOOD or NEEDS_ADJUSTMENT.

        Return ONLY valid JSON, no markdown:
        {
          "lighting": {"status": "GOOD", "suggestion": "..."},
          "colorTemperature": {"status": "NEEDS_ADJUSTMENT", "suggestion": "..."},
          "framing": {"status": "GOOD", "suggestion": "..."},
          "background": {"status": "GOOD", "suggestion": "..."}
        }
        """

    func analyze(imageData: Data) async throws -> AnalysisResult {
        guard let apiKey = KeychainManager.retrieve() else {
            throw AnalysisError.noAPIKey
        }

        let service = AnthropicServiceFactory.service(
            apiKey: apiKey,
            betaHeaders: nil
        )
        let base64Image = imageData.base64EncodedString()

        let imageSource = MessageParameter.Message.Content.ImageSource(
            type: .base64,
            mediaType: .jpeg,
            data: base64Image
        )

        let message = MessageParameter(
            model: .other("claude-haiku-4-5-20251001"),
            messages: [
                .init(
                    role: .user,
                    content: .list([
                        .image(imageSource),
                        .text("Analyze this podcast video setup."),
                    ])
                )
            ],
            maxTokens: 800,
            system: .text(systemPrompt)
        )

        let response = try await service.createMessage(message)

        // Extract text from response
        guard let textBlock = response.content.first,
              case .text(let text) = textBlock else {
            throw AnalysisError.invalidResponse
        }

        // Strip markdown code fences if present
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```") {
            // Remove opening fence (```json or ```)
            if let firstNewline = jsonText.firstIndex(of: "\n") {
                jsonText = String(jsonText[jsonText.index(after: firstNewline)...])
            }
            // Remove closing fence
            if jsonText.hasSuffix("```") {
                jsonText = String(jsonText.dropLast(3))
            }
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Parse JSON response
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AnalysisResult.self, from: jsonData)
    }
}

enum AnalysisError: LocalizedError {
    case noAPIKey
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key found. Please add your Anthropic API key in Settings."
        case .invalidResponse:
            return "Could not parse the analysis response. Please try again."
        }
    }
}
