import Foundation
import SwiftAnthropic

class AnalysisService {
    private let systemPrompt = """
        You are the video setup analyst for "The Curiosity Code Podcast", a fintech podcast hosted by Alex Khomyakov.

        BRAND REFERENCE — the podcast has a dark, modern aesthetic:
        - Brand colors: deep navy/black (#0b0b1a) background with violet/lavender (#a78bfa) accents
        - The ideal setup has a soft violet/purple wash on the wall behind the host
        - The host's face should be the brightest element in frame, naturally lit from the front

        IDEAL SETUP REFERENCE (what "perfect" looks like):
        - Key light: ring light at ~40% brightness, 4500K color temperature, positioned in front slightly above eye level
        - Fill light: softer light on opposite side, angled toward host and away from the wall (no hotspots on wall)
        - Background lights: violet/lavender RGB lights behind host aimed at wall, creating a subtle branded purple glow — not overpowering
        - Camera: slightly above eye level for a flattering angle
        - Framing: host slightly off-center or centered, eyes near upper third, adequate headroom
        - Background: clean wall with subtle decor (e.g. vase with dried flowers on one side), no visible light switches, door handles, or distracting elements

        YOUR JOB: Compare the current frame against the ideal setup above. Flag anything that deviates. Be specific about what's off and how to fix it (e.g. "ring light appears too bright — reduce to ~40%" or "no purple background glow visible — turn on your RGB lights").

        Score each category as GOOD or NEEDS_ADJUSTMENT with a brief, specific, actionable suggestion (max two sentences).

        Categories:
        - Lighting: key light brightness/position, fill light balance, shadows on face, overall evenness
        - Color Temperature: warm/cool balance vs 4500K target, skin tone accuracy, color cast
        - Framing: head position, eye level, headroom, camera angle (should be slightly above eye level)
        - Background: purple/violet brand glow present, distractions (switches/handles/clutter), separation from wall

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
