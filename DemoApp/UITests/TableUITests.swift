import XCTest

/// A table in chat with real touches: its text selects and its links open as a text view's own,
/// sideways scrolls are the table's and others the list's, and only what's touched has a text view.
@MainActor
final class TableUITests: XCTestCase {
    private let probe = "/tmp/md-table-probe"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(scrolls: Bool = false, drawn: Bool = true) {
        for suffix in ["", ".state", ".link", ".pasteboard"] { try? FileManager.default.removeItem(atPath: probe + suffix) }
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatCorpus", "interactionTable",
            "-chatDrawsText", drawn ? "YES" : "NO", "-chatTableScrolls", scrolls ? "YES" : "NO", "-chatProbe", probe,
        ]
        app.launch()
    }

    private func ask(_ command: String, _ suffix: String) -> String? {
        try? "\(command) \(probe)\(suffix)".write(toFile: probe, atomically: true, encoding: .utf8)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            if let text = try? String(contentsOfFile: probe + suffix, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: probe + suffix)
                return text
            }
        }
        XCTFail("the probe didn't answer \(command)")
        return nil
    }

    private func number(_ name: String) -> CGFloat {
        let text = ask("state", ".state") ?? ""
        return CGFloat(Double(text.components(separatedBy: "\(name)=").last?.components(separatedBy: " ").first ?? "") ?? -2)
    }

    private var isSelected: Bool { ask("state", ".state")?.contains("selected=true") ?? false }

    private func element(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    /// A cell by what it says, on screen, scrolled to if it has to be: a reply repeats, so
    /// there are others above it.
    private func cell(_ words: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 20), "no cell with \(words)")
        for _ in 0..<10 {
            for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
                Thread.sleep(forTimeInterval: 0.5)
                return matches.element(boundBy: index)
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("no cell with \(words) on screen")
        return matches.firstMatch
    }

    private func middle(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    func testNothingHasATextViewUntilTouched() {
        launch()
        _ = cell("Table plain words")
        XCTAssertEqual(number("tableTextViews"), 0, "a table only looked at has text views")
    }

    func testLongPressSelectsACellsText() {
        launch()
        middle(of: cell("Table plain words")).press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a long press on a cell selected nothing")
        XCTAssertTrue(app.menuItems["Copy"].exists || app.buttons["Copy"].exists, "no Copy in the menu")
    }

    func testDoubleTapSelectsACellsText() {
        launch()
        middle(of: cell("Table plain words")).doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a double tap on a cell selected nothing")
    }

    func testFirstTapOpensALinkInACell() {
        launch()
        middle(of: cell("Table test link")).tap()
        Thread.sleep(forTimeInterval: 1)
        let link = try? String(contentsOfFile: probe + ".link", encoding: .utf8)
        XCTAssertEqual(link, "https://example.com/table", "a tap on a cell's link opened nothing")
    }

    func testLinkInACellOfAScrollingTable() {
        launch(scrolls: true)
        middle(of: cell("Table test link")).tap()
        Thread.sleep(forTimeInterval: 1)
        let link = try? String(contentsOfFile: probe + ".link", encoding: .utf8)
        XCTAssertEqual(link, "https://example.com/table", "a tap on a scrolling table's link opened nothing")
    }

    func testTouchingACellMovesNothing() {
        launch()
        let target = cell("Table second row")
        let frame = target.frame
        target.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(number("tableTextViews"), 1, "the touched cell has no text view")
        XCTAssertEqual(element("Table second row").frame.minX, frame.minX, accuracy: 1, "the cell's text moved across")
        XCTAssertEqual(element("Table second row").frame.minY, frame.minY, accuracy: 1, "the cell's text moved down")
    }

    func testManyTouchesKeepFewTextViews() {
        launch()
        let rows = ["Table plain words", "Table second row", "Table third row", "Table fourth row", "Table fifth row", "Table sixth row",
                    "Second value", "Third value", "Fourth value", "Fifth value", "Sixth value"]
        _ = cell(rows[0])
        for row in rows {
            let target = element(row)
            if target.exists, target.isHittable { target.tap() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let views = number("tableTextViews")
        XCTAssertGreaterThan(views, 0)
        XCTAssertLessThanOrEqual(views, 8, "touches kept more text views than the limit")
    }

    func testSidewaysSwipeScrollsAWideTable() {
        launch(scrolls: true)
        let target = cell("Table second row")
        let listBefore = number("listOffset")
        XCTAssertEqual(number("tableOffset"), 0)
        target.swipeLeft()
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertGreaterThan(number("tableOffset"), 10, "a sideways swipe didn't scroll the table")
        XCTAssertEqual(number("listOffset"), listBefore, accuracy: 2, "a sideways swipe moved the list")
    }

    func testDragDownFromATableScrollsTheList() {
        for scrolls in [false, true] {
            launch(scrolls: scrolls)
            let target = cell("Table third row")
            let listBefore = number("listOffset")
            let views = number("tableTextViews")
            let start = middle(of: target)
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
            Thread.sleep(forTimeInterval: 1.2)
            XCTAssertLessThan(number("listOffset"), listBefore - 40, "a drag starting on a table didn't scroll the list (scrolling table: \(scrolls))")
            XCTAssertEqual(number("tableOffset"), 0, accuracy: 1, "a drag up and down scrolled the table sideways")
            XCTAssertLessThanOrEqual(number("tableTextViews"), views + 1, "scrolling took a text view for more than the touched cell")
            app.terminate()
        }
    }

    func testSwipeOnASelectedCellKeepsTheSelectionsCell() {
        launch()
        middle(of: cell("Table plain words")).press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected)
        // Other cells touched don't take a selected cell's text view away.
        for row in ["Table second row", "Table third row", "Table fourth row"] where element(row).isHittable {
            element(row).tap()
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertGreaterThan(number("tableTextViews"), 0)
    }
}
