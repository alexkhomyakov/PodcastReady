import Foundation

// A profile is settings PLUS the picture those settings produced.
//
// Storing settings alone does not give a repeatable look, which is the whole
// objective here. The same exposure and white balance under different light
// produce a different picture — measured on this rig, opening the window
// shutter moved the wall behind the head from 66 to 160 and the neutral
// reference from R−B +3 to −37 with the camera untouched.
//
// So the target metrics travel with the settings. Restoring a profile puts the
// camera back; comparing against the stored targets says whether the PICTURE
// came back, which is the thing that actually has to be constant.

struct MetricSnapshot: Codable, Equatable {
    var forehead: Double?
    var keyFill: Double?
    var faceOverWall: Double?
    var shirtOverFace: Double?
    var shirtRB: Double?
    var wallRB: Double?
    var clipPct: Double
    var crushPct: Double

    init(_ m: FrameMetrics) {
        forehead = m.forehead
        keyFill = m.keyFillRatio
        faceOverWall = m.faceOverWall
        shirtOverFace = m.shirtOverFace
        shirtRB = m.shirtRB
        wallRB = m.wallRB
        clipPct = m.clipPct
        crushPct = m.crushPct
    }
}

struct CameraProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// UVCControlID.rawValue -> value
    var settings: [String: Int]
    /// The light is part of the look, so it is part of the profile. Restoring
    /// camera settings alone under a different light gives a different picture,
    /// which is the whole thing this is trying to prevent.
    var light: ElgatoState?
    var targets: MetricSnapshot?
    var createdAt: Date = Date()

    func value(for control: UVCControlID) -> Int? { settings[control.rawValue] }
}

/// One drifted number, with how far off it is.
struct ProfileDrift: Identifiable {
    let id = UUID()
    let label: String
    let saved: String
    let now: String
    let significant: Bool
}

enum ProfileComparison {
    /// Tolerances are per-metric because the metrics are not comparable. A face
    /// 10 luma darker is invisible; a neutral reference 10 off is a colour cast
    /// you can see.
    static func drift(saved: MetricSnapshot, current: FrameMetrics) -> [ProfileDrift] {
        var out: [ProfileDrift] = []

        func compare(_ label: String, _ a: Double?, _ b: Double?, tolerance: Double, format: String = "%.0f") {
            guard let a, let b else { return }
            out.append(ProfileDrift(label: label,
                                    saved: String(format: format, a),
                                    now: String(format: format, b),
                                    significant: abs(a - b) > tolerance))
        }

        compare("Forehead", saved.forehead, current.forehead, tolerance: 12)
        compare("Key : fill", saved.keyFill, current.keyFillRatio, tolerance: 0.5, format: "%.1f")
        compare("Face − wall", saved.faceOverWall, current.faceOverWall, tolerance: 25)
        compare("Top R−B", saved.shirtRB, current.shirtRB, tolerance: 12)
        compare("Wall R−B", saved.wallRB, current.wallRB, tolerance: 15)
        compare("Crushed %", saved.crushPct, current.crushPct, tolerance: 5, format: "%.1f")
        return out
    }
}

// MARK: - Storage

final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [CameraProfile] = []
    /// Applied automatically when the app launches and the camera appears.
    @Published var applyOnLaunch: String? {
        didSet { UserDefaults.standard.set(applyOnLaunch, forKey: Self.launchKey) }
    }

    private static let launchKey = "PodcastReady.applyOnLaunchProfile"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PodcastReady", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("camera-profiles.json")
    }

    init() {
        applyOnLaunch = UserDefaults.standard.string(forKey: Self.launchKey)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CameraProfile].self, from: data) else { return }
        profiles = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Writing is atomic. A profile store that can be truncated by a crash is
    /// worse than none — it silently loses the settings it exists to protect.
    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func save(_ profile: CameraProfile) {
        if let index = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[index] = profile          // overwrite by name, keep one per name
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
    }

    func delete(_ profile: CameraProfile) {
        profiles.removeAll { $0.id == profile.id }
        if applyOnLaunch == profile.name { applyOnLaunch = nil }
        persist()
    }

    func profile(named name: String) -> CameraProfile? {
        profiles.first { $0.name == name }
    }
}
