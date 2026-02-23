import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    private let analysisService = AnalysisService()

    @State private var analysisResult: AnalysisResult?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showSettings = false

    var body: some View {
        if showSettings {
            SettingsView(isPresented: $showSettings, cameraManager: cameraManager)
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("PodcastReady")
                    .font(.headline)
                Spacer()
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }

            // Camera preview
            if cameraManager.isAuthorized {
                CameraPreviewView(session: cameraManager.session)
                    .frame(height: 225)
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 225)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.largeTitle)
                            Text("Camera access required")
                            Text("Grant access in System Settings > Privacy > Camera")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                    )
                    .cornerRadius(8)
            }

            // Analyze button
            Button(action: analyzeSetup) {
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 8)
                } else {
                    Label("Analyze Setup", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAnalyzing || !cameraManager.isAuthorized)

            // First-launch hint
            if KeychainManager.retrieve() == nil && analysisResult == nil && errorMessage == nil {
                Text("Add your Anthropic API key in Settings to get started.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Error message
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            // Results
            if let result = analysisResult {
                Divider()
                AnalysisResultView(result: result)
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit PodcastReady") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(width: 400, height: 520)
    }

    private func analyzeSetup() {
        isAnalyzing = true
        errorMessage = nil

        Task {
            do {
                guard let imageData = await cameraManager.captureFrame() else {
                    errorMessage = "Failed to capture frame."
                    isAnalyzing = false
                    return
                }

                let result = try await analysisService.analyze(imageData: imageData)

                await MainActor.run {
                    analysisResult = result
                    isAnalyzing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAnalyzing = false
                }
            }
        }
    }
}
