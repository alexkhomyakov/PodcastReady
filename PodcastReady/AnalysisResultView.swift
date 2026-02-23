import SwiftUI

struct AnalysisResultView: View {
    let result: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CategoryRow(label: "Lighting", category: result.lighting)
            CategoryRow(label: "Color Temp", category: result.colorTemperature)
            CategoryRow(label: "Framing", category: result.framing)
            CategoryRow(label: "Background", category: result.background)
        }
    }
}

struct CategoryRow: View {
    let label: String
    let category: AnalysisResult.Category

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: category.status == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(category.status == .good ? .green : .orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(category.suggestion)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
