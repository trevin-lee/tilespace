import XCTest
@testable import TileSpaceCore

final class CLITests: XCTestCase {
    func parse(_ line: String) throws -> CLICommand { try parseCommand(line.split(separator: " ").map(String.init)) }

    func assertRefused(_ line: String, _ message: String, line l: UInt = #line) {
        XCTAssertThrowsError(try parse(line), line, line: l) { XCTAssertTrue("\($0)".contains(message), "\($0)", line: l) }
    }

    func testTheWindowComesLastAndCanBeLeftOut() throws {
        XCTAssertEqual(try parse("snap left-half"), .snap(action: "left-half", window: nil))
        XCTAssertEqual(try parse("snap left-half zen github"), .snap(action: "left-half", window: "zen github"))
        XCTAssertEqual(try parse("move 2"), .move(desktop: 2, window: nil, display: nil, follow: false))
        XCTAssertEqual(try parse("move 2 zen github"), .move(desktop: 2, window: "zen github", display: nil, follow: false))
        XCTAssertEqual(try parse("move 2 4144"), .move(desktop: 2, window: "4144", display: nil, follow: false))
        // one quoted argument is the same window as the same words unquoted
        XCTAssertEqual(try parseCommand(["move", "2", "zen github"]), try parse("move 2 zen github"))
    }

    func testMoveTakesADisplayAndFollowAnywhere() throws {
        let want = CLICommand.move(desktop: 3, window: "zen", display: "built-in", follow: true)
        XCTAssertEqual(try parse("move 3 zen --display built-in --follow"), want)
        XCTAssertEqual(try parse("move --follow --display=built-in 3 zen"), want)
        XCTAssertEqual(try parseCommand(["move", "1", "--display", "Odyssey G95NC"]),
                       .move(desktop: 1, window: nil, display: "Odyssey G95NC", follow: false))
        assertRefused("move 3 --display", "--display needs a display's name")
    }

    func testMoveWithTheWindowFirstSaysTheDesktopComesFirst() {
        // the order `move` used to take: "desktop must be a number" pointed at the wrong problem
        assertRefused("move zen 2", "the desktop's number comes first")
        assertRefused("move", "usage: tilespace move <desktop>")
    }

    func testAnOptionACommandDoesntTakeIsRefused() {
        // `snap left-half --follow` used to drop the option and snap the frontmost window
        assertRefused("snap left-half --follow", "tilespace snap has no option --follow")
        assertRefused("windows --display built-in", "tilespace windows has no option --display")
        assertRefused("move 2 --folow", "tilespace move has no option --folow")
        assertRefused("windows zen", "tilespace windows takes no arguments")
        assertRefused("desktops 2", "tilespace desktops takes no arguments")
    }

    func testAnEmptyWindowIsRefusedNotTakenAsTheFrontmostOne() {
        XCTAssertThrowsError(try parseCommand(["snap", "left-half", ""])) { XCTAssertTrue("\($0)".contains("the window is empty")) }
        XCTAssertThrowsError(try parseCommand(["move", "2", " "])) { XCTAssertTrue("\($0)".contains("the window is empty")) }
    }

    func testTheOtherCommands() throws {
        XCTAssertEqual(try parse("windows"), .windows)
        XCTAssertEqual(try parse("list"), .windows)
        XCTAssertEqual(try parse("desktops"), .desktops)
        XCTAssertEqual(try parse("spaces"), .desktops)
        XCTAssertEqual(try parse("mcp"), .mcp)
        XCTAssertEqual(try parse("mcp add"), .mcpAdd)
        XCTAssertEqual(try parse("mcp remove"), .mcpRemove)
        // "install" is what's done to the app; adding it to Claude Code has one name everywhere
        assertRefused("mcp install", "usage: tilespace mcp [add | remove]")
        for help in ["", "help", "-h", "--help"] { XCTAssertEqual(try parse(help), .help) }
        assertRefused("snap sideways", "actions: left-half")
        assertRefused("mcp sideways", "usage: tilespace mcp")
        assertRefused("bogus", "unknown command: bogus")
    }
}

final class LinkTests: XCTestCase {
    func testSnapLinks() {
        XCTAssertEqual(linkCommand("tilespace://execute-action?name=left-half"), .snap(.leftHalf))
        XCTAssertEqual(linkCommand("tilespace://execute-action?name=last-three-fourths"), .snap(.lastThreeFourths))
        XCTAssertNil(linkCommand("tilespace://execute-action?name=sideways"))
        XCTAssertNil(linkCommand("tilespace://execute-action"))
    }

    func testMoveLinks() {
        XCTAssertEqual(linkCommand("tilespace://move-to-desktop?desktop=3"), .move(desktop: 3, display: nil, follow: false))
        XCTAssertEqual(linkCommand("tilespace://move-to-desktop?desktop=3&display=built-in&follow=true"),
                       .move(desktop: 3, display: "built-in", follow: true))
        XCTAssertEqual(linkCommand("tilespace://move-to-desktop?desktop=1&display=Odyssey%20G95NC"),
                       .move(desktop: 1, display: "Odyssey G95NC", follow: false))
        // a link that can't be understood does nothing, rather than something else than it says
        for bad in ["tilespace://move-to-desktop", "tilespace://move-to-desktop?desktop=0", "tilespace://move-to-desktop?desktop=two",
                    "tilespace://move-to-desktop?desktop=2&follow=yes", "tilespace://move?desktop=2", "rectangle://execute-action?name=left-half"] {
            XCTAssertNil(linkCommand(bad), bad)
        }
    }
}

final class MoveMenuTests: XCTestCase {
    let mac = DisplaySpaces(uuid: "M", spaces: [1, 2, 3], current: 2)
    let odyssey = DisplaySpaces(uuid: "O", spaces: [11, 12], current: 11)
    func name(_ uuid: String) -> String { uuid == "M" ? "Built-in Retina Display" : "Odyssey G95NC" }

    func testListsEachDisplaysDesktopsUnderItsName() {
        let rows = moveChoices(displays: [mac, odyssey], screenCount: 2, name: name)
        XCTAssertEqual(rows.map(\.title), ["Built-in Retina Display", "Desktop 1", "Desktop 2 (showing)", "Desktop 3",
                                           "Odyssey G95NC", "Desktop 1 (showing)", "Desktop 2"])
        XCTAssertEqual(rows.map(\.desktop), [nil, 1, 2, 3, nil, 1, 2])
        XCTAssertEqual(rows.map(\.display), [nil, "M", "M", "M", nil, "O", "O"])
    }

    func testSaysWhyThereIsNothingToPick() {
        let one = moveChoices(displays: [mac], screenCount: 1, name: name)
        XCTAssertEqual(one, [MoveChoice(title: "Needs a second display", display: nil, desktop: nil)])
        let shared = moveChoices(displays: [DisplaySpaces(uuid: "Main", spaces: [1, 2], current: 1)], screenCount: 2, name: name)
        XCTAssertEqual(shared.count, 1)
        XCTAssertTrue(shared[0].title.contains("Displays have separate Spaces"))
    }
}
