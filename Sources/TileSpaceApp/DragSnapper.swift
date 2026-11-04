// Snapping by dragging a window to a screen edge or corner, like Rectangle: while a window is
// dragged, a preview shows where it would go; letting go there snaps it, and Esc cancels.
// Dragging a snapped window away gives it back its size from before the snap.
import AppKit
import TileSpaceCore

final class DragSnapper {
    private let snapper: Snapper
    private let footprint = Footprint()
    private var monitor: Any?

    // the drag in progress
    private var el: AXUIElement?, id: Int?, startFrame: CGRect?
    private var displays: [Screen] = []
    private var moving = false, ignoring = false
    private var restore: CGRect?   // where Restore puts it back after a drop
    private var target: DropTarget?

    init(snapper: Snapper) { self.snapper = snapper }

    func start() {
        guard monitor == nil else { return }
        // global monitors see other apps' events (which is all we want); Esc needs Accessibility
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) {
            [unowned self] in handle($0)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        reset()
    }

    private func handle(_ e: NSEvent) {
        guard let p = e.cgEvent?.location else { return }
        switch e.type {
        case .leftMouseDown:
            reset()
            el = window(at: p)
            id = el.flatMap(windowID(of:))
            startFrame = id.flatMap(windowFrame)
            displays = screens()
        case .leftMouseDragged:
            guard !ignoring, let el, let id, let start = startFrame, let now = windowFrame(id) else { return }
            if !moving {
                if now.size != start.size { ignoring = true; return }   // a resize, not a move
                if now.origin == start.origin { return }
                moving = true
                if let before = snapper.restoreFrame(of: id, at: start) {
                    snapper.forget(id)
                    restore = before
                    setFrame(el, unsnapFrame(now, size: before.size, cursor: p))
                } else {
                    restore = start
                }
            }
            update(at: p, window: now)
        case .leftMouseUp:
            // judge where it was let go, not the last drag event (fast drags skip ahead)
            if moving, !ignoring, let el, let id, let now = windowFrame(id) {
                update(at: p, window: now)
                if let target { snapper.drop(el, id: id, on: target, restore: restore ?? now) }
            }
            reset()
        case .keyDown where e.keyCode == 53:   // Esc: no snap this time, but the drag goes on
            if moving { ignoring = true; target = nil; footprint.hide() }
        default:
            break
        }
    }

    private func update(at p: CGPoint, window: CGRect) {
        let t = dropTarget(at: p, window: window, screens: displays)
        guard t != target else { return }
        target = t
        if let t { footprint.show(t.rect) } else { footprint.hide() }
    }

    private func reset() {
        el = nil; id = nil; startFrame = nil
        moving = false; ignoring = false
        restore = nil; target = nil
        footprint.hide()
    }
}

// The translucent preview of where a dropped window will go.
final class Footprint {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

    init() {
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let radius: CGFloat = 16
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        // a stretchable rounded-rect mask, since a layer corner radius doesn't clip the blur
        let d = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: d, height: d), flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        glass.maskImage = mask

        let border = NSView()
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        border.autoresizingMask = [.width, .height]
        glass.addSubview(border)
        panel.contentView = glass
    }

    // `rect` in Accessibility coordinates (top-left origin)
    func show(_ rect: CGRect) {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let r = NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().setFrame(r, display: true) }
        } else {
            panel.setFrame(r, display: true)
            panel.contentView?.subviews.first?.frame = panel.contentView!.bounds
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }
}
