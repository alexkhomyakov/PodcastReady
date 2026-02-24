import Foundation

struct AnalysisResult: Codable {
    let lighting: Category
    let colorTemperature: Category
    let framing: Category
    let background: Category

    struct Category: Codable {
        let status: Status
        let suggestion: String

        enum Status: String, Codable {
            case good = "GOOD"
            case needsAdjustment = "NEEDS_ADJUSTMENT"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(Status.self, forKey: .status)
            suggestion = (try? container.decode(String.self, forKey: .suggestion)) ?? "Looks good."
        }
    }
}
