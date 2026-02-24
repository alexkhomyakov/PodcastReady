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
        VStack(spacing: 10) {
            // Header
            HStack {
                Text("PodcastReady")
                    .font(.headline)
                Spacer()
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

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }

            // Full-width camera preview (16:9)
            if cameraManager.isAuthorized {
                CameraPreviewView(session: cameraManager.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .background(Color.black)
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.largeTitle)
                            Text("Camera access required")
                            Text("System Settings > Privacy > Camera")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                    )
                    .cornerRadius(8)
            }

            // Results panel below camera
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let result = analysisResult {
                        AnalysisResultView(result: result)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if KeychainManager.retrieve() == nil {
                        Text("Add your Anthropic API key in Settings to get started.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Click Analyze Setup to check your video setup.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .padding()
        .frame(width: 720, height: 640)
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
                    errorMessage = String(describing: error)
                    isAnalyzing = false
                }
            }
        }
    }
}
