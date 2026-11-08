import XCTest

/// One selection across a reply's blocks, with real touches or a real pointer.
@MainActor
final class SelectionUITests: XCTestCase {
    private let probe = "/tmp/md-selection-probe"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        for suffix in ["", ".selection", ".pasteboard"] { try? FileManager.default.removeItem(atPath: probe + suffix) }
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatCorpus", "interactionText",
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
