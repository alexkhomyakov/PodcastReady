import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var settingsModel = CameraSettingsModel()
    @StateObject private var profileStore = ProfileStore()
    private let analysisService = AnalysisService()

    private enum Tab: String, CaseIterable { case measure = "Measure", camera = "Camera" }
    @State private var tab: Tab = .measure

    @State private var analysisResult: AnalysisResult?
    @State private var metrics: FrameMetrics?
    @State private var isMeasuring = false
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var didApplyLaunchProfile = false

    var body: some View {
        if showSettings {
            SettingsView(isPresented: $showSettings, cameraManager: cameraManager)
        } else {
            mainView
        }
    }

    private var mainView: some View {
        VStack(spacing: 10) {
            header

            if cameraManager.isAuthorized {
                CameraPreviewView(session: cameraManager.session)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .background(Color.black).cornerRadius(8)
            } else {
                Rectangle().fill(Color.black)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill").font(.largeTitle)
                            Text("Camera access required")
                            Text("System Settings > Privacy > Camera").font(.caption)
                        }.foregroundColor(.white)
                    )
                    .cornerRadius(8)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .measure: measurePane
                    case .camera:
                        CameraView(settings: settingsModel,
                                   store: profileStore,
                                   metrics: metrics,
                                   capture: { await cameraManager.captureFrame() },
                                   onTuned: { measureOnly() })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Text(settingsModel.isConnected ? settingsModel.deviceName : "")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Quit PodcastReady") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 760, height: 720)
        .onAppear {
            connectCamera()
            // Not in the Camera tab's onAppear: the header control and the
            // launch profile both need the light before that tab is ever opened.
            Task { await settingsModel.connectLight() }
        }
        .onChange(of: cameraManager.selectedCamera) { _, _ in connectCamera() }
    }

    private var header: some View {
        HStack {
            Text("PodcastReady").font(.headline)
            lightButton
            Spacer()
            Button(action: measureOnly) {
                if isMeasuring {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    Label("Measure", systemImage: "ruler")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isMeasuring || isAnalyzing || !cameraManager.isAuthorized)

            Button(action: analyzeSetup) {
                if isAnalyzing {
                    ProgressView().controlSize(.small).padding(.horizontal, 8)
                } else {
                    Label("Analyze Setup", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAnalyzing || isMeasuring || !cameraManager.isAuthorized)

            Button(action: { showSettings.toggle() }) { Image(systemName: "gear") }
                .buttonStyle(.borderless)
        }
    }

    /// Light on/off from anywhere in the app — it is the first thing you touch
    /// before recording and the last thing you want to go hunting for.
    @ViewBuilder
    private var lightButton: some View {
        let light = settingsModel.light
        if let state = light.state {
            Button {
                Task { await light.apply(on: !state.on) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: state.on ? "lightbulb.fill" : "lightbulb")
                        .foregroundColor(state.on ? .yellow : .secondary)
                    Text(state.on ? "\(state.brightness)% · \(state.kelvin)K" : "Light off")
                        .font(.caption)
                        .foregroundColor(state.on ? .primary : .secondary)
                }
            }
            .buttonStyle(.borderless)
            .help(state.on ? "Turn the light off" : "Turn the light on")
        } else {
            Button {
                Task { await light.rediscover() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb.slash").foregroundColor(.secondary)
                    Text("Find light").font(.caption).foregroundColor(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Search the network for an Elgato light")
        }
    }

    @ViewBuilder
    private var measurePane: some View {
        if let metrics {
            MetricsView(metrics: metrics)
            if analysisResult != nil { Divider() }
        }
        if let result = analysisResult {
            AnalysisResultView(result: result)
        } else if let errorMessage {
            Text(errorMessage).font(.caption).foregroundColor(.red)
        } else if KeychainManager.retrieve() == nil {
            Text("Add your Anthropic API key in Settings to use Analyze.")
                .font(.caption).foregroundColor(.secondary)
        } else if metrics == nil {
            Text("Click Measure for the numbers, or Analyze Setup to add Claude's read.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Actions

    private func connectCamera() {
        settingsModel.connect(to: cameraManager.selectedCamera)
        // Apply the launch profile once, and only after the camera is reachable —
        // applying to a camera that is not there yet is how a "saved" profile
        // silently fails to take.
        guard !didApplyLaunchProfile,
              settingsModel.isConnected,
              let name = profileStore.applyOnLaunch,
              let profile = profileStore.profile(named: name) else { return }
        didApplyLaunchProfile = true
        settingsModel.apply(profile)
    }

    private func measureOnly() {
        isMeasuring = true
        errorMessage = nil
        analysisResult = nil

        Task {
            guard let imageData = await cameraManager.captureFrame() else {
                await MainActor.run { errorMessage = "Failed to capture frame."; isMeasuring = false }
                return
            }
            let measured = FrameMetricsAnalyzer.measure(imageData: imageData)
            await MainActor.run {
                metrics = measured
                if measured == nil { errorMessage = "Could not measure this frame." }
                if let name = profileStore.applyOnLaunch, let p = profileStore.profile(named: name) {
                    settingsModel.compareToProfile(p, metrics: measured)
                }
                isMeasuring = false
            }
        }
    }

    private func analyzeSetup() {
        isAnalyzing = true
        errorMessage = nil

        Task {
            do {
                guard let imageData = await cameraManager.captureFrame() else {
                    await MainActor.run { errorMessage = "Failed to capture frame."; isAnalyzing = false }
                    return
                }
                let measured = FrameMetricsAnalyzer.measure(imageData: imageData)
                await MainActor.run { metrics = measured }

                let result = try await analysisService.analyze(imageData: imageData, metrics: measured)
                await MainActor.run { analysisResult = result; isAnalyzing = false }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAnalyzing = false
                }
            }
        }
    }
}
