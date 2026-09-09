import SwiftUI

struct CameraView: View {
    @ObservedObject var settings: CameraSettingsModel
    @ObservedObject var store: ProfileStore
    let metrics: FrameMetrics?
    let capture: () async -> Data?
    let onTuned: () -> Void

    @State private var selectedProfile: String = ""
    @State private var showSaveSheet = false
    @State private var newProfileName = ""

    private static let groups: [(String, [UVCControlID])] = [
        ("Exposure", [.exposureAuto, .exposureTime, .gain]),
        ("White Balance", [.whiteBalanceAuto, .whiteBalance]),
        ("Focus", [.focusAuto, .focusAbsolute]),
        ("Zoom / Pan / Tilt", [.zoomAbsolute, .panAbsolute, .tiltAbsolute]),
        ("Image", [.brightness, .contrast, .saturation, .sharpness]),
        ("Advanced", [.powerLineFrequency, .backlightCompensation]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !settings.isConnected {
                Label(settings.status ?? "No UVC camera connected.", systemImage: "camera.badge.ellipsis")
                    .font(.caption).foregroundColor(.orange)
            } else {
                profileBar
                if !settings.drift.isEmpty { driftPanel }
                magicFixBar
                if let outcome = settings.tuneOutcome { outcomePanel(outcome) }
                Divider()
                lightSection
                Divider()
                controlsList
            }
        }
        .onAppear { syncSelection() }
        .sheet(isPresented: $showSaveSheet) { saveSheet }
    }

    // MARK: Profiles

    private var profileBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedProfile) {
                Text("— profile —").tag("")
                ForEach(store.profiles) { p in Text(p.name).tag(p.name) }
            }
            .labelsHidden()
            .frame(width: 190)

            Button("Apply") {
                guard let p = store.profile(named: selectedProfile) else { return }
                settings.apply(p)
                settings.compareToProfile(p, metrics: metrics)
            }
            .disabled(selectedProfile.isEmpty)

            Button("Save as…") {
                newProfileName = selectedProfile
                showSaveSheet = true
            }

            Button("Delete") {
                if let p = store.profile(named: selectedProfile) { store.delete(p); selectedProfile = "" }
            }
            .disabled(selectedProfile.isEmpty)

            Spacer()

            Toggle("Apply on launch", isOn: Binding(
                get: { store.applyOnLaunch == selectedProfile && !selectedProfile.isEmpty },
                set: { store.applyOnLaunch = $0 ? selectedProfile : nil }))
                .toggleStyle(.checkbox)
                .disabled(selectedProfile.isEmpty)
                .font(.caption)
        }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save camera profile").font(.headline)
            Text("Stores the current camera settings and the numbers this picture measures, so a later apply can tell you whether the look actually came back.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $newProfileName)
            if metrics == nil {
                Label("No measurement yet — the profile will save settings only. Press Measure first to capture targets.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                Button("Save") {
                    let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    store.save(settings.currentProfile(named: name, metrics: metrics))
                    selectedProfile = name
                    showSaveSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var driftPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Against saved profile").font(.caption).fontWeight(.semibold)
            ForEach(settings.drift) { d in
                HStack(spacing: 6) {
                    Image(systemName: d.significant ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(d.significant ? .orange : .green).frame(width: 12)
                    Text(d.label).font(.caption).frame(width: 90, alignment: .leading)
                    Text("saved \(d.saved) → now \(d.now)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(d.significant ? .primary : .secondary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: Magic fix

    private var magicFixBar: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await settings.autoTune(capture: capture)
                    onTuned()
                }
            } label: {
                if settings.isTuning {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Tuning…") }
                } else {
                    Label("Magic Fix", systemImage: "wand.and.stars")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(settings.isTuning)

            Toggle("Hold", isOn: $settings.holdSettings)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Re-apply these settings if the camera drifts off them.")

            if let correction = settings.lastCorrection {
                Text(correction).font(.caption).foregroundColor(.orange).lineLimit(1)
            } else if let last = settings.tuneSteps.last {
                Text(last.message).font(.caption).foregroundColor(.secondary).lineLimit(1)
            } else if !settings.isTuning {
                Text("Adjusts exposure and white balance until the picture matches target.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func outcomePanel(_ outcome: AutoTuneOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // What it MEASURED, always. Without this "nothing to change" is
            // indistinguishable from "it did nothing" — and the run captures its
            // own frame, so it can legitimately disagree with the last Measure
            // when a value sits near the edge of its band.
            if let m = outcome.finalMetrics {
                HStack(spacing: 10) {
                    if let f = m.forehead {
                        Text("forehead \(Int(f))")
                            .foregroundColor(MetricTarget.forehead.contains(f) ? .green : .orange)
                    }
                    if let r = m.keyFillRatio {
                        Text(String(format: "key:fill %.1f:1", r))
                            .foregroundColor(MetricTarget.keyFill.contains(r) ? .green : .orange)
                    }
                    if let rb = m.shirtRB {
                        Text(String(format: "top R−B %+.0f", rb))
                            .foregroundColor(
                                abs(rb - MetricTarget.warmthAim(level: m.shirt ?? 0))
                                    <= MetricTarget.tolerance(level: m.shirt ?? 0,
                                                              percent: MetricTarget.tolerancePercent)
                                ? .green : .orange)
                    }
                    Text(String(format: "clipped %.2f%%", m.clipPct)).foregroundColor(.secondary)
                }
                .font(.system(.caption, design: .monospaced))
            }

            ForEach(outcome.fixed, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundColor(.green)
            }
            if outcome.fixed.isEmpty {
                Label("Nothing needed changing — the numbers above were already in range.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(outcome.needsYou, id: \.self) { line in
                Label(line, systemImage: "hand.raised.fill")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !outcome.steps.isEmpty {
                DisclosureGroup("What it tried (\(outcome.steps.count) steps)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(outcome.steps) { step in
                            Text("\(step.iteration). \(step.message)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    // MARK: Light

    @ViewBuilder
    private var lightSection: some View {
        let light = settings.light
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Light").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                if let name = light.displayName {
                    Text(name).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if light.state == nil {
                    Button("Find light") { Task { await light.rediscover() } }
                        .font(.caption)
                } else {
                    Button("Re-scan") { Task { await light.rediscover() } }
                        .font(.caption).buttonStyle(.borderless).foregroundColor(.secondary)
                }
            }

            if let state = light.state {
                HStack(spacing: 8) {
                    Text("Power").font(.caption).frame(width: 130, alignment: .leading)
                    Toggle("", isOn: Binding(
                        get: { state.on },
                        set: { v in Task { await light.apply(on: v) } }))
                        .labelsHidden().toggleStyle(.switch)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text("Brightness").font(.caption).frame(width: 130, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(state.brightness) },
                        set: { v in Task { await light.apply(brightness: Int(v.rounded())) } }),
                           in: 0...100)
                    Text("\(state.brightness)%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Temperature").font(.caption).frame(width: 130, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(state.kelvin) },
                        set: { v in Task { await light.apply(kelvin: Int(v.rounded())) } }),
                           in: Double(ElgatoState.kelvinRange.lowerBound)...Double(ElgatoState.kelvinRange.upperBound))
                    Text("\(state.kelvin)K")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Magic Fix ceiling").font(.caption).frame(width: 130, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(settings.maxLightBrightness) },
                        set: { settings.maxLightBrightness = Int($0.rounded()) }),
                           in: 20...100)
                    Text("\(settings.maxLightBrightness)%")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Face brightness").font(.caption).frame(width: 130, alignment: .leading)
                    Slider(value: $settings.faceBrightness, in: 110...180, step: 1)
                    Text(String(format: "%.0f", settings.faceBrightness))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                Text("What Magic Fix aims the face at. ~165 is a conventionally lit portrait; ~120 is low key — light falls off sooner and the frame reads calmer. Neither is more correct.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("Warmth").font(.caption).frame(width: 130, alignment: .leading)
                    Slider(value: $settings.warmth, in: 0...20, step: 1)
                    Text(String(format: "%.0f%%", settings.warmth))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                Text("Warmth as a share of the top's own brightness, so it means the same in a bright or a dark frame. A natural-looking reference frame measured 8%; past ~15% skin starts to read orange.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Magic Fix will not take the light past the ceiling; it uses camera exposure beyond that. Keep the temperature near your camera's white balance — mismatched sources split the two sides of your face into different colours.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = light.status {
                Text(status).font(.caption).foregroundColor(.orange)
            }
        }
    }

    // MARK: Controls

    private var controlsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.groups, id: \.0) { title, ids in
                    let available = ids.compactMap { id in settings.controls.first { $0.id == id && $0.isSupported } }
                    if !available.isEmpty {
                        Text(title).font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                        ForEach(available) { control in row(control) }
                        if title == "Focus" { focusTools }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ control: UVCControlState) -> some View {
        HStack(spacing: 8) {
            Text(control.id.label).font(.caption).frame(width: 130, alignment: .leading)

            switch control.id.kind {
            case .toggle:
                Toggle("", isOn: Binding(
                    get: { control.current != 0 },
                    set: { settings.set(control.id, to: $0 ? 1 : 0) }))
                    .labelsHidden().toggleStyle(.switch)
                Spacer()

            case .options(let all):
                // Only offer values the camera says it accepts. Powerline
                // frequency advertises four modes in the spec; this camera
                // reports min=1 max=2, so Disabled and Auto would be dead
                // buttons that silently do nothing.
                let usable = all.filter { control.minimum == control.maximum
                    || ($0.value >= control.minimum && $0.value <= control.maximum)
                    || $0.value == control.current }
                Picker("", selection: Binding(
                    get: { control.current },
                    set: { settings.set(control.id, to: $0) })) {
                        ForEach(usable, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 260)
                Spacer()

            case .continuous:
                Slider(value: settings.binding(for: control.id),
                       in: Double(control.minimum)...Double(max(control.maximum, control.minimum + 1)))
                Text("\(control.current)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .opacity(isOverriddenByAuto(control.id) ? 0.4 : 1)
        .help(isOverriddenByAuto(control.id) ? "Turn off the matching Auto switch to control this." : "")
    }

    /// Focus by measurement instead of by eye. Scores each motor position on
    /// the sharpness of the eyes only, so it cannot lock onto the microphone
    /// the way the camera's own autofocus does.
    private var focusTools: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Spacer().frame(width: 130)
                Button {
                    Task { await settings.findFocus(narrow: false, capture: capture) }
                } label: {
                    if settings.isFocusing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sweeping…") }
                    } else {
                        Label("Focus on my face", systemImage: "scope")
                    }
                }
                .disabled(settings.isFocusing)

                Button("Re-focus (narrow)") {
                    Task { await settings.findFocus(narrow: true, capture: capture) }
                }
                .disabled(settings.isFocusing)
                .help("Searches only near the current position — quick, and cannot jump to the mic.")
                Spacer()
            }
            if let r = settings.focusResult, !r.message.isEmpty {
                HStack {
                    Spacer().frame(width: 130)
                    Text(r.message)
                        .font(.caption)
                        .foregroundColor(r.best == nil ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            } else if settings.isFocusing {
                HStack {
                    Spacer().frame(width: 130)
                    Text("Hold still — sweeping the focus motor and scoring your eyes at each stop.")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func isOverriddenByAuto(_ id: UVCControlID) -> Bool {
        func value(_ control: UVCControlID) -> Int? {
            settings.controls.first { $0.id == control }?.current
        }
        switch id {
        // AE Mode is a bitmap, not a boolean: 1 is manual, anything else is one
        // of the automatic modes, and exposure time is ignored in those.
        case .exposureTime, .gain:
            guard let mode = value(.exposureAuto) else { return false }
            return mode != 1
        case .focusAbsolute:  return value(.focusAuto) == 1
        case .whiteBalance:   return value(.whiteBalanceAuto) == 1
        default:              return false
        }
    }

    private func syncSelection() {
        guard selectedProfile.isEmpty else { return }
        // Prefer the launch profile, else the most recently saved one. Landing
        // on "— profile —" with Apply and Delete greyed out reads as "your
        // profiles are gone" when they are simply not selected.
        if let launch = store.applyOnLaunch, store.profile(named: launch) != nil {
            selectedProfile = launch
        } else if let newest = store.profiles.max(by: { $0.createdAt < $1.createdAt }) {
            selectedProfile = newest.name
        }
    }
}
