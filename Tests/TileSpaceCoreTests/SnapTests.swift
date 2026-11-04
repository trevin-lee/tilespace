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
