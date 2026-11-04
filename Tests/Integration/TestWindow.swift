// A plain window for the integration test to move around. Ten times a second it writes
//   x y width height  screen-x y width height  visible-x y width height
// to the file given as the first argument: its frame, then the main display's whole and
// visible areas, all with a top-left origin like Accessibility. SIGUSR1 puts it back at
// 800x600. Dragging anywhere in it moves it (the app moves itself, as some apps do; macOS
// may ignore synthetic drags of a title bar).
//   swiftc Tests/Integration/TestWindow.swift -o build/TestWindow && build/TestWindow /tmp/frame
import AppKit

let out = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class DragView: NSView {
    var grab = NSPoint.zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { grab = e.locationInWindow }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let p = w.convertPoint(toScreen: e.locationInWindow)
        w.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
    }
}

let home = NSRect(x: 200, y: 200, width: 800, height: 600)
let window = NSWindow(contentRect: home, styleMask: [.titled, .resizable, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "tilespace test"
window.contentView = DragView()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

signal(SIGUSR1, SIG_IGN)
let reset = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
reset.setEventHandler { window.setFrame(window.frameRect(forContentRect: home), display: true) }
reset.resume()

Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let main = NSScreen.screens[0], h = main.frame.height
    func flip(_ r: NSRect) -> String { "\(Int(r.minX)) \(Int(h - r.maxY)) \(Int(r.width)) \(Int(r.height))" }
    try? "\(flip(window.frame)) \(flip(main.frame)) \(flip(main.visibleFrame))\n".write(toFile: out, atomically: true, encoding: .utf8)
}
app.run()
