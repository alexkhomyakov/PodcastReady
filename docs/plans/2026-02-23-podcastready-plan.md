# PodcastReady Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS menubar app that shows a live camera preview and uses Claude Vision API to analyze podcast video setup quality.

**Architecture:** SwiftUI menubar-only app using AVFoundation for camera access and SwiftAnthropic SDK for Claude Vision API. The app lives in the menubar with a popover containing a live camera preview, an "Analyze Setup" button, and a results checklist. API key is stored in macOS Keychain.

**Tech Stack:** Swift 5.9+, SwiftUI, AVFoundation, SwiftAnthropic SDK, macOS 14.0+ (Sonoma), Swift Package Manager

---

### Task 1: Scaffold Xcode Project

**Files:**
- Create: `PodcastReady/PodcastReadyApp.swift`
- Create: `PodcastReady/Info.plist`
- Create: `Package.swift`

**Step 1: Create the Swift Package / Xcode project structure**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
mkdir -p PodcastReady
```

Create `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastReady",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "1.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "PodcastReady",
            dependencies: ["SwiftAnthropic"],
            path: "PodcastReady"
        ),
    ]
)
```

Create `PodcastReady/PodcastReadyApp.swift`:

```swift
import SwiftUI

@main
struct PodcastReadyApp: App {
    // Hide dock icon — menubar only
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty Settings scene required but we use menubar only
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApp.setActivationPolicy(.accessory)
    }
}
```

**Step 2: Verify it builds**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Build succeeds (empty app, no UI yet).

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: scaffold PodcastReady macOS app with SwiftAnthropic dependency"
```

---

### Task 2: Menubar Icon + Popover Shell

**Files:**
- Create: `PodcastReady/MenuBarManager.swift`
- Create: `PodcastReady/ContentView.swift`
- Modify: `PodcastReady/PodcastReadyApp.swift`

**Step 1: Create MenuBarManager**

Create `PodcastReady/MenuBarManager.swift`:

```swift
import AppKit
import SwiftUI

class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    init() {
        setupMenuBar()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "PodcastReady")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
```

**Step 2: Create ContentView placeholder**

Create `PodcastReady/ContentView.swift`:

```swift
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
```

**Step 3: Wire up in PodcastReadyApp**

Replace `PodcastReady/PodcastReadyApp.swift`:

```swift
import SwiftUI

@main
struct PodcastReadyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var menuBarManager = MenuBarManager()

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

**Step 4: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds. Running the app shows a camera icon in the menubar. Clicking it opens a popover with placeholder content.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add menubar icon and popover shell with placeholder UI"
```

---

### Task 3: Live Camera Preview

**Files:**
- Create: `PodcastReady/CameraManager.swift`
- Create: `PodcastReady/CameraPreviewView.swift`
- Modify: `PodcastReady/ContentView.swift`

**Step 1: Create CameraManager**

Create `PodcastReady/CameraManager.swift`:

```swift
import AVFoundation
import AppKit

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var captureCompletion: ((Data?) -> Void)?

    @Published var isAuthorized = false
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?

    override init() {
        super.init()
        checkAuthorization()
    }

    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted { self?.setupSession() }
                }
            }
        default:
            isAuthorized = false
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Discover cameras
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discovery.devices

        // Use first available camera
        guard let camera = discovery.devices.first else {
            session.commitConfiguration()
            return
        }
        selectedCamera = camera

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
        } catch {
            print("Camera setup error: \(error)")
        }

        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func captureFrame() async -> Data? {
        await withCheckedContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            settings.flashMode = .off
            captureCompletion = { data in
                continuation.resume(returning: data)
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func switchCamera(to device: AVCaptureDevice) {
        session.beginConfiguration()

        // Remove existing input
        for input in session.inputs {
            session.removeInput(input)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                selectedCamera = device
            }
        } catch {
            print("Camera switch error: \(error)")
        }

        session.commitConfiguration()
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        captureCompletion?(data)
        captureCompletion = nil
    }
}
```

**Step 2: Create CameraPreviewView**

Create `PodcastReady/CameraPreviewView.swift`:

```swift
import SwiftUI
import AVFoundation

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(previewLayer)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

**Step 3: Update ContentView to use live camera**

Replace `PodcastReady/ContentView.swift`:

```swift
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
```

**Step 4: Add camera usage description to Info.plist**

Create `PodcastReady/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSCameraUsageDescription</key>
    <string>PodcastReady needs camera access to analyze your podcast video setup.</string>
</dict>
</plist>
```

**Step 5: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds. Running shows live camera preview in the popover. macOS prompts for camera permission on first launch.

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add live camera preview with AVFoundation"
```

---

### Task 4: Keychain Storage for API Key

**Files:**
- Create: `PodcastReady/KeychainManager.swift`

**Step 1: Create KeychainManager**

Create `PodcastReady/KeychainManager.swift`:

```swift
import Foundation
import Security

struct KeychainManager {
    private static let service = "com.podcastready.apikey"
    private static let account = "anthropic-api-key"

    static func save(apiKey: String) -> Bool {
        guard let data = apiKey.data(using: .utf8) else { return false }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func retrieve() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
```

**Step 2: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds clean.

**Step 3: Commit**

```bash
git add -A
git commit -m "feat: add Keychain manager for secure API key storage"
```

---

### Task 5: Analysis Service (Claude Vision API)

**Files:**
- Create: `PodcastReady/AnalysisService.swift`
- Create: `PodcastReady/AnalysisResult.swift`

**Step 1: Create AnalysisResult model**

Create `PodcastReady/AnalysisResult.swift`:

```swift
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
    }
}
```

**Step 2: Create AnalysisService**

Create `PodcastReady/AnalysisService.swift`:

```swift
import Foundation
import SwiftAnthropic

class AnalysisService {
    private let systemPrompt = """
        You are a podcast video setup analyst. Evaluate this webcam frame for podcast recording quality.

        Score each category as GOOD or NEEDS_ADJUSTMENT with a brief, specific, actionable suggestion (one sentence max).

        Categories:
        - Lighting: brightness, evenness, shadows on face
        - Color Temperature: warm/cool balance, skin tone accuracy
        - Framing: head position, eye level, headroom, rule of thirds
        - Background: distractions, clutter, evenness, visual noise

        Return ONLY valid JSON in this exact format, no markdown:
        {
          "lighting": {"status": "GOOD", "suggestion": "..."},
          "colorTemperature": {"status": "NEEDS_ADJUSTMENT", "suggestion": "..."},
          "framing": {"status": "GOOD", "suggestion": "..."},
          "background": {"status": "GOOD", "suggestion": "..."}
        }
        """

    func analyze(imageData: Data) async throws -> AnalysisResult {
        guard let apiKey = KeychainManager.retrieve() else {
            throw AnalysisError.noAPIKey
        }

        let service = AnthropicServiceFactory.service(apiKey: apiKey)
        let base64Image = imageData.base64EncodedString()

        let message = MessageParameter(
            model: .claude37Sonnet,
            messages: [
                .init(
                    role: .user,
                    content: .list([
                        .image(.init(type: .base64, mediaType: .jpeg, data: base64Image)),
                        .text("Analyze this podcast video setup.")
                    ])
                )
            ],
            maxTokens: 500,
            system: .text(systemPrompt)
        )

        let response = try await service.createMessage(message)

        // Extract text from response
        guard let textBlock = response.content.first,
              case .text(let text) = textBlock else {
            throw AnalysisError.invalidResponse
        }

        // Parse JSON response
        guard let jsonData = text.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(AnalysisResult.self, from: jsonData)
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
```

**Step 3: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds. Note — the exact SwiftAnthropic API surface may need adjustment based on the SDK version resolved. If build fails, check the SDK's README for current API usage and adjust `MessageParameter` construction accordingly.

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: add Claude Vision analysis service with JSON response parsing"
```

---

### Task 6: Results UI (Checklist View)

**Files:**
- Create: `PodcastReady/AnalysisResultView.swift`
- Modify: `PodcastReady/ContentView.swift`

**Step 1: Create AnalysisResultView**

Create `PodcastReady/AnalysisResultView.swift`:

```swift
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
```

**Step 2: Update ContentView with full flow**

Replace `PodcastReady/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    private let analysisService = AnalysisService()

    @State private var analysisResult: AnalysisResult?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            // Header
            Text("PodcastReady")
                .font(.headline)

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
```

**Step 3: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds. Full flow works: camera preview → analyze button → loading → results checklist (requires API key to be set, which we add next).

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: add analysis results UI and wire up full analyze flow"
```

---

### Task 7: Settings View (API Key + Camera Selection)

**Files:**
- Create: `PodcastReady/SettingsView.swift`
- Modify: `PodcastReady/ContentView.swift`

**Step 1: Create SettingsView**

Create `PodcastReady/SettingsView.swift`:

```swift
import SwiftUI
import AVFoundation

struct SettingsView: View {
    @Binding var isPresented: Bool
    @ObservedObject var cameraManager: CameraManager

    @State private var apiKey: String = ""
    @State private var savedSuccessfully = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            // API Key
            VStack(alignment: .leading, spacing: 4) {
                Text("Anthropic API Key")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                SecureField("sk-ant-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Key") {
                        if KeychainManager.save(apiKey: apiKey) {
                            savedSuccessfully = true
                            apiKey = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                savedSuccessfully = false
                            }
                        }
                    }
                    .disabled(apiKey.isEmpty)

                    if savedSuccessfully {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }

                    Spacer()

                    if KeychainManager.retrieve() != nil {
                        Label("Key stored", systemImage: "key.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Camera selection
            if !cameraManager.availableCameras.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Camera")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Picker("Camera", selection: Binding(
                        get: { cameraManager.selectedCamera?.uniqueID ?? "" },
                        set: { id in
                            if let camera = cameraManager.availableCameras.first(where: { $0.uniqueID == id }) {
                                cameraManager.switchCamera(to: camera)
                            }
                        }
                    )) {
                        ForEach(cameraManager.availableCameras, id: \.uniqueID) { camera in
                            Text(camera.localizedName).tag(camera.uniqueID)
                        }
                    }
                    .labelsHidden()
                }
            }

            Spacer()
        }
        .padding()
        .frame(width: 400, height: 520)
    }
}
```

**Step 2: Add settings toggle to ContentView**

Add a settings state and gear button to `PodcastReady/ContentView.swift`. Add these to the existing view:

At the top of the struct, add:

```swift
@State private var showSettings = false
```

Replace the header `Text("PodcastReady")` with:

```swift
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
```

Wrap the entire `VStack` body inside a conditional so settings and main view swap:

```swift
var body: some View {
    if showSettings {
        SettingsView(isPresented: $showSettings, cameraManager: cameraManager)
    } else {
        mainView
    }
}

// Move existing VStack content to a computed property:
private var mainView: some View {
    VStack(spacing: 12) {
        // ... existing content with updated header ...
    }
    .padding()
    .frame(width: 400, height: 520)
}
```

**Step 3: Build and verify**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
```

Expected: Builds. Clicking gear icon shows settings with API key input and camera picker. "Done" returns to main view.

**Step 4: Commit**

```bash
git add -A
git commit -m "feat: add settings view with API key management and camera selection"
```

---

### Task 8: Polish and Final Integration

**Files:**
- Modify: `PodcastReady/ContentView.swift`
- Modify: `PodcastReady/MenuBarManager.swift`

**Step 1: Add a "Quit" option**

In `PodcastReady/ContentView.swift`, add a quit button at the bottom of the main view, before `Spacer()`:

```swift
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
```

**Step 2: Add first-launch experience**

In `PodcastReady/ContentView.swift`, show a hint when no API key is stored. Add this after the Analyze button:

```swift
// First-launch hint
if KeychainManager.retrieve() == nil && analysisResult == nil && errorMessage == nil {
    Text("Add your Anthropic API key in Settings to get started.")
        .font(.caption)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
}
```

**Step 3: Add entitlements for camera access**

Create `PodcastReady/PodcastReady.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**Step 4: Build and run full end-to-end test**

```bash
cd /Users/alex/Documents/GitHub/PodcastReady
swift build
.build/debug/PodcastReady
```

Manual test checklist:
1. App appears in menubar with camera icon (no dock icon)
2. Clicking icon opens popover with live camera preview
3. First-launch hint shows "Add your Anthropic API key..."
4. Clicking gear opens settings
5. Enter API key → Save → "Saved" confirmation appears
6. Switch camera if multiple available
7. Click Done → back to main view
8. Click "Analyze Setup" → loading spinner → results appear
9. Each category shows green checkmark or orange warning with suggestion
10. Click "Quit PodcastReady" exits the app

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add quit button, first-launch hint, and entitlements"
```

---

### Task 9: Add .gitignore and README

**Files:**
- Create: `.gitignore`
- Create: `README.md`

**Step 1: Create .gitignore**

Create `.gitignore`:

```
.build/
.swiftpm/
*.xcodeproj
xcuserdata/
DerivedData/
.DS_Store
```

**Step 2: Create README**

Create `README.md`:

```markdown
# PodcastReady

A macOS menubar app that analyzes your podcast video setup using AI before you hit record.

## Features

- Live camera preview in a menubar popover
- One-click AI analysis of your video setup via Claude Vision
- Scores lighting, color temperature, framing, and background
- Actionable suggestions for each category
- Secure API key storage in macOS Keychain
- Camera selection for multi-camera setups

## Requirements

- macOS 14.0 (Sonoma) or later
- Anthropic API key (get one at https://console.anthropic.com)

## Build & Run

\`\`\`bash
swift build
.build/debug/PodcastReady
\`\`\`

## Setup

1. Launch the app (appears in your menubar as a camera icon)
2. Click the icon → Settings (gear icon)
3. Enter your Anthropic API key and save
4. Click Done, then "Analyze Setup" to check your video setup
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: add .gitignore and README"
```

---

## Summary

| Task | Description | Estimated Steps |
|------|-------------|----------------|
| 1 | Scaffold Xcode project + SPM | 3 |
| 2 | Menubar icon + popover shell | 5 |
| 3 | Live camera preview (AVFoundation) | 6 |
| 4 | Keychain manager for API key | 3 |
| 5 | Claude Vision analysis service | 4 |
| 6 | Results checklist UI + full flow wiring | 4 |
| 7 | Settings view (API key + camera picker) | 4 |
| 8 | Polish: quit, first-launch hint, entitlements | 5 |
| 9 | .gitignore + README | 3 |
| **Total** | | **37 steps** |
