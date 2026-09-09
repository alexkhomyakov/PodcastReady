import AppKit
import SwiftUI

@MainActor
class MenuBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    init() {
        setupMenuBar()
        Task { @MainActor in
            // The menu needs the light's state before it is first opened.
            await ElgatoLight.shared.discoverAndRead()
            // And the light starts OFF. With launch-at-login the app opens every
            // time the Mac boots, and a light that came on with it would be lit
            // all day for the sake of a recording that happens once.
            await ElgatoLight.shared.apply(on: false)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "PodcastReady")
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 720, height: 640)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())
        self.popover = popover
    }

    /// Left click opens the panel; right click opens a short menu, so the light
    /// can be switched without waiting for the whole UI to appear.
    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let light = ElgatoLight.shared
        let menu = NSMenu()

        let state = light.state
        let title: String
        if state == nil {
            title = "Find light"
        } else if state!.on {
            title = "Turn light off  (\(state!.brightness)% · \(state!.kelvin)K)"
        } else {
            title = "Turn light on  (\(state!.brightness)% · \(state!.kelvin)K)"
        }
        let toggle = NSMenuItem(title: title, action: #selector(toggleLight), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open PodcastReady", action: #selector(togglePopover), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit PodcastReady",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attaching the menu permanently would make LEFT click open it too, so
        // it is attached for this click only and detached immediately after.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLight() {
        Task {
            let light = ElgatoLight.shared
            // Read first: the menu title was built from cached state, and the
            // light may have been changed from the Elgato app or the panel.
            guard let current = await light.refresh() else {
                await light.discoverAndRead()
                return
            }
            await light.apply(on: !current.on)
        }
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
