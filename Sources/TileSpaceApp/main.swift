// TileSpace: a menu-bar app for arranging windows, and the core that the `tilespace` command and
// agents talk to through its MCP server: Rectangle-style snapping by keyboard and by dragging to
// screen edges (each can be turned off in the menu), and moving windows between desktops (from
// the menu, a link, the command line or an agent).
import AppKit
import ApplicationServices
import Carbon
import TileSpaceCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let hotkeys = Hotkeys()
    let snapper = Snapper()
    lazy var dragSnapper = DragSnapper(snapper: snapper)
    lazy var tools = Tools(snapper: snapper)
    var failed: [SnapAction] = []   // shortcuts that couldn't be registered
    let rectangle = "com.knollsoft.Rectangle"
    var rectangleWatch: NSKeyValueObservation?
    var yielding = false            // whether shortcuts and drag snapping are left to Rectangle now
    let defaults = UserDefaults.standard

    // menu sections, in order
    let groups: [[SnapAction]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds],
        [.firstFourth, .lastThreeFourths],
        [.maximize, .maximizeHeight, .center, .larger, .smaller, .restore],
        [.previousDisplay, .nextDisplay],
    ]

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["shortcutsOn": true, "dragSnapOn": true])
        tools.start()
        // Launch at Login is on by default, so the MCP server is always there; turning it off in
        // the menu sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemSetUp") {
            UserDefaults.standard.set(true, forKey: "loginItemSetUp")
            if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        }
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "TileSpace")
        item.menu = NSMenu()
        item.menu!.delegate = self
        // Rectangle gets the same key presses and drags, so both would snap (and the second snap
        // counts as a repeat). Leave shortcuts and drag snapping to it while it runs. It has no
        // Dock icon, and macOS posts no launch or quit notifications for such apps, so watch
        // the list of running apps instead.
        rectangleWatch = NSWorkspace.shared.observe(\.runningApplications) { [unowned self] _, _ in
            DispatchQueue.main.async { if self.rectangleRunning != self.yielding { self.updateShortcuts() } }
        }
        updateShortcuts()
        // tilespace:// links
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // asks for Accessibility access the first time
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    var rectangleRunning: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == rectangle } }

    // macOS's own drag tiling (Desktop & Dock), read fresh so turning it off clears the notice
    var macOSTiling: Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        return macOSTilesByDrag(macOSVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            CFPreferencesCopyAppValue($0 as CFString, domain)
        }
    }

    func updateShortcuts() {
        hotkeys.unregisterAll()
        dragSnapper.stop()
        failed = []
        yielding = rectangleRunning
        guard !yielding else { return }
        if defaults.bool(forKey: "dragSnapOn") { dragSnapper.start() }
        guard defaults.bool(forKey: "shortcutsOn") else { return }
        for (action, s) in shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if !hotkeys.register(s, { [unowned self] in snapFocused(action) }) {
                failed.append(action)
                NSLog("couldn't set up the shortcut for %@", action.title)
            }
        }
    }

    func snapFocused(_ action: SnapAction) {
        do { try snapper.run(action) } catch { NSSound.beep() }
    }

    // rebuilt each time it opens, so the permission and login items are current
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        if rectangleRunning {
            menu.addItem(withTitle: "Shortcuts and drag snapping are off while Rectangle runs", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Quit Rectangle", action: #selector(quitRectangle), keyEquivalent: "").target = self
            menu.addItem(.separator())
        } else if !failed.isEmpty {
            menu.addItem(withTitle: "\(failed.count) shortcuts couldn't be set up", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        if !rectangleRunning, defaults.bool(forKey: "dragSnapOn"), macOSTiling {
            menu.addItem(withTitle: "macOS also tiles windows dragged to screen edges", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Turn Off macOS Tiling in System Settings…", action: #selector(openTilingSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        for group in groups {
            for action in group {
                let mi = menu.addItem(withTitle: action.title, action: #selector(runAction), keyEquivalent: "")
                mi.target = self
                mi.representedObject = action.rawValue
                if let s = shortcuts[action], !hotkeys.isEmpty, !failed.contains(action) {
                    mi.keyEquivalent = s.keyEquivalent
                    mi.keyEquivalentModifierMask = s.mods
                }
            }
            menu.addItem(.separator())
        }
        // moving the frontmost window to another desktop: the desktops as they are right now
        let move = menu.addItem(withTitle: "Move to Desktop", action: nil, keyEquivalent: "")
        move.submenu = NSMenu()
        let choices = moveChoices(displays: managedSpaces(), screenCount: NSScreen.screens.count, name: displayName)
        for c in choices {
            guard let display = c.display, let desktop = c.desktop else {
                // a display's name above its desktops, or the one line saying why there are none
                move.submenu!.addItem(choices.count > 1 ? .sectionHeader(title: c.title)
                                                        : NSMenuItem(title: c.title, action: nil, keyEquivalent: ""))
                continue
            }
            let mi = move.submenu!.addItem(withTitle: c.title, action: #selector(moveToDesktop), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["display": display, "desktop": desktop] as [String: Any]
        }
        menu.addItem(.separator())
        for (title, key) in [("Keyboard Shortcuts", "shortcutsOn"), ("Snap by Dragging to Screen Edges", "dragSnapOn")] {
            let mi = menu.addItem(withTitle: title, action: #selector(toggleSetting), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key
            mi.state = defaults.bool(forKey: key) ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "MCP Server: \(tools.status)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Copy MCP Server URL", action: #selector(copyURL), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add to Claude Code", action: #selector(addToClaudeCode), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit TileSpace", action: #selector(NSApplication.terminate), keyEquivalent: "q")
    }

    @objc func runAction(_ mi: NSMenuItem) {
        // the menu doesn't take focus from the frontmost app, so this acts on its window
        if let raw = mi.representedObject as? String, let a = SnapAction(rawValue: raw) { snapFocused(a) }
    }

    @objc func moveToDesktop(_ mi: NSMenuItem) {
        guard let c = mi.representedObject as? [String: Any], let display = c["display"] as? String,
              let desktop = c["desktop"] as? Int else { return }
        // once the menu has closed: a move takes a couple of seconds and switches desktops
        DispatchQueue.main.async {
            do { _ = try moveWindow(nil, toDesktop: desktop, display: display) } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't move the window"
                alert.informativeText = "\(error)".prefix(1).uppercased() + "\(error)".dropFirst()
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    // tilespace://execute-action?name=left-half, like Rectangle's rectangle:// links, and
    // tilespace://move-to-desktop?desktop=3. There's nowhere to show an error, so it beeps.
    @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        switch event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue.flatMap(linkCommand) {
        case .snap(let action):
            snapFocused(action)
        case .move(let desktop, let display, let follow):
            do { _ = try moveWindow(nil, toDesktop: desktop, display: display, follow: follow) } catch {
                NSLog("couldn't move the window: %@", "\(error)")
                NSSound.beep()
            }
        case nil:
            NSSound.beep()
        }
    }

    @objc func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverURL, forType: .string)
    }

    @objc func addToClaudeCode() {
        // a login shell, so `claude` is on the PATH the way it is in Terminal
        let (ok, output) = addToClaudeCodeConfig()
        let alert = NSAlert()
        alert.messageText = ok ? "Added TileSpace to Claude Code" : "Couldn't add TileSpace to Claude Code"
        alert.informativeText = ok ? "New Claude Code sessions have TileSpace's tools. In a running session, use /mcp to connect."
                                   : output
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quitRectangle() {
        NSRunningApplication.runningApplications(withBundleIdentifier: rectangle).forEach { $0.terminate() }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func openTilingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }

    @objc func toggleSetting(_ mi: NSMenuItem) {
        guard let key = mi.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        updateShortcuts()
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() }
        catch { NSAlert(error: error).runModal() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
