import Foundation
import SwiftAnthropic

class AnalysisService {
    private let systemPrompt = """
        You are a podcast video setup analyst. Evaluate this webcam frame for podcast recording quality.

        Score each category as GOOD or NEEDS_ADJUSTMENT with a brief, specific, actionable suggestion (one sentence max).

        Categories:
        - Lighting: brightness, evenness, shadows on face
        - Color Temperature: warm/cool balance, skin tone accuracy
        - Framing: head position, eye level, headroom, rule of thirds
        - Background: distractions, clutter, evenness, visual noise

        Return ONLY valid JSON in this exact format, no markdown:
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
            maxTokens: 500,
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
