import Foundation
import ServiceManagement

// Launch at login via SMAppService (macOS 13+). No helper bundle, no login-item
// plist — the OS registers the main app itself.
//
// The state is deliberately READ FROM THE SYSTEM rather than mirrored into
// UserDefaults. A stored copy can disagree with reality — the user can remove
// the item in System Settings > General > Login Items, and a checkbox that
// still says "on" is worse than no checkbox.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `.requiresApproval` means macOS accepted it but the user has switched it
    /// off in System Settings; that is a real state and needs saying out loud
    /// rather than being reported as failure.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
