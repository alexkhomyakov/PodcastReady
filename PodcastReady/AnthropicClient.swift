import Foundation

// Direct Messages API client.
//
// This replaced SwiftAnthropic, which pinned us to an older model: its response
// decoder knows only `text` and `tool_use` content blocks, and Claude Opus 5
// runs adaptive thinking by default, so every Opus 5 response failed to decode
// before any of our code ran. The failure surfaced as `jsonDecodingFailure` with
// no detail, which is the second reason this exists — an API error now arrives
// as the message the API actually sent.
//
// There is no official Anthropic Swift SDK, so raw HTTP is the supported route.

struct AnthropicClient {
    let apiKey: String

    enum ClientError: LocalizedError {
        case badResponse
        case api(status: Int, type: String, message: String)
        case noTextBlock

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "The API returned a response that could not be read."
            case .api(let status, let type, let message):
                return "API error \(status) (\(type)): \(message)"
            case .noTextBlock:
                return "The model returned no text (only thinking or tool blocks)."
            }
        }
    }

    /// Sends one image plus a prompt and returns the model's text.
    func complete(system: String,
                  prompt: String,
                  jpeg: Data,
                  model: String = "claude-opus-5",
                  effort: String = "low",
                  maxTokens: Int = 4000) async throws -> String {

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // A four-line verdict over pre-computed numbers is not a hard
            // reasoning problem, and low effort keeps the button responsive.
            "output_config": ["effort": effort],
            "system": system,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg",
                                "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badResponse }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badResponse
        }

        if http.statusCode != 200 {
            let err = json["error"] as? [String: Any]
            throw ClientError.api(status: http.statusCode,
                                  type: err?["type"] as? String ?? "unknown",
                                  message: err?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "")
        }

        // Take the first TEXT block. Opus 5 thinks by default, so block zero is
        // routinely a thinking block with the answer sitting behind it.
        guard let content = json["content"] as? [[String: Any]] else { throw ClientError.badResponse }
        for block in content where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        throw ClientError.noTextBlock
    }
}
