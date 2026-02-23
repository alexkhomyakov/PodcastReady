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
