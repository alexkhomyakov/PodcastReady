import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Owns the UVC connection and the live control values for the UI.
@MainActor
final class CameraSettingsModel: ObservableObject {
    @Published private(set) var controls: [UVCControlState] = []
    @Published private(set) var isConnected = false
    @Published private(set) var deviceName = ""
    @Published var status: String?

    @Published private(set) var isTuning = false
    @Published private(set) var tuneSteps: [AutoTuneStep] = []
    @Published private(set) var tuneOutcome: AutoTuneOutcome?
    @Published private(set) var drift: [ProfileDrift] = []

    /// Re-asserts the settings if the camera drifts off them.
    ///
    /// CameraController pushes every setting once a second unconditionally. This
    /// reads first and only writes what actually moved, so the USB traffic is
    /// proportional to the problem — and a drift gets NAMED rather than silently
    /// papered over, which is how "it keeps resetting focus to auto" went
    /// undiagnosed.
    @Published var holdSettings = false {
        didSet { holdSettings ? startHold() : stopHold() }
    }
    @Published private(set) var lastCorrection: String?

    private var held: [UVCControlID: Int] = [:]
    private var holdTimer: Timer?

    @Published private(set) var isFocusing = false
    @Published private(set) var focusResult: FocusResult?

    let light = ElgatoLight.shared

    /// How bright Magic Fix may drive the light. A comfort limit, set by the
    /// person sitting in front of it — the loop has no way to know that 76% is
    /// unpleasant to work under.
    @Published var maxLightBrightness: Int = UserDefaults.standard.object(forKey: "PodcastReady.maxLightBrightness") as? Int ?? 70 {
        didSet { UserDefaults.standard.set(maxLightBrightness, forKey: "PodcastReady.maxLightBrightness") }
    }

    /// How warm the picture should render. Read by both the Top R−B row and
    /// Magic Fix, so the loop defends the look rather than correcting it away.
    /// Percent of level, not raw R-B. New key: the old absolute values do not
    /// convert, and silently reinterpreting a stored 20 as 20% would be a much
    /// heavier cast than anyone chose.
    @Published var warmth: Double = UserDefaults.standard.object(forKey: "PodcastReady.warmthPercent") as? Double ?? 8 {
        didSet { UserDefaults.standard.set(warmth, forKey: "PodcastReady.warmthPercent") }
    }

    /// How bright the face should be. Read by the Forehead row and by Magic Fix,
    /// so a low-key look is defended rather than corrected back to bright.
    @Published var faceBrightness: Double = UserDefaults.standard.object(forKey: "PodcastReady.foreheadTarget") as? Double ?? 165 {
        didSet { UserDefaults.standard.set(faceBrightness, forKey: "PodcastReady.foreheadTarget") }
    }

    /// SwiftUI does not observe an ObservableObject nested inside another one,
    /// so a change to the light never redrew anything watching this model. The
    /// symptom was a power button that worked once: it rendered with the old
    /// state and kept sending the same command. Forward the child's changes.
    private var lightObserver: AnyCancellable?

    private var camera: UVCCamera?
    private let tuner = AutoTuner()
    private let focusTuner = FocusTuner()

    init() {
        lightObserver = light.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func connectLight() async { await light.discoverAndRead() }

    func connect(to device: AVCaptureDevice?) {
        guard let device else {
            camera = nil; isConnected = false; deviceName = ""
            status = "No camera selected."
            return
        }
        deviceName = device.localizedName
        guard let cam = UVCCamera(device: device) else {
            camera = nil
            isConnected = false
            status = "\(device.localizedName) does not expose UVC controls."
            return
        }
        camera = cam
        isConnected = true
        status = nil
        refresh()
    }

    func refresh() {
        guard let camera else { return }
        controls = camera.readAll()
    }

    func binding(for id: UVCControlID) -> Binding<Double> {
        Binding(
            get: { Double(self.controls.first(where: { $0.id == id })?.current ?? 0) },
            set: { self.set(id, to: Int($0.rounded())) }
        )
    }

    func set(_ id: UVCControlID, to value: Int) {
        guard let camera else { return }
        camera.write(id, value: value)
        if holdSettings { held[id] = value }
        // Read back rather than trusting the write: a camera can clamp, or
        // refuse a control while another one is on auto.
        if let index = controls.firstIndex(where: { $0.id == id }) {
            controls[index].current = camera.read(id).current
        }
    }

    // MARK: Profiles

    func currentProfile(named name: String, metrics: FrameMetrics?) -> CameraProfile {
        var settings: [String: Int] = [:]
        for c in controls where c.isSupported { settings[c.id.rawValue] = c.current }
        return CameraProfile(name: name,
                             settings: settings,
                             light: light.state,
                             targets: metrics.map(MetricSnapshot.init))
    }

    /// Auto controls are written FIRST. Setting an absolute value while its auto
    /// counterpart is still on is silently ignored by the camera — the reason a
    /// restored profile can appear to apply and do nothing.
    func apply(_ profile: CameraProfile) {
        guard camera != nil else { return }
        let autos: [UVCControlID] = [.exposureAuto, .focusAuto, .whiteBalanceAuto]
        for id in autos {
            if let v = profile.value(for: id) { set(id, to: v) }
        }
        for id in UVCControlID.allCases where !autos.contains(id) {
            if let v = profile.value(for: id) { set(id, to: v) }
        }
        refresh()
        if let saved = profile.light {
            // Brightness and temperature only — never power. A profile is a
            // LOOK; whether the light is on right now is a moment-to-moment
            // decision, and with launch-at-login this would otherwise switch the
            // light on every time the Mac boots.
            Task { await light.apply(brightness: saved.brightness, kelvin: saved.kelvin) }
        }
        status = "Applied “\(profile.name)”."
    }

    func compareToProfile(_ profile: CameraProfile, metrics: FrameMetrics?) {
        guard let targets = profile.targets, let metrics else { drift = []; return }
        drift = ProfileComparison.drift(saved: targets, current: metrics)
    }

    // MARK: Holding settings

    private func startHold() {
        guard camera != nil else { return }
        held = [:]
        for c in controls where c.isSupported { held[c.id] = c.current }
        lastCorrection = nil
        holdTimer?.invalidate()
        // 5s, not 1s. A camera that drifts does it on a timescale of seconds to
        // minutes, and polling 14 controls every second is a lot of USB traffic
        // to catch something that rarely happens.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enforceHeldSettings() }
        }
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        held = [:]
        lastCorrection = nil
    }

    private func enforceHeldSettings() {
        guard let camera, holdSettings else { return }
        var corrected: [String] = []
        for (id, wanted) in held {
            let actual = camera.read(id).current
            if actual != wanted {
                camera.write(id, value: wanted)
                corrected.append("\(id.label) \(actual) → \(wanted)")
            }
        }
        if !corrected.isEmpty {
            lastCorrection = "Corrected: " + corrected.joined(separator: ", ")
            refresh()
        }
    }

    // MARK: Focus

    /// `narrow` searches only around the current position — fast, and it cannot
    /// wander onto the microphone or the wall. Use the full sweep once, then
    /// narrow for the rest of the setup's life.
    func findFocus(narrow: Bool, capture: @escaping () async -> Data?) async {
        guard let camera else { return }
        isFocusing = true
        focusResult = nil
        let result = await focusTuner.find(camera: camera,
                                           capture: capture,
                                           window: narrow ? 40 : nil) { _ in }
        focusResult = result
        refresh()
        if holdSettings, let best = result.best { held[.focusAbsolute] = best }
        isFocusing = false
    }

    // MARK: Magic fix

    func autoTune(capture: @escaping () async -> Data?) async {
        guard let camera else { return }
        isTuning = true
        tuneSteps = []
        tuneOutcome = nil

        let lightModel = light
        let outcome = await tuner.run(
            camera: camera,
            capture: capture,
            lightRead: { await MainActor.run { lightModel.state?.brightness } },
            lightWrite: { value in _ = await lightModel.apply(on: true, brightness: value) },
            maxLightBrightness: maxLightBrightness,
            onStep: { step in Task { @MainActor in self.tuneSteps.append(step) } })

        tuneOutcome = outcome
        refresh()
        // The loop changed things on purpose; hold the new values, not the old.
        if holdSettings { for c in controls where c.isSupported { held[c.id] = c.current } }
        isTuning = false
    }
}
