import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("PodcastReady")
                .font(.headline)

            Rectangle()
                .fill(Color.black)
                .frame(height: 225)
                .overlay(
                    Text("Camera Preview")
                        .foregroundColor(.white)
                )
                .cornerRadius(8)

            Button("Analyze Setup") {
                // TODO: implement
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
        .frame(width: 400, height: 520)
    }
}
