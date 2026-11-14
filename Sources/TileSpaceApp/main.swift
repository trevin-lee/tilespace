// TileSpace: a menu-bar app for arranging windows, and the core that the `tilespace` command and
// agents talk to through its MCP server: Rectangle-style snapping by keyboard and by dragging to
// screen edges (each can be turned off in the menu), and moving windows between desktops.
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
        // counts as a repeat). Leave shortcuts and drag snapping to it while it runs.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [unowned self] n in
                let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if a?.bundleIdentifier == rectangle { updateShortcuts() }
            }
        }
        updateShortcuts()
        // tilespace://execute-action?name=left-half, like Rectangle's rectangle:// links
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // asks for Accessibility access the first time
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    var rectangleRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rectangle).isEmpty }

    func updateShortcuts() {
        hotkeys.unregisterAll()
        dragSnapper.stop()
        failed = []
        guard !rectangleRunning else { return }
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

    @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URLComponents(string: s),
              url.host == "execute-action", let name = url.queryItems?.first(where: { $0.name == "name" })?.value,
              let action = SnapAction(cliName: name) else { return NSSound.beep() }
        snapFocused(action)
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
