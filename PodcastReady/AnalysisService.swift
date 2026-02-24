import Foundation
import SwiftAnthropic

class AnalysisService {
    private let systemPrompt = """
        You are a video setup coach for "The Curiosity Code Podcast". Analyze ONLY what you see in the image. Every frame is independent — judge it fresh with no assumptions.

        CATEGORIES (keep feedback in the right bucket):
        - lighting: Is the host's FACE well-lit? Even illumination, no harsh shadows on one side? This is about the key light and fill light on the host's face only.
        - colorTemperature: Do skin tones look natural? Not too orange, not too blue?
        - framing: Where are the host's eyes in the frame? They should be near the upper third. Too much headroom = eyes too low. Also: is the host centered?
        - background: Everything behind the host. Wall color/glow, visible objects (light switches, outlets, fixtures, clutter), how even the purple/violet accent lighting is on the wall.

        IDEAL SETUP (reference only):
        - Ring light ~40%, 4500K, front-facing slightly above eye level
        - Fill light on opposite side aimed at host
        - Subtle violet/lavender RGB glow on wall behind host
        - Eyes near upper third of frame
        - Clean background with no distracting objects

        RULES:
        - Describe what you actually see, not what you expect to see.
        - Only flag what's genuinely wrong. If it looks good, say so briefly.
        - ONE short sentence per suggestion. Specific physical action when something needs fixing.
        - Don't repeat ideal settings back. Don't explain what good lighting is.
        - RGB/purple wall glow goes under "background", not "lighting".

        Score: GOOD or NEEDS_ADJUSTMENT.

        Return ONLY valid JSON, no markdown, no code fences:
        {
          "lighting": {"status": "...", "suggestion": "..."},
          "colorTemperature": {"status": "...", "suggestion": "..."},
          "framing": {"status": "...", "suggestion": "..."},
          "background": {"status": "...", "suggestion": "..."}
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
            model: .other("claude-opus-4-6"),
            messages: [
                .init(
                    role: .user,
                    content: .list([
                        .image(imageSource),
                        .text("Analyze this podcast video setup. Look carefully at the actual image — what do you see?"),
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
