// Rectangle-style snap actions, as pure geometry so they can be tested without moving
// windows. Behaves like Rectangle with its "across monitor" repeat mode and no gaps:
// repeating Left/Right Half moves the window to the next display over; repeating First or
// Last Third cycles through the thirds; thirds and fourths stack on portrait displays.
import CoreGraphics

public enum SnapAction: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case firstFourth, lastThreeFourths
    case maximize, maximizeHeight, center, larger, smaller, restore
    case previousDisplay, nextDisplay

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .firstFourth: "First Fourth"
        case .lastThreeFourths: "Last Three Fourths"
        case .maximize: "Maximize"
        case .maximizeHeight: "Maximize Height"
        case .center: "Center"
        case .larger: "Larger"
        case .smaller: "Smaller"
        case .restore: "Restore"
        case .previousDisplay: "Previous Display"
        case .nextDisplay: "Next Display"
        }
    }

    // "left-half" for the command line
    public var cliName: String { rawValue.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined() }
    public init?(cliName: String) {
        guard let a = Self.allCases.first(where: { $0.cliName == cliName }) else { return nil }
        self = a
    }

    // actions that put a window in a fixed spot on a display, so they can be recognized later
    static let placements: [SnapAction] = [.leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight, .firstThird, .centerThird, .lastThird,
        .firstTwoThirds, .centerTwoThirds, .lastTwoThirds, .firstFourth, .lastThreeFourths, .maximize]
}

// The last snap applied to a window: the key pressed and where it actually put the window.
public struct LastSnap: Equatable {
    public let pressed: SnapAction
    public let result: SnapAction
    public init(pressed: SnapAction, result: SnapAction) { self.pressed = pressed; self.result = result }
}

public struct SnapResult: Equatable {
    public let rect: CGRect
    public let result: SnapAction   // can differ from the key pressed (repeats, other display)
    public init(rect: CGRect, result: SnapAction) { self.rect = rect; self.result = result }
}

// Where `action` puts a window that's at `window`. `last` is the previous snap if the window
// hasn't moved since; without it, a window sitting exactly in a snap spot counts as there.
// Restore is up to the caller (it needs the frame from before the first snap).
public func snap(_ action: SnapAction, window: CGRect, last: LastSnap?, screens: [Screen]) -> SnapResult? {
    guard let here = screen(for: window, in: screens) else { return nil }
    let last = last ?? recognize(window, on: here).map { LastSnap(pressed: $0, result: $0) }
    let i = screens.firstIndex(of: here)!
    let prev = screens.count > 1 ? screens[(i + screens.count - 1) % screens.count] : nil
    let next = screens.count > 1 ? screens[(i + 1) % screens.count] : nil
    func at(_ a: SnapAction, _ s: Screen) -> SnapResult { SnapResult(rect: placement(a, in: s.visible), result: a) }

    switch action {
    case .leftHalf:
        if last?.result == .leftHalf, let prev { return at(.rightHalf, prev) }
        return at(.leftHalf, here)
    case .rightHalf:
        if last?.result == .rightHalf, let next { return at(.leftHalf, next) }
        return at(.rightHalf, here)
    case .firstThird, .lastThird:
        let cycle: [SnapAction] = action == .firstThird ? [.firstThird, .centerThird, .lastThird]
                                                        : [.lastThird, .centerThird, .firstThird]
        if last?.pressed == action, let r = last?.result, let k = cycle.firstIndex(of: r) {
            return at(cycle[(k + 1) % 3], here)
        }
        return at(action, here)
    case .maximizeHeight:
        let v = here.visible
        return SnapResult(rect: CGRect(x: window.minX, y: v.minY, width: window.width, height: v.height), result: action)
    case .center:
        let v = here.visible
        let w = min(window.width, v.width), h = min(window.height, v.height)
        return SnapResult(rect: CGRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h), result: action)
    case .larger, .smaller:
        return SnapResult(rect: resized(window, by: action == .larger ? 30 : -30, in: here.visible), result: action)
    case .previousDisplay, .nextDisplay:
        guard let to = action == .nextDisplay ? next : prev else { return nil }
        if let r = last?.result, SnapAction.placements.contains(r) { return at(r, to) }
        return SnapResult(rect: transfer(window, from: here.visible, to: to.visible), result: action)
    case .restore:
        return nil
    default:
        return at(action, here)
    }
}

// The rect for a placement action within a display's visible area.
public func placement(_ a: SnapAction, in v: CGRect) -> CGRect {
    let portrait = v.height > v.width
    // a slice from `from` to `to` (fractions) along the long side
    func along(_ from: CGFloat, _ to: CGFloat) -> CGRect {
        portrait
            ? CGRect(x: v.minX, y: v.minY + (v.height * from).rounded(.down), width: v.width,
                     height: (v.height * to).rounded(.down) - (v.height * from).rounded(.down))
            : CGRect(x: v.minX + (v.width * from).rounded(.down), y: v.minY,
                     width: (v.width * to).rounded(.down) - (v.width * from).rounded(.down), height: v.height)
    }
    let hw = (v.width / 2).rounded(.down), hh = (v.height / 2).rounded(.down)
    switch a {
    case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: hw, height: v.height)
    case .rightHalf: return CGRect(x: v.minX + hw, y: v.minY, width: v.width - hw, height: v.height)
    case .topHalf: return CGRect(x: v.minX, y: v.minY, width: v.width, height: hh)
    case .bottomHalf: return CGRect(x: v.minX, y: v.minY + hh, width: v.width, height: v.height - hh)
    case .topLeft: return CGRect(x: v.minX, y: v.minY, width: hw, height: hh)
    case .topRight: return CGRect(x: v.minX + hw, y: v.minY, width: v.width - hw, height: hh)
    case .bottomLeft: return CGRect(x: v.minX, y: v.minY + hh, width: hw, height: v.height - hh)
    case .bottomRight: return CGRect(x: v.minX + hw, y: v.minY + hh, width: v.width - hw, height: v.height - hh)
    case .firstThird: return along(0, 1.0 / 3)
    case .centerThird: return along(1.0 / 3, 2.0 / 3)
    case .lastThird: return along(2.0 / 3, 1)
    case .firstTwoThirds: return along(0, 2.0 / 3)
    case .centerTwoThirds: return along(1.0 / 6, 5.0 / 6)
    case .lastTwoThirds: return along(1.0 / 3, 1)
    case .firstFourth: return along(0, 0.25)
    case .lastThreeFourths: return along(0.25, 1)
    default: return v
    }
}

// The placement a window is sitting in, if any (within 2pt, since some apps round sizes).
func recognize(_ window: CGRect, on s: Screen) -> SnapAction? {
    SnapAction.placements.first { a in
        let r = placement(a, in: s.visible)
        return abs(r.minX - window.minX) <= 2 && abs(r.minY - window.minY) <= 2
            && abs(r.width - window.width) <= 2 && abs(r.height - window.height) <= 2
    }
}

// Grow or shrink by `step` in each direction, keeping any edge that touches the display's edge
// against it. Won't shrink below a quarter of the display.
func resized(_ w: CGRect, by step: CGFloat, in v: CGRect) -> CGRect {
    let near: CGFloat = 5
    let left = abs(w.minX - v.minX) <= near, right = abs(w.maxX - v.maxX) <= near
    let top = abs(w.minY - v.minY) <= near, bottom = abs(w.maxY - v.maxY) <= near
    var r = w
    if step < 0, left, right, top, bottom {
        r = w.insetBy(dx: -step / 2, dy: -step / 2)   // maximized: shrink toward the middle
    } else {
        r.size.width += step; r.origin.x -= (step / 2).rounded(.down)
        if right { r.origin.x = v.maxX - r.width }
        if left { r.origin.x = v.minX; if right { r.size.width = v.width } }
        r.size.height += step; r.origin.y -= (step / 2).rounded(.down)
        if bottom { r.origin.y = v.maxY - r.height }
        if top { r.origin.y = v.minY; if bottom { r.size.height = v.height } }
    }
    if r.width >= v.width { r.size.width = v.width; r.origin.x = v.minX }
    if r.height >= v.height { r.size.height = v.height; r.origin.y = v.minY }
    if step < 0, r.width < v.width / 4 || r.height < v.height / 4 { return w }
    return r
}

// Move a window to another display. Along each axis: a window touching an edge keeps the same
// share of the display, anchored to that edge (so a left half stays a left half); a floating
// one keeps its size and its relative position.
func transfer(_ w: CGRect, from s: CGRect, to d: CGRect) -> CGRect {
    func axis(_ lo: CGFloat, _ len: CGFloat, _ sLo: CGFloat, _ sLen: CGFloat, _ dLo: CGFloat, _ dLen: CGFloat) -> (CGFloat, CGFloat) {
        let atLo = abs(lo - sLo) <= 5, atHi = abs(lo + len - (sLo + sLen)) <= 5
        if atLo || atHi {
            let l = min(dLen, (len / sLen * dLen).rounded())
            return (atLo ? dLo : dLo + dLen - l, l)
        }
        let l = min(len, dLen)
        let mid = (lo + len / 2 - sLo) / sLen   // where the middle was, as a fraction
        return (max(dLo, min(dLo + dLen - l, (dLo + mid * dLen - l / 2).rounded())), l)
    }
    let (x, width) = axis(w.minX, w.width, s.minX, s.width, d.minX, d.width)
    let (y, height) = axis(w.minY, w.height, s.minY, s.height, d.minY, d.height)
    return CGRect(x: x, y: y, width: width, height: height)
}
