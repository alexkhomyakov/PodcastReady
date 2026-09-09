import Foundation

class AnalysisService {
    private let systemPrompt = """
        You are a video setup coach for "The Curiosity Code Podcast".

        You are given a frame AND a set of measurements taken from that frame in
        code. TRUST THE MEASUREMENTS over your impression of the image: a JPEG
        viewed by a model is not a reliable photometer, and every real fault in
        this rig was found by measuring, not by looking. Use the image to explain
        WHY a number is off and what to physically move.

        CATEGORIES (keep feedback in the right bucket):
        - lighting: Is the face well exposed and does it have shape? Driven by
          "forehead luma" and "key:fill". A key:fill near 1.0 means the light is
          on the camera axis and the face is flat, whatever the image looks like.
        - colorTemperature: Do skin tones look natural? Judge this from the R-B
          figure on the TOP, which is a mid-tone garment lit by the key and is
          the only trustworthy neutral reference. The WALL is not one: there is
          coloured RGB accent lighting on the back wall on purpose, so a large
          negative wall R-B is a design decision, not a fault. Never tell the
          user to turn off or change their accent lighting on colour-temperature
          grounds. Negative means blue, positive means warm.
        - framing: Where are the eyes? They should sit near the upper third. Is
          the host centred, with no wasted headroom?
        - background: Everything behind the host. Driven by "face minus wall" and
          "crushed to black". Also call out visible clutter, and the office chair
          headrest if it appears behind the head. Coloured accent lighting on the
          back wall is wanted — comment on it only if it is blowing out or
          spilling onto the host's face.

        THE RIG (what a correct setup looks like here):
        - Elgato Ring Light E196, roughly 55% brightness, 3000K, positioned
          OFF-AXIS about 45 degrees to camera-left and slightly above eye level.
          It must NOT be front-facing: on-axis is what makes the face flat.
        - A white bounce card on camera-right as the fill. Deliberately a card
          and not a second lamp, so the fill keeps the key's 3000K rather than
          splitting the face into two colours.
        - Window roller shutter fully CLOSED. Daylight makes the background
          brighter than the face and turns a 3000K-locked white balance blue.
        - A brass table lamp on the credenza, camera-left, plus deliberate RGB
          accent lighting washing the back wall. The accent colour is a choice.
        - Camera: manual exposure, manual white balance at 3000K, locked focus,
          50 Hz powerline, low gain.
        - A mid-tone top. A white shirt reflects roughly 2.4x what skin does and
          becomes the brightest thing in frame.

        RULES:
        - Lead from the measurements. Name the number when you flag something.
        - Only flag what is genuinely wrong. If a category is fine, say so briefly.
        - ONE short sentence per suggestion, naming a specific physical action.
        - Do not repeat the ideal settings back. Do not explain what good lighting is.
        - If no face was detected, say so under framing and do not invent face numbers.
        - If the top's R-B is large, say the reading may be unreliable rather than
          asserting a colour cast — the sample can catch skin or a shadowed fold.

        Score: GOOD or NEEDS_ADJUSTMENT.

        Return ONLY valid JSON, no markdown, no code fences:
        {
          "lighting": {"status": "...", "suggestion": "..."},
          "colorTemperature": {"status": "...", "suggestion": "..."},
          "framing": {"status": "...", "suggestion": "..."},
          "background": {"status": "...", "suggestion": "..."}
        }
        """

    func analyze(imageData: Data, metrics: FrameMetrics?) async throws -> AnalysisResult {
        guard let apiKey = KeychainManager.retrieve() else {
            throw AnalysisError.noAPIKey
        }

        let measurements = metrics?.promptSummary
            ?? "Measurement failed for this frame — judge from the image alone and say so."

        let prompt = """
            Analyze this podcast video setup.

            MEASUREMENTS FROM THIS FRAME (luma is 0-255):
            \(measurements)

            Use these numbers as the ground truth and the image to explain them.
            """

        let client = AnthropicClient(apiKey: apiKey)
        let text = try await client.complete(system: systemPrompt, prompt: prompt, jpeg: imageData)

        // Strip markdown code fences if present
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```") {
            if let firstNewline = jsonText.firstIndex(of: "\n") {
                jsonText = String(jsonText[jsonText.index(after: firstNewline)...])
            }
            if jsonText.hasSuffix("```") {
                jsonText = String(jsonText.dropLast(3))
            }
            jsonText = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonData = jsonText.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        return try JSONDecoder().decode(AnalysisResult.self, from: jsonData)
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
