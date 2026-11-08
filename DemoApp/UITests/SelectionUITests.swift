import XCTest

/// One selection across a reply's blocks, with real touches or a real pointer.
@MainActor
final class SelectionUITests: XCTestCase {
    private let probe = "/tmp/md-selection-probe"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        launch(corpus: "interactionText")
    }

    private func launch(corpus: String) {
        for suffix in ["", ".selection", ".pasteboard"] { try? FileManager.default.removeItem(atPath: probe + suffix) }
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatCorpus", corpus,
            "-chatDrawsText", "YES", "-chatProbe", probe,
        ]
        app.launch()
    }

    private func ask(_ command: String, _ suffix: String) -> String? {
        try? FileManager.default.removeItem(atPath: probe + suffix)
        try? "\(command) \(probe)\(suffix)".write(toFile: probe, atomically: true, encoding: .utf8)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            if let text = try? String(contentsOfFile: probe + suffix, encoding: .utf8) { return text }
        }
        XCTFail("the probe didn't answer \(command)")
        return nil
    }

    private func row(_ words: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 20), "no row with \(words)")
        return element
    }

    private func point(in element: XCUIElement, x: CGFloat) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: x, dy: 0))
    }

    func testDragSelectsAcrossBlocks() {
        let first = row("Interaction first paragraph")
        let item = row("A list item with plain words")
        Thread.sleep(forTimeInterval: 1)
        print("SEL first \(first.frame) item \(item.frame)")
        // A drag on a phone selects a little above the finger.
        let end = point(in: item, x: 60).withOffset(CGVector(dx: 0, dy: UIDevice.current.userInterfaceIdiom == .phone ? 40 : 0))
        point(in: first, x: 30).press(forDuration: 1.0, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1)
        let selected = ask("selection", ".selection") ?? ""
        print("SEL selected <<\(selected)>>")
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/md-selection-\(UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "mac").png"))
        XCTAssertTrue(selected.contains("first paragraph"), "the selection doesn't start in the first paragraph")
        XCTAssertTrue(selected.contains("Open the test link"), "the selection doesn't run through the link's paragraph")
        XCTAssertTrue(selected.contains("A li"), "the selection doesn't reach the list item")
    }

    /// A table copies a tab between cells and a line a row, its header as it shows; a formula as
    /// it was written.
    func testTablesAndFormulasCopyAsWritten() {
        launch(corpus: "blocks.tables")
        _ = row("longer text")
        Thread.sleep(forTimeInterval: 1)
        let tables = ask("selectall", ".selection") ?? ""
        print("SEL tables <<\(tables)>>")
        XCTAssertTrue(tables.contains("LEFT\tCENTER\tRIGHT\na\tb\tc\nlonger text\tlonger text\tlonger text"), "a table doesn't copy cell by cell")
        XCTAssertTrue(tables.contains("NAME\tVALUE\nBold\tcode\nlink\titalic"), "a table's styled cells don't copy as their text")

        launch(corpus: "blocks.math")
        _ = row("Euler")
        Thread.sleep(forTimeInterval: 1)
        let math = ask("selectall", ".selection") ?? ""
        print("SEL math <<\(math)>>")
        XCTAssertTrue(math.contains("$$\n\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}\n$$"), "a formula on its own doesn't copy as written")
        XCTAssertTrue(math.contains("identity \\(e^{i\\pi} + 1 = 0\\) and \\(x^2 + y^2 = z^2\\)"), "a formula in a line doesn't copy as written")

        launch(corpus: "blocks.code")
        _ = row("kotlin")
        Thread.sleep(forTimeInterval: 1)
        let code = ask("selectall", ".selection") ?? ""
        print("SEL code <<\(code)>>")
        XCTAssertTrue(code.contains("fun main() = println(\"kotlin\")"), "code doesn't copy")
        XCTAssertTrue(code.contains("unknown language keeps its text"), "code in a language nothing colours doesn't copy")

        launch(corpus: "blocks.images")
        Thread.sleep(forTimeInterval: 3)
        let images = ask("selectall", ".selection") ?? ""
        print("SEL images <<\(images)>>")
        XCTAssertTrue(images.contains("![A landscape](https://catalog.test/wide.png)"), "a picture on its own doesn't copy as written")
    }

    /// A drag across a table's cells selects them.
    func testDragSelectsTableCells() {
        launch(corpus: "blocks.tables")
        let left = app.elementInMiddle(saying: "LEFT")
        let longer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'longer text'")).firstMatch
        XCTAssertTrue(longer.waitForExistence(timeout: 10))
        let end = point(in: longer, x: 30).withOffset(CGVector(dx: 0, dy: UIDevice.current.userInterfaceIdiom == .phone ? 40 : 0))
        point(in: left, x: 4).press(forDuration: 1.0, thenDragTo: end)
        Thread.sleep(forTimeInterval: 1)
        let selected = ask("selection", ".selection") ?? ""
        print("SEL cells <<\(selected)>>")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/md-selection-table-\(UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "mac").png"))
        XCTAssertTrue(selected.hasPrefix("LEFT\tCENTER\tRIGHT\n"), "the drag doesn't select the header row")
        XCTAssertTrue(selected.contains("a\tb\tc\nlo"), "the drag doesn't reach the last row")
    }

    /// Three taps select the line the tap is on, and nothing past it.
    func testTripleTapSelectsALine() {
        let first = row("Interaction first paragraph")
        Thread.sleep(forTimeInterval: 1)
        first.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        Thread.sleep(forTimeInterval: 1)
        let selected = ask("selection", ".selection") ?? ""
        print("SEL line <<\(selected)>>")
        XCTAssertEqual(selected, "Interaction first paragraph with plain words to select in it.")
    }

    private static let prompts = [
        "How do I keep a chat list", "帮我总结一下这周的睡眠数据", "difference between a spring",
        "splits markdown into blocks", "Compare the three options", "Explain the integral",
    ]

    /// A drag up past a reply's start stops there: the prompt above isn't taken.
    func testSelectionStaysInOneMessage() {
        let first = row("Interaction first paragraph")
        Thread.sleep(forTimeInterval: 1)
        let item = row("A list item with plain words")
        let above = point(in: first, x: 30).withOffset(CGVector(dx: 0, dy: -90))
        point(in: item, x: 60).press(forDuration: 1.0, thenDragTo: above)
        Thread.sleep(forTimeInterval: 1)
        let selected = ask("selection", ".selection") ?? ""
        print("SEL message <<\(selected)>>")
        XCTAssertTrue(selected.contains("Interaction first paragraph"), "the drag doesn't reach the reply's start")
        for prompt in Self.prompts { XCTAssertFalse(selected.contains(prompt), "the selection went into a prompt") }
    }

    private func listOffset() -> Double {
        let state = ask("state", ".state") ?? ""
        let value = state.split(separator: " ").first { $0.hasPrefix("listOffset=") }?.dropFirst("listOffset=".count)
        return value.flatMap { Double($0) } ?? .nan
    }

    /// A drag held at the list's top scrolls it, and the selection follows.
    func testDragAtTheEdgeScrolls() {
        launch(corpus: "blocks.headings")
        let start = app.elementInMiddle(saying: "A paragraph after a thematic break")
        let before = listOffset()
        let top = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paged'")).firstMatch
        let edgeY = top.exists ? top.frame.maxY + 14 : app.windows.firstMatch.frame.minY + 140
        let window = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let edge = window.withOffset(CGVector(dx: start.frame.minX + 40, dy: edgeY))
        point(in: start, x: 60).press(forDuration: 1.0, thenDragTo: edge, withVelocity: .default, thenHoldForDuration: 2.5)
        Thread.sleep(forTimeInterval: 1)
        let after = listOffset()
        let selected = ask("selection", ".selection") ?? ""
        print("SEL edge \(before) -> \(after) <<\(selected)>>")
        XCTAssertLessThan(after, before - 40, "the list didn't scroll up")
        XCTAssertGreaterThan(after, before - 1500, "the list scrolled on past the message")
        XCTAssertTrue(selected.hasPrefix("本周睡眠报告"), "the selection didn't follow the scroll to the message's start")
    }

    func testDoubleTapSelectsAWord() {
        let first = row("Interaction first paragraph")
        Thread.sleep(forTimeInterval: 1)
        point(in: first, x: 30).doubleTap()
        Thread.sleep(forTimeInterval: 1)
        let selected = ask("selection", ".selection") ?? ""
        print("SEL word <<\(selected)>>")
        XCTAssertEqual(selected, "Interaction")
    }
}
