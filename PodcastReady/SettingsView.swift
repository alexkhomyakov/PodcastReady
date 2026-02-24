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
        .frame(width: 720, height: 400)
    }
}
