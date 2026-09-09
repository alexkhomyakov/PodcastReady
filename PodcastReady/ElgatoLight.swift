import Foundation

// Elgato key/ring light control over its local HTTP API, so the light lives in
// the same app as the camera and the measurements.
//
// No reverse engineering and no third-party library: the light advertises
// itself over Bonjour as `_elg._tcp` and serves JSON on port 9123.
//
// Two things about this API are easy to get wrong:
//
//  1. Temperature is in MIREDS, not Kelvin, and the scale is inverted —
//     a HIGHER mired value is a WARMER light. 331 mired is ~3020 K.
//  2. A PUT replaces the whole light object, so writing a remembered state
//     clobbers whatever changed since. Every write here reads first. (Learned
//     the hard way: a PUT built from a stale reading switched the light off.)

struct ElgatoState: Equatable, Codable {
    var on: Bool
    var brightness: Int     // 0...100
    var kelvin: Int         // 2900...7000, what people actually think in

    static let kelvinRange = 2900...7000
}

private func kelvinToMired(_ k: Int) -> Int {
    min(344, max(143, 1_000_000 / max(1, k)))
}
private func miredToKelvin(_ m: Int) -> Int {
    let k = 1_000_000 / max(1, m)
    return (k / 50) * 50            // the device quantises; don't show false precision
}

@MainActor
final class ElgatoLight: ObservableObject {
    /// Shared, because the menubar menu and the popover's ContentView are two
    /// separate view trees. Two instances would each cache their own idea of
    /// whether the light is on, and the menu would go stale the moment the
    /// panel changed anything.
    static let shared = ElgatoLight()

    @Published private(set) var host: String?
    @Published private(set) var displayName: String?
    @Published private(set) var state: ElgatoState?
    @Published private(set) var status: String?

    private static let hostKey = "PodcastReady.elgatoHost"
    private let browser = BonjourBrowser()

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey)
    }

    var isConnected: Bool { host != nil && state != nil }

    func discoverAndRead() async {
        if host == nil {
            status = "Looking for an Elgato light…"
            host = await browser.findFirstElgato()
            if let host { UserDefaults.standard.set(host, forKey: Self.hostKey) }
        }
        guard host != nil else {
            // The commonest cause is not the network. macOS gates Bonjour
            // browsing behind Local Network permission, and the app cannot see
            // anything for the launch during which the prompt appears — so the
            // first run after any rebuild looks exactly like a missing light.
            status = "No Elgato light found. If macOS asked for Local Network permission, allow it and relaunch — the app can't browse during the launch it was asked."
            return
        }
        await refresh()
    }

    /// Forget the cached address and search again — the light gets a new one
    /// when it reconnects to Wi-Fi.
    func rediscover() async {
        host = nil
        UserDefaults.standard.removeObject(forKey: Self.hostKey)
        state = nil
        await discoverAndRead()
    }

    @discardableResult
    func refresh() async -> ElgatoState? {
        guard let host else { return nil }
        guard let data = try? await get("http://\(host)/elgato/lights"),
              let parsed = Self.parse(data) else {
            status = "Light did not respond."
            state = nil
            return nil
        }
        state = parsed
        status = nil
        if displayName == nil,
           let info = try? await get("http://\(host)/elgato/accessory-info"),
           let json = try? JSONSerialization.jsonObject(with: info) as? [String: Any] {
            displayName = json["productName"] as? String
        }
        return parsed
    }

    /// Applies only the fields given, on top of a FRESH read.
    @discardableResult
    func apply(on: Bool? = nil, brightness: Int? = nil, kelvin: Int? = nil) async -> ElgatoState? {
        guard let host else { return nil }
        guard let current = await refresh() else { return nil }

        let next = ElgatoState(
            on: on ?? current.on,
            brightness: min(100, max(0, brightness ?? current.brightness)),
            kelvin: min(ElgatoState.kelvinRange.upperBound,
                        max(ElgatoState.kelvinRange.lowerBound, kelvin ?? current.kelvin)))

        let body: [String: Any] = [
            "numberOfLights": 1,
            "lights": [[
                "on": next.on ? 1 : 0,
                "brightness": next.brightness,
                "temperature": kelvinToMired(next.kelvin),
            ]],
        ]
        guard let data = try? await put("http://\(host)/elgato/lights", body: body),
              let parsed = Self.parse(data) else {
            status = "Could not set the light."
            return nil
        }
        state = parsed
        return parsed
    }

    // MARK: HTTP

    private func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 4
        return try await URLSession.shared.data(for: request).0
    }

    private func put(_ url: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.data(for: request).0
    }

    private static func parse(_ data: Data) -> ElgatoState? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lights = json["lights"] as? [[String: Any]],
              let first = lights.first else { return nil }
        return ElgatoState(
            on: (first["on"] as? Int ?? 0) == 1,
            brightness: first["brightness"] as? Int ?? 0,
            kelvin: miredToKelvin(first["temperature"] as? Int ?? 200))
    }
}

// MARK: - Bonjour

/// Resolves the first `_elg._tcp` service to a host:port.
private final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var service: NetService?
    private var continuation: CheckedContinuation<String?, Never>?

    func findFirstElgato(timeout: TimeInterval = 4) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let browser = NetServiceBrowser()
            browser.delegate = self
            // Schedule on the MAIN run loop explicitly. This function is
            // nonisolated async, so it runs on a cooperative-pool thread whose
            // run loop is never pumped — the browser would sit there and find
            // nothing, silently, until the timeout.
            browser.schedule(in: .main, forMode: .common)
            browser.searchForServices(ofType: "_elg._tcp.", inDomain: "local.")
            self.browser = browser

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(nil)
            }
        }
    }

    private func finish(_ result: String?) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.stop()
        browser = nil
        continuation.resume(returning: result)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        self.service = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { finish(nil); return }
        // hostName arrives with a trailing dot: "elgato-ring-light-e196.local."
        finish("\(hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName):\(sender.port)")
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }
}
