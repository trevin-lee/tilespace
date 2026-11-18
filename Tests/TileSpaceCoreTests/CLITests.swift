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
        XCTAssertEqual(try parse("mcp install"), .mcpAdd)
        XCTAssertEqual(try parse("mcp uninstall"), .mcpRemove)
        for help in ["", "help", "-h", "--help"] { XCTAssertEqual(try parse(help), .help) }
        assertRefused("snap sideways", "actions: left-half")
        assertRefused("mcp sideways", "usage: tilespace mcp")
        assertRefused("bogus", "unknown command: bogus")
    }
}
