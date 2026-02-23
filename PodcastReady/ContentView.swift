import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        VStack(spacing: 16) {
            Text("PodcastReady")
                .font(.headline)

            if cameraManager.isAuthorized {
                CameraPreviewView(session: cameraManager.session)
                    .frame(height: 225)
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 225)
                    .overlay(
                        Text("Camera access required")
                            .foregroundColor(.white)
                    )
                    .cornerRadius(8)
            }

            Button("Analyze Setup") {
                // TODO: implement analysis
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
        .frame(width: 400, height: 520)
    }
}
