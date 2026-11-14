import CoreGraphics
import XCTest
@testable import TileSpaceCore

final class DesktopShortcutTests: XCTestCase {
    func testCoversDesktops1To16() {
        XCTAssertEqual(desktopShortcut(1)?.key, 18)                     // Ctrl+1
        XCTAssertEqual(desktopShortcut(1)?.flags, .maskControl)
        XCTAssertEqual(desktopShortcut(10)?.key, 29)                    // Ctrl+0
        XCTAssertEqual(desktopShortcut(11)?.key, 18)                    // Ctrl+Option+1
        XCTAssertEqual(desktopShortcut(11)?.flags, [.maskControl, .maskAlternate])
        XCTAssertEqual(desktopShortcut(16)?.key, 22)                    // Ctrl+Option+6
    }

    func testHasNoneOutside1To16() {
        // 17-19 used to press Ctrl+Option+7-9, and 20 and up read past the end of the key table
        for n in [0, 17, 19, 20, 30] { XCTAssertNil(desktopShortcut(n), "desktop \(n)") }
    }
}

final class PlanMoveTests: XCTestCase {
    let mac = DisplaySpaces(uuid: "M", spaces: [1, 2, 3], current: 1)
    let odyssey = DisplaySpaces(uuid: "O", spaces: [11, 12, 13, 14], current: 12)
    func name(_ uuid: String) -> String { uuid == "M" ? "Built-in Retina Display" : uuid == "O" ? "Odyssey G95NC" : uuid }

    func plan(_ desktop: Int, to target: Int, display: String? = nil, follow: Bool = false,
              from home: String = "M", displays: [DisplaySpaces]? = nil) throws -> MovePlan? {
        try planMove(from: home, desktop: desktop, to: target, display: display, follow: follow,
                     displays: displays ?? [mac, odyssey], name: name)
    }

    func assertThrows(_ message: String, _ f: @autoclosure () throws -> MovePlan?, line: UInt = #line) {
        XCTAssertThrowsError(try f(), line: line) { XCTAssertTrue("\($0)".contains(message), "\($0)", line: line) }
    }

    func testWithinItsDisplayParksOnTheOtherAndSwitchesBack() throws {
        XCTAssertEqual(try plan(1, to: 3), MovePlan(display: "M", park: "O", target: 3, switchTo: 3, switchBack: 1))
    }

    func testFollowStaysOnTheTargetDesktop() throws {
        XCTAssertEqual(try plan(1, to: 3, follow: true), MovePlan(display: "M", park: "O", target: 3, switchTo: 3, switchBack: nil))
    }

    func testNamingItsOwnDisplayIsAMoveWithinIt() throws {
        XCTAssertEqual(try plan(1, to: 3, display: "built-in"), try plan(1, to: 3))
    }

    func testToAnotherDisplaySwitchesThatDisplayAndBack() throws {
        // the shortcuts count the MacBook's 3 desktops first
        XCTAssertEqual(try plan(1, to: 4, display: "odyssey"), MovePlan(display: "O", park: nil, target: 14, switchTo: 7, switchBack: 5))
        XCTAssertEqual(try plan(1, to: 4, display: "odyssey", follow: true),
                       MovePlan(display: "O", park: nil, target: 14, switchTo: 7, switchBack: nil))
    }

    func testToTheDesktopShowingOnAnotherDisplaySwitchesNothing() throws {
        XCTAssertEqual(try plan(1, to: 2, display: "odyssey"), MovePlan(display: "O", park: nil, target: 12, switchTo: nil, switchBack: nil))
    }

    func testAlreadyThere() throws {
        XCTAssertNil(try plan(1, to: 1))
        XCTAssertNil(try plan(2, to: 2, display: "odyssey", from: "O"))
    }

    func testOneDisplayHasNowhereToPark() {
        assertThrows("needs a second display", try plan(1, to: 2, displays: [mac]))
    }

    func testDesktopOutOfRange() {
        assertThrows("starting at 1", try plan(1, to: 0))
        assertThrows("Built-in Retina Display has only 3 desktops", try plan(1, to: 4))
        assertThrows("has only 1 desktop", try plan(1, to: 2, display: "odyssey", displays: [mac, DisplaySpaces(uuid: "O", spaces: [11], current: 11)]))
    }

    func testUnknownDisplay() {
        assertThrows("no display matches 'lg'", try plan(1, to: 2, display: "lg"))
    }

    func testPastTheSixteenShortcuts() throws {
        let ten = DisplaySpaces(uuid: "M", spaces: Array(1...10), current: 1)
        let big = DisplaySpaces(uuid: "O", spaces: Array(11...20), current: 11)
        // desktop 10 of the second display is desktop 20 overall: this used to crash the app
        assertThrows("only has shortcuts for the first 16", try plan(1, to: 10, display: "odyssey", displays: [ten, big]))
        XCTAssertEqual(try plan(1, to: 6, display: "odyssey", displays: [ten, big])?.switchTo, 16)
        // and within one display, the same limit applies
        assertThrows("is desktop 17", try plan(1, to: 7, from: "O", displays: [ten, big]))
    }

    func testCantSwitchBackPastTheSixteenShortcuts() throws {
        let ten = DisplaySpaces(uuid: "M", spaces: Array(1...10), current: 1)
        let showing8 = DisplaySpaces(uuid: "O", spaces: Array(11...20), current: 18)   // desktop 18 overall
        assertThrows("is desktop 18", try plan(1, to: 2, display: "odyssey", displays: [ten, showing8]))
        XCTAssertEqual(try plan(1, to: 2, display: "odyssey", follow: true, displays: [ten, showing8])?.switchTo, 12)
    }
}

final class WindowListTests: XCTestCase {
    func win(_ id: Int, _ app: String, _ title: String = "", display: String = "M", desktop: Int = 1, showing: Bool = true) -> Win {
        Win(id: id, pid: 1, app: app, title: title, frame: CGRect(x: 10, y: 20, width: 800, height: 600),
            display: display, displayName: display == "M" ? "Built-in Retina Display" : "Odyssey G95NC",
            desktop: desktop, showing: showing)
    }

    func testFindPrefersWindowsThatAreShowing() throws {
        let wins = [win(1, "Zen", "Docs", desktop: 2, showing: false), win(2, "Zen", "GitHub"), win(3, "Terminal")]
        XCTAssertEqual(try findWindow("zen", in: wins).id, 2)
        XCTAssertEqual(try findWindow("zen docs", in: [win(2, "Zen", "GitHub"), win(4, "Zen", "Docs")]).id, 4)
        XCTAssertEqual(try findWindow("3", in: wins).app, "Terminal")
    }

    func testFindExplainsAWindowOnAHiddenDesktop() {
        let wins = [win(1, "Zen", "Docs", desktop: 2, showing: false)]
        XCTAssertThrowsError(try findWindow("1", in: wins)) {
            XCTAssertEqual("\($0)", "Zen — Docs is on desktop 2 of Built-in Retina Display, which isn't showing. Switch to that desktop first.")
        }
        XCTAssertThrowsError(try findWindow("mail", in: wins)) { XCTAssertTrue("\($0)".hasPrefix("no window matches 'mail'")) }
    }

    func testListsByDisplayThenDesktopThenFrontToBack() {
        let wins = [win(5, "Zen", "Back", display: "O", desktop: 1), win(1, "Terminal", desktop: 2, showing: false),
                    win(2, "Zen", "Front"), win(3, "Mail", "Inbox")]
        let rows = formatWindows(wins, displayOrder: ["M", "O"]).components(separatedBy: "\n")
        XCTAssertEqual(rows.map { $0.split(separator: " ", omittingEmptySubsequences: true)[3] }, ["2", "3", "1", "5"])
        XCTAssertTrue(rows[0].hasPrefix("Built-in R 1*"))
        XCTAssertTrue(rows[2].hasPrefix("Built-in R 2 "), "no * on a desktop that isn't showing")
        XCTAssertTrue(rows[2].hasSuffix("800x600"), "no trailing spaces without a title")
        XCTAssertTrue(rows[0].hasSuffix("Front"))
    }
}
