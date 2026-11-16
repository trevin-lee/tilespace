import CoreGraphics
import XCTest
@testable import TileSpaceCore

// The MacBook above-left of the ultrawide, roughly as set up (visible areas lose the menu bar).
let macbook = Screen(name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                     visible: CGRect(x: 0, y: 33, width: 1728, height: 1084))
let wide = Screen(name: "Odyssey", frame: CGRect(x: 1728, y: 0, width: 5120, height: 1440),
                  visible: CGRect(x: 1728, y: 25, width: 5120, height: 1415))
let both = [macbook, wide]

final class SnapTests: XCTestCase {
    func testHalvesCoverTheDisplay() {
        let l = placement(.leftHalf, in: wide.visible), r = placement(.rightHalf, in: wide.visible)
        XCTAssertEqual(l.maxX, r.minX)
        XCTAssertEqual(l.width + r.width, wide.visible.width)
        XCTAssertEqual(l.height, wide.visible.height)
    }

    func testThirdsCoverTheDisplay() {
        let v = CGRect(x: 0, y: 0, width: 1001, height: 500)
        let f = placement(.firstThird, in: v), c = placement(.centerThird, in: v), l = placement(.lastThird, in: v)
        XCTAssertEqual(f.maxX, c.minX); XCTAssertEqual(c.maxX, l.minX); XCTAssertEqual(l.maxX, v.maxX)
    }

    func testThirdsStackOnPortraitDisplays() {
        let v = CGRect(x: 0, y: 0, width: 1000, height: 1800)
        XCTAssertEqual(placement(.firstThird, in: v), CGRect(x: 0, y: 0, width: 1000, height: 600))
    }

    func testRepeatedLeftHalfMovesToTheDisplayOnTheLeft() {
        let w = CGRect(x: 3000, y: 300, width: 800, height: 600)
        let first = snap(.leftHalf, window: w, last: nil, screens: both)!
        XCTAssertEqual(first.rect, placement(.leftHalf, in: wide.visible))
        let second = snap(.leftHalf, window: first.rect, last: LastSnap(pressed: .leftHalf, result: first.result), screens: both)!
        XCTAssertEqual(second.result, .rightHalf)
        XCTAssertEqual(second.rect, placement(.rightHalf, in: macbook.visible))
        // and once more: the left half of that display
        let third = snap(.leftHalf, window: second.rect, last: LastSnap(pressed: .leftHalf, result: second.result), screens: both)!
        XCTAssertEqual(third.rect, placement(.leftHalf, in: macbook.visible))
    }

    func testAWindowAlreadyInPlaceCountsAsARepeat() {
        // no memory of the last snap (the CLI), but the window sits exactly on the right half
        let r = snap(.rightHalf, window: placement(.rightHalf, in: macbook.visible), last: nil, screens: both)!
        XCTAssertEqual(r.rect, placement(.leftHalf, in: wide.visible))
    }

    func testRepeatedFirstThirdCycles() {
        var w = CGRect(x: 2000, y: 200, width: 500, height: 500)
        var last: LastSnap?
        var seen: [SnapAction] = []
        for _ in 0..<4 {
            let r = snap(.firstThird, window: w, last: last, screens: both)!
            seen.append(r.result); w = r.rect; last = LastSnap(pressed: .firstThird, result: r.result)
        }
        XCTAssertEqual(seen, [.firstThird, .centerThird, .lastThird, .firstThird])
    }

    func testMaximizeHeightKeepsTheColumn() {
        let w = CGRect(x: 2000, y: 200, width: 700, height: 500)
        XCTAssertEqual(snap(.maximizeHeight, window: w, last: nil, screens: both)!.rect,
                       CGRect(x: 2000, y: 25, width: 700, height: 1415))
    }

    func testLargerKeepsEdgesAgainstTheDisplay() {
        let half = placement(.leftHalf, in: wide.visible)
        let r = snap(.larger, window: half, last: nil, screens: both)!.rect
        XCTAssertEqual(r.minX, wide.visible.minX)
        XCTAssertEqual(r.width, half.width + 30)
        XCTAssertEqual(r.height, wide.visible.height)
    }

    func testSmallerStopsAtAQuarter() {
        let tiny = CGRect(x: 2000, y: 200, width: 1290, height: 400)
        XCTAssertEqual(snap(.smaller, window: tiny, last: nil, screens: both)!.rect, tiny)
    }

    func testNextDisplayKeepsAPlacement() {
        let r = snap(.nextDisplay, window: placement(.firstThird, in: macbook.visible), last: nil, screens: both)!
        XCTAssertEqual(r.rect, placement(.firstThird, in: wide.visible))
    }

    func testNextDisplayKeepsAFloatingWindowsSize() {
        let w = CGRect(x: 400, y: 300, width: 800, height: 500)
        let r = snap(.nextDisplay, window: w, last: nil, screens: both)!.rect
        XCTAssertEqual(r.size, w.size)
        XCTAssertTrue(wide.visible.contains(r))
    }

    func testCLINames() {
        XCTAssertEqual(SnapAction.firstTwoThirds.cliName, "first-two-thirds")
        XCTAssertEqual(SnapAction(cliName: "left-half"), .leftHalf)
    }
}

// A window as an app with size limits keeps it: it goes where it's put, at the nearest size the
// app allows.
final class LimitedWindow {
    var frame: CGRect
    let minSize: CGSize, maxSize: CGSize
    var sets = 0

    init(_ frame: CGRect, min: CGSize = .zero, max: CGSize = CGSize(width: 1e6, height: 1e6)) {
        self.frame = frame; minSize = min; maxSize = max
    }

    func set(_ r: CGRect) {
        sets += 1
        frame = CGRect(x: r.minX, y: r.minY, width: min(max(r.width, minSize.width), maxSize.width),
                       height: min(max(r.height, minSize.height), maxSize.height))
    }

    // snap it the way the app does: work out the frame, set it, and settle the window there
    @discardableResult
    func snap(_ action: SnapAction, last: LastSnap? = nil) -> SnapResult {
        let r = TileSpaceCore.snap(action, window: frame, last: last, screens: both)!
        put(action, at: r.rect)
        return r
    }

    func put(_ action: SnapAction, at asked: CGRect) {
        frame = settle(action, at: asked, from: frame, screens: both, set: set, read: { self.frame })
    }
}

// Windows that don't take the size a snap asks for: System Settings, chat and music apps...
final class SizeLimitTests: XCTestCase {
    let floating = CGRect(x: 300, y: 200, width: 1300, height: 800)   // on the MacBook

    func testAWindowTooWideForTheRightHalfStaysOnTheDisplay() {
        let w = LimitedWindow(floating, min: CGSize(width: 1000, height: 300))
        w.snap(.rightHalf)
        XCTAssertEqual(w.frame, CGRect(x: 728, y: 33, width: 1000, height: 1084))   // not 864...1864
    }

    func testAWindowTooTallForTheBottomHalfStaysOnTheDisplay() {
        let w = LimitedWindow(floating, min: CGSize(width: 300, height: 700))
        w.snap(.bottomHalf)
        XCTAssertEqual(w.frame, CGRect(x: 0, y: 417, width: 1728, height: 700))     // not 575...1275
        w.snap(.bottomRight)
        XCTAssertEqual(w.frame, CGRect(x: 864, y: 417, width: 864, height: 700))
    }

    func testRepeatingLastThirdStaysOnTheDisplayItsOn() {
        let w = LimitedWindow(floating, min: CGSize(width: 1200, height: 300))
        let first = w.snap(.lastThird)
        XCTAssertEqual(w.frame, CGRect(x: 528, y: 33, width: 1200, height: 1084))   // not 1152...2352, mostly on the ultrawide
        let second = w.snap(.lastThird, last: LastSnap(pressed: .lastThird, result: first.result))
        XCTAssertEqual(second.result, .centerThird)
        XCTAssertEqual(screen(for: w.frame, in: both), macbook)
        XCTAssertEqual(w.frame.minX, 528)   // as far right as the center third gets
    }

    func testAWindowMovedToASmallerDisplayStaysOnIt() {
        // against the ultrawide's right edge; a fourth as wide on the MacBook is under its minimum
        let w = LimitedWindow(CGRect(x: 5648, y: 25, width: 1200, height: 1415), min: CGSize(width: 600, height: 300))
        w.snap(.previousDisplay)
        XCTAssertEqual(w.frame, CGRect(x: 1128, y: 33, width: 600, height: 1084))   // not 1323...1923
    }

    func testAWindowDroppedOnAnEdgeStaysOnTheDisplay() {
        let w = LimitedWindow(floating, min: CGSize(width: 1000, height: 300))
        let t = dropTarget(at: CGPoint(x: 1727, y: 500), window: w.frame, screens: [macbook])!
        w.put(t.action, at: t.rect)
        XCTAssertEqual(w.frame, CGRect(x: 728, y: 33, width: 1000, height: 1084))
    }

    func testAWindowBiggerThanTheDisplayKeepsItsTopLeftCorner() {
        let w = LimitedWindow(floating, min: CGSize(width: 2000, height: 1200))
        w.snap(.bottomRight)
        XCTAssertEqual(w.frame, CGRect(x: 0, y: 33, width: 2000, height: 1200))
    }

    func testAWindowThatTakesTheSizeIsSetOnce() {
        let w = LimitedWindow(floating)
        w.snap(.rightHalf)
        XCTAssertEqual(w.frame, placement(.rightHalf, in: macbook.visible))
        XCTAssertEqual(w.sets, 1)
        // one that comes out smaller (Terminal rounds to rows) stays where it was put
        let rows = LimitedWindow(floating, max: CGSize(width: 860, height: 1075))
        rows.snap(.rightHalf)
        XCTAssertEqual(rows.frame, CGRect(x: 864, y: 33, width: 860, height: 1075))
        XCTAssertEqual(rows.sets, 1)
    }

    func testLargerAndSmallerLeaveAWindowOfAFixedSizeWhereItIs() {
        let fixed = CGRect(x: 600, y: 400, width: 715, height: 500)
        let w = LimitedWindow(fixed, min: fixed.size, max: fixed.size)
        for _ in 0..<5 { w.snap(.larger) }
        XCTAssertEqual(w.frame, fixed)   // not 15pt further up and left with each press
        for _ in 0..<5 { w.snap(.smaller) }
        XCTAssertEqual(w.frame, fixed)
    }

    func testSmallerLeavesAWindowAtItsMinimumSizeWhereItIs() {
        let small = CGRect(x: 900, y: 500, width: 700, height: 500)
        let w = LimitedWindow(small, min: small.size)
        for _ in 0..<12 { w.snap(.smaller) }
        XCTAssertEqual(w.frame, small)   // not walked off the display's right edge
        // against the right edge, as a right half that's as narrow as it gets
        let half = LimitedWindow(placement(.rightHalf, in: macbook.visible), min: CGSize(width: 864, height: 300))
        for _ in 0..<3 { half.snap(.smaller) }
        XCTAssertEqual(half.frame, placement(.rightHalf, in: macbook.visible))
    }

    func testAWindowThatGrowsOrShrinksPartOfTheWayKeepsItsMiddleOrItsEdge() {
        // 10pt short of its widest: grows by that, around its middle
        let w = LimitedWindow(CGRect(x: 600, y: 400, width: 700, height: 500), max: CGSize(width: 710, height: 1e6))
        w.snap(.larger)
        XCTAssertEqual(w.frame, CGRect(x: 595, y: 385, width: 710, height: 530))
        // a right half 14pt over its narrowest: shrinks by that, still against the right edge
        let half = LimitedWindow(placement(.rightHalf, in: macbook.visible), min: CGSize(width: 850, height: 300))
        half.snap(.smaller)
        XCTAssertEqual(half.frame, CGRect(x: 878, y: 33, width: 850, height: 1084))
    }

    func testMaximizeHeightKeepsAColumnThatIsOffTheDisplay() {
        // hanging off the MacBook's left side, and too tall for its display
        let w = LimitedWindow(CGRect(x: -200, y: 300, width: 800, height: 600), min: CGSize(width: 300, height: 1200))
        w.snap(.maximizeHeight)
        XCTAssertEqual(w.frame, CGRect(x: -200, y: 33, width: 800, height: 1200))
    }
}

final class DragSnapTests: XCTestCase {
    func testEdgesAndCorners() {
        let f = wide.frame
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.minX + 2, y: f.midY), in: f), .left)
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.maxX, y: f.midY), in: f), .right)   // the far edge counts
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.midX, y: f.minY + 1), in: f), .top)
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.midX, y: f.maxY - 1), in: f), .bottom)
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.minX + 20, y: f.minY + 2), in: f), .topLeft)
        XCTAssertEqual(snapEdge(at: CGPoint(x: f.maxX - 2, y: f.maxY - 20), in: f), .bottomRight)
        XCTAssertNil(snapEdge(at: CGPoint(x: f.minX + 30, y: f.midY), in: f))
        XCTAssertNil(snapEdge(at: CGPoint(x: f.minX - 1, y: f.midY), in: f))
    }

    func testDropTargetsUseTheSnapAreas() {
        let w = CGRect(x: 2000, y: 300, width: 800, height: 600)
        let left = dropTarget(at: CGPoint(x: wide.frame.minX + 1, y: 700), window: w, screens: both)!
        XCTAssertEqual(left, DropTarget(action: .leftHalf, rect: placement(.leftHalf, in: wide.visible)))
        let bottom = dropTarget(at: CGPoint(x: 4000, y: wide.frame.maxY - 1), window: w, screens: both)!
        XCTAssertEqual(bottom.action, .centerThird)
        let corner = dropTarget(at: CGPoint(x: wide.frame.maxX - 1, y: 1), window: w, screens: both)!
        XCTAssertEqual(corner.action, .lastThreeFourths)
        XCTAssertNil(dropTarget(at: CGPoint(x: 4000, y: 700), window: w, screens: both))
    }

    func testMaximizeHeightByDragKeepsTheColumnOnTheTargetDisplay() {
        // dragged from the ultrawide up to the MacBook's top edge, hanging off its right side
        let w = CGRect(x: 1500, y: 300, width: 800, height: 600)
        let t = dropTarget(at: CGPoint(x: 900, y: 1), window: w, screens: both)!
        XCTAssertEqual(t.action, .maximizeHeight)
        XCTAssertEqual(t.rect, CGRect(x: 928, y: 33, width: 800, height: 1084))
    }

    func testUnsnapKeepsTheCursorOnTheTitleBar() {
        let half = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let r = unsnapFrame(half, size: CGSize(width: 800, height: 600), cursor: CGPoint(x: 1500, y: 10))
        XCTAssertEqual(r, CGRect(x: 900, y: 0, width: 800, height: 600))   // cursor 3/4 across before and after
    }
}

final class MacOSTilingTests: XCTestCase {
    func testOnByDefaultFromMacOS15() {
        XCTAssertTrue(macOSTilesByDrag(macOSVersion: 15) { _ in nil })
        XCTAssertFalse(macOSTilesByDrag(macOSVersion: 14) { _ in nil })
    }

    func testEitherSettingCounts() {
        let edgesOnly: [String: Any] = ["EnableTilingByEdgeDrag": true, "EnableTopTilingByEdgeDrag": false]
        let topOnly: [String: Any] = ["EnableTilingByEdgeDrag": false]
        let off: [String: Any] = ["EnableTilingByEdgeDrag": false, "EnableTopTilingByEdgeDrag": false]
        XCTAssertTrue(macOSTilesByDrag(macOSVersion: 26) { edgesOnly[$0] })
        XCTAssertTrue(macOSTilesByDrag(macOSVersion: 26) { topOnly[$0] })
        XCTAssertFalse(macOSTilesByDrag(macOSVersion: 26) { off[$0] })
    }
}
