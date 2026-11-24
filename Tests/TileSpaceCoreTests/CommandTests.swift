import CoreGraphics
import XCTest
@testable import TileSpaceCore

final class DesktopShortcutTests: XCTestCase {
    func shortcut(_ n: Int, _ hotKeys: [String: Any]? = nil) -> KeyCombo? { desktopShortcut(n, hotKeys: hotKeys) }
    // an entry of com.apple.symbolichotkeys' AppleSymbolicHotKeys
    func hotKey(_ enabled: Bool, key: Int = 18, flags: Int = 262_144) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [65535, key, flags], "type": "standard"]]
    }

    // on, with no keys stored: macOS's keys
    func on(_ n: Int) -> KeyCombo? { shortcut(n, ["\(117 + n)": ["enabled": true]]) }

    func testOnWithNoKeysStoredPressesMacOSKeysForDesktops1To16() {
        XCTAssertEqual(on(1), KeyCombo(key: 18, flags: .maskControl))                      // Ctrl+1
        XCTAssertEqual(on(10), KeyCombo(key: 29, flags: .maskControl))                     // Ctrl+0
        XCTAssertEqual(on(11), KeyCombo(key: 18, flags: [.maskControl, .maskAlternate]))   // Ctrl+Option+1
        XCTAssertEqual(on(16)?.key, 22)                                                    // Ctrl+Option+6
    }

    func testNeverTurnedOnIsOff() {
        // a new account has no entry for 118-133: macOS ships "Switch to Desktop N" off
        for n in [1, 2, 10, 16] { XCTAssertNil(shortcut(n), "desktop \(n), no hot keys at all") }
        XCTAssertNil(shortcut(3, [:]))
        XCTAssertNil(shortcut(3, ["118": hotKey(true)]), "only desktop 1 is on")
        XCTAssertNil(shortcut(3, ["120": ["value": ["parameters": [65535, 20, 262_144]]]]), "keys, but never turned on")
    }

    func testHasNoneOutside1To16() {
        // 17-19 used to press Ctrl+Option+7-9, and 20 and up read past the end of the key table
        for n in [0, 17, 19, 20, 30] { XCTAssertNil(shortcut(n, ["\(117 + n)": hotKey(true)]), "desktop \(n)") }
    }

    func testPressesTheKeysTheUserSet() {
        // "Switch to Desktop 3" (hot key 120) moved to Cmd+Shift+F3
        XCTAssertEqual(shortcut(3, ["120": hotKey(true, key: 99, flags: 1_179_648 | 8_388_608)]),
                       KeyCombo(key: 99, flags: [.maskCommand, .maskShift, .maskSecondaryFn]))
        // Ctrl+Option+1 for desktop 11 (hot key 128), as macOS stores it
        XCTAssertEqual(shortcut(11, ["128": hotKey(true, flags: 786_432)]), KeyCombo(key: 18, flags: [.maskControl, .maskAlternate]))
    }

    func testOffOrWithoutAKeyIsNone() {
        XCTAssertNil(shortcut(3, ["120": hotKey(false)]))
        XCTAssertNil(shortcut(3, ["120": ["enabled": false]]))
        XCTAssertNil(shortcut(3, ["120": hotKey(true, key: 65535, flags: 0)]))
        XCTAssertEqual(shortcut(3, ["120": ["enabled": true]])?.key, 20, "on, with no keys stored: the default")
    }

    func testAMoveChecksItsShortcutsFirst() throws {
        let plan = MovePlan(display: "M", park: "O", target: 3, switchTo: 3, switchBack: 1)
        let bothOn = ["118": hotKey(true), "120": hotKey(true, key: 20)]
        XCTAssertNoThrow(try checkShortcuts(plan, hotKeys: bothOn))
        // a new account, which has never turned them on, is told before anything moves
        for fresh in [nil, [:]] as [[String: Any]?] {
            XCTAssertThrowsError(try checkShortcuts(plan, hotKeys: fresh)) {
                XCTAssertTrue("\($0)".hasPrefix("\"Switch to Desktop 3\" is off. Turn it on in System Settings"), "\($0)")
            }
        }
        XCTAssertThrowsError(try checkShortcuts(plan, hotKeys: ["118": hotKey(true), "120": hotKey(false)])) {
            XCTAssertTrue("\($0)".hasPrefix("\"Switch to Desktop 3\" is off. Turn it on in System Settings"), "\($0)")
        }
        for back in [["120": hotKey(true, key: 20), "118": hotKey(false)], ["120": hotKey(true, key: 20)]] {
            XCTAssertThrowsError(try checkShortcuts(plan, hotKeys: back)) {
                XCTAssertTrue("\($0)".contains("\"Switch to Desktop 1\" is off"), "\($0)")
                XCTAssertTrue("\($0)".contains("with follow on"), "the way back is the only problem: \($0)")
            }
        }
        let follow = MovePlan(display: "M", park: "O", target: 3, switchTo: 3, switchBack: nil)
        XCTAssertNoThrow(try checkShortcuts(follow, hotKeys: ["120": hotKey(true, key: 20)]))
    }
}

final class PlanMoveTests: XCTestCase {
    let mac = DisplaySpaces(uuid: "M", spaces: [1, 2, 3], current: 1)
    let odyssey = DisplaySpaces(uuid: "O", spaces: [11, 12, 13, 14], current: 12)
    func name(_ uuid: String) -> String { uuid == "M" ? "Built-in Retina Display" : uuid == "O" ? "Odyssey G95NC" : uuid }

    func plan(_ desktop: Int, to target: Int, display: String? = nil, follow: Bool = false,
              from home: String = "M", displays: [DisplaySpaces]? = nil, screenCount: Int? = nil) throws -> MovePlan? {
        let displays = displays ?? [mac, odyssey]
        return try planMove(from: home, desktop: desktop, to: target, display: display, follow: follow,
                            displays: displays, screenCount: screenCount ?? displays.count, name: name)
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

    func testSharedSpacesNameTheSettingInsteadOfASecondDisplay() {
        // "Displays have separate Spaces" off: two displays, but SkyLight reports one
        let shared = DisplaySpaces(uuid: "Main", spaces: [1, 2, 3], current: 1)
        for display in [nil, "built-in", "odyssey"] {
            assertThrows("Displays have separate Spaces", try plan(1, to: 2, display: display, from: "Main", displays: [shared], screenCount: 2))
        }
        XCTAssertEqual(displayName("Main"), "All displays")
    }

    func testDesktopOutOfRange() {
        assertThrows("starting at 1", try plan(1, to: 0))
        assertThrows("Built-in Retina Display has only 3 desktops", try plan(1, to: 4))
        assertThrows("has only 1 desktop", try plan(1, to: 2, display: "odyssey", displays: [mac, DisplaySpaces(uuid: "O", spaces: [11], current: 11)]))
    }

    func testADisplayCanBeGivenByItsIdentifier() throws {
        // what the menu passes: two displays of one model have the same name
        let twin = DisplaySpaces(uuid: "T", spaces: [21, 22], current: 21)
        let named: (String) -> String = { $0 == "M" ? "Built-in Retina Display" : "Odyssey G95NC" }
        let p = try planMove(from: "M", desktop: 1, to: 2, display: "T", follow: false,
                             displays: [mac, odyssey, twin], screenCount: 3, name: named)
        XCTAssertEqual(p?.display, "T")
        XCTAssertEqual(p?.target, 22)
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
        // the move itself could work: say that it's the way back, and that following skips it,
        // in words that fit the command line's --follow and the MCP tool's `follow` alike
        assertThrows("Odyssey G95NC is showing desktop 8, which is desktop 18", try plan(1, to: 2, display: "odyssey", displays: [ten, showing8]))
        assertThrows("with follow on, to stay on desktop 2", try plan(1, to: 2, display: "odyssey", displays: [ten, showing8]))
        XCTAssertEqual(try plan(1, to: 2, display: "odyssey", follow: true, displays: [ten, showing8])?.switchTo, 12)
    }
}

// The app runs for days, and every list, snap by name and move asks SkyLight for the desktops.
// The arrays it hands back have to be freed once they're let go, or each call leaks one.
final class SpacesMemoryTests: XCTestCase {
    // whether what `copy` returns is still around after it's let go (nil if it returned nothing)
    func outlives(_ copy: () -> CFArray?) -> Bool? {
        weak var array: AnyObject?
        var returned = false
        autoreleasepool {
            let a = copy()
            returned = a != nil
            array = a
        }
        return returned ? array != nil : nil
    }

    func testTheListOfDesktopsIsFreed() throws {
        guard let leaked = outlives(copyDisplaySpaces) else { throw XCTSkip("no window server to ask") }
        XCTAssertFalse(leaked)
    }

    func testAWindowsDesktopsAreFreed() throws {
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // a window that's on a desktop: for one that isn't, SkyLight returns a shared empty array
        guard let window = onScreen.compactMap({ $0[kCGWindowNumber as String] as? Int }).first(where: { !spaces(of: $0).isEmpty })
        else { throw XCTSkip("no window on a desktop to ask about") }
        XCTAssertEqual(outlives { copySpaces(of: window) }, false)
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

    func testWindowsOnScreenComeFrontToBack() throws {
        // as the window server lists every window: newest first, whatever is in front
        let all = [win(53418, "agents"), win(45252, "Visual Studio Code", "back"), win(45251, "Visual Studio Code", "front"),
                   win(900, "Notes", desktop: 2, showing: false), win(44738, "Zen", "front"), win(800, "Mail"),
                   win(43659, "Zen", "back")]
        // and the ones on screen, frontmost first (Mail is hidden, Notes on another desktop)
        let wins = frontmostFirst(all, onScreen: [44738, 53418, 45251, 43659, 45252])
        XCTAssertEqual(wins.map(\.id), [44738, 53418, 45251, 43659, 45252, 900, 800])
        // so text that matches several windows means the one in front
        XCTAssertEqual(try findWindow("visual studio code", in: wins).title, "front")
        XCTAssertEqual(try findWindow("zen", in: wins).title, "front")
        let rows = formatWindows(wins, displayOrder: ["M"]).components(separatedBy: "\n")
        XCTAssertTrue(rows[0].hasSuffix("front") && rows[0].contains("Zen"), rows[0])
    }

    func testListsByDisplayThenDesktopThenFrontToBack() {
        let wins = [win(5, "Zen", "Back", display: "O", desktop: 1), win(1, "Terminal", desktop: 2, showing: false),
                    win(2, "Zen", "Front"), win(3, "Mail", "Inbox")]
        let rows = formatWindows(wins, displayOrder: ["M", "O"]).components(separatedBy: "\n")
        // the id is the number after the desktop's
        let ids = rows.map { row -> String in
            let r = row.range(of: #"[0-9]\*? +[0-9]+  "#, options: .regularExpression)!
            return row[r].split(separator: " ")[1].description
        }
        XCTAssertEqual(ids, ["2", "3", "1", "5"])
        // whole display names, in a column as wide as the longest
        XCTAssertTrue(rows[0].hasPrefix("Built-in Retina Display 1*      2  Zen"), rows[0])
        XCTAssertTrue(rows[2].hasPrefix("Built-in Retina Display 2       1  Terminal"), "no * on a desktop that isn't showing: \(rows[2])")
        XCTAssertTrue(rows[3].hasPrefix("Odyssey G95NC 1*                5  Zen"), rows[3])
        XCTAssertTrue(rows[2].hasSuffix("800x600"), "no trailing spaces without a title")
        XCTAssertTrue(rows[0].hasSuffix("Front"))
    }
}

final class PlanSwitchTests: XCTestCase {
    let mac = DisplaySpaces(uuid: "M", spaces: [1, 2, 3], current: 1)
    let odyssey = DisplaySpaces(uuid: "O", spaces: [11, 12, 13, 14], current: 12)
    func name(_ uuid: String) -> String { uuid == "M" ? "Built-in Retina Display" : "Odyssey G95NC" }

    func plan(_ target: Int, display: String? = nil, home: String? = "M", displays: [DisplaySpaces]? = nil) throws -> SwitchPlan {
        try planSwitch(to: target, display: display, home: home, displays: displays ?? [mac, odyssey], name: name)
    }

    func assertThrows(_ message: String, _ f: @autoclosure () throws -> SwitchPlan, line: UInt = #line) {
        XCTAssertThrowsError(try f(), line: line) { XCTAssertTrue("\($0)".contains(message), "\($0)", line: line) }
    }

    func testSwitchesTheDisplayNamedNotTheOneInFront() throws {
        // the shortcuts count the MacBook's 3 desktops first
        XCTAssertEqual(try plan(4, display: "odyssey"), SwitchPlan(display: "O", target: 14, shortcut: 7))
        XCTAssertEqual(try plan(1, display: "odyssey", home: nil), SwitchPlan(display: "O", target: 11, shortcut: 4))
    }

    func testWithoutADisplayTheFrontmostWindowsOne() throws {
        XCTAssertEqual(try plan(3), SwitchPlan(display: "M", target: 3, shortcut: 3))
        XCTAssertEqual(try plan(3, home: "O"), SwitchPlan(display: "O", target: 13, shortcut: 6))
        // no frontmost window: fine with one display, asks which with two
        XCTAssertEqual(try plan(2, home: nil, displays: [mac]), SwitchPlan(display: "M", target: 2, shortcut: 2))
        assertThrows("which display?", try plan(2, home: nil))
    }

    func testTheDesktopShowingAlreadyNeedsNoShortcut() throws {
        XCTAssertEqual(try plan(2, display: "odyssey"), SwitchPlan(display: "O", target: 12, shortcut: nil))
        XCTAssertEqual(try plan(1), SwitchPlan(display: "M", target: 1, shortcut: nil))
    }

    func testOutOfRange() {
        assertThrows("starting at 1", try plan(0))
        assertThrows("Built-in Retina Display has only 3 desktops", try plan(4))
        assertThrows("no display matches 'lg'", try plan(1, display: "lg"))
        let ten = DisplaySpaces(uuid: "M", spaces: Array(1...10), current: 1)
        let big = DisplaySpaces(uuid: "O", spaces: Array(11...20), current: 11)
        assertThrows("is desktop 17 counting across displays", try plan(7, display: "odyssey", displays: [ten, big]))
        XCTAssertEqual(try plan(6, display: "odyssey", displays: [ten, big]).shortcut, 16)
    }
}

final class DesktopEditTests: XCTestCase {
    let mac = DisplaySpaces(uuid: "M", spaces: [1, 2, 3], current: 2, all: [1, 2, 50, 3])   // a full-screen app's space at 50
    let dell = DisplaySpaces(uuid: "D", spaces: [11, 12], current: 11)
    func name(_ uuid: String) -> String { uuid == "M" ? "Built-in Retina Display" : "DELL U4924DW" }
    func win(_ id: Int, display: String, desktop: Int) -> Win {
        Win(id: id, pid: 1, app: "Zen", title: "Docs", frame: .zero, display: display, displayName: name(display), desktop: desktop, showing: false)
    }

    func remove(_ n: Int, display: String? = nil, home: String? = "M", windows: [Win] = [], moveWindows: Bool = false) throws -> RemovePlan {
        try planRemoveDesktop(n, display: display, home: home, displays: [mac, dell], windows: windows, moveWindows: moveWindows, name: name)
    }

    func assertRefused(_ message: String, _ f: @autoclosure () throws -> RemovePlan, line: UInt = #line) {
        XCTAssertThrowsError(try f(), line: line) { XCTAssertTrue("\($0)".contains(message), "\($0)", line: line) }
    }

    func testAddGoesToTheDisplayNamedOrTheFrontmostWindowsOne() throws {
        XCTAssertEqual(try planAddDesktop(display: "dell", home: "M", displays: [mac, dell], name: name).uuid, "D")
        XCTAssertEqual(try planAddDesktop(display: nil, home: "D", displays: [mac, dell], name: name).uuid, "D")
        XCTAssertThrowsError(try planAddDesktop(display: nil, home: nil, displays: [mac, dell], name: name))
    }

    func testRemovesByItsPlaceInMissionControlsRow() throws {
        // desktop 3 comes after a full-screen app's space, so it's the 4th button
        XCTAssertEqual(try remove(3), RemovePlan(display: "M", space: 3, button: 3))
        XCTAssertEqual(try remove(1), RemovePlan(display: "M", space: 1, button: 0))
        XCTAssertEqual(try remove(2, display: "dell"), RemovePlan(display: "D", space: 12, button: 1))
    }

    func testNeverTheShowingOneOrTheLast() {
        assertRefused("is showing", try remove(2))
        assertRefused("is showing", try remove(1, display: "dell"))
        let one = DisplaySpaces(uuid: "D", spaces: [11], current: 11)
        XCTAssertThrowsError(try planRemoveDesktop(1, display: "dell", home: nil, displays: [mac, one], windows: [], moveWindows: false, name: name)) {
            XCTAssertTrue("\($0)".contains("only desktop"), "\($0)")
        }
        assertRefused("has only 3 desktops", try remove(4))
        assertRefused("starting at 1", try remove(0))
    }

    func testADesktopWithWindowsNeedsMoveWindows() throws {
        let wins = [win(7, display: "M", desktop: 3), win(8, display: "M", desktop: 3), win(9, display: "D", desktop: 2)]
        XCTAssertThrowsError(try remove(3, windows: wins)) {
            XCTAssertTrue("\($0)".contains("has 2 windows on it: Zen — Docs (7), Zen — Docs (8)"), "\($0)")
        }
        XCTAssertEqual(try remove(3, windows: wins, moveWindows: true).space, 3)
        // windows on other desktops don't count
        XCTAssertEqual(try remove(1, windows: wins).space, 1)
    }

    func testReadsTheDesktopAMissionControlButtonNames() {
        XCTAssertEqual(desktopNumber(in: "Desktop 3"), 3)
        XCTAssertNil(desktopNumber(in: "Zen"))
        XCTAssertNil(desktopNumber(in: "Desktop"))
    }
}
