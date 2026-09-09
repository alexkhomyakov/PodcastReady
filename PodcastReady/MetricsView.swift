import SwiftUI

/// The measured numbers, shown whether or not the model has been asked for an
/// opinion. Measuring is free and instant; the API call is neither.
struct MetricsView: View {
    let metrics: FrameMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !metrics.faceFound {
                Label("No face detected — showing whole-frame numbers only.",
                      systemImage: "person.slash")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 2)
            }

            ForEach(metrics.rows) { row in
                HStack(spacing: 8) {
                    Image(systemName: icon(row.status))
                        .foregroundColor(color(row.status))
                        .frame(width: 14)

                    Text(row.label)
                        .font(.caption)
                        .frame(width: 120, alignment: .leading)

                    Text(row.value)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .frame(width: 70, alignment: .trailing)

                    Text(row.target)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Spacer()
                }
            }
        }
    }

    private func icon(_ s: Metric.Status) -> String {
        switch s {
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "circle.dashed"
        }
    }

    private func color(_ s: Metric.Status) -> Color {
        switch s {
        case .good: return .green
        case .warn: return .orange
        case .info: return .secondary
        }
    }
}
