import XCTest

/// A code block in chat with real touches. The box, chat's default: no buttons, selecting and
/// copying its text, scrolling sideways, scrolls that start on it, drawn and in a text view. The
/// header look, a style option: its buttons, and its wrapped and sideways lines.
@MainActor
final class CodeBlockUITests: XCTestCase {
    private let probe = "/tmp/md-code-probe"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(drawn: Bool, scrolls: Bool = false, header: Bool = false) {
        for suffix in ["", ".state", ".pasteboard"] { try? FileManager.default.removeItem(atPath: probe + suffix) }
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatSelectsAcrossBlocks", "NO", "-chatCorpus", "interaction",
            "-chatDrawsText", drawn ? "YES" : "NO", "-chatCodeScrolls", scrolls ? "YES" : "NO", "-chatProbe", probe,
            "-chatCodeLook", header ? "header" : "box",
        ]
        app.launch()
    }

    /// What the app says.
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

    private var isSelected: Bool { ask("state", ".state")?.contains("selected=true") ?? false }

    private func element(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    /// The code's text, by what it says, scrolled to if it has to be.
    private func codeText() -> XCUIElement {
        let code = element("interactionFirstCodeLine")
        for _ in 0..<8 where !(code.exists && code.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(code.waitForExistence(timeout: 20), "no code block")
        Thread.sleep(forTimeInterval: 0.5)
        return code
    }

    /// The one on screen: a reply repeats, so there are others above it.
    private func button(_ label: String) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        for index in 0..<matches.count where matches.element(boundBy: index).isHittable {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    private func checkHeaderCopy(drawn: Bool) {
        launch(drawn: drawn, header: true)
        _ = codeText()
        let copy = button("Copy")
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "no Copy")
        copy.tap()
        Thread.sleep(forTimeInterval: 0.3)
        let copied = ask("pasteboard", ".pasteboard") ?? ""
        XCTAssertTrue(copied.hasPrefix("let interactionFirstCodeLine"), "pasteboard has: \(copied.prefix(40))")
        XCTAssertTrue(copied.contains("let interactionLastCodeLine = 17"), "copy left out the lines past the limit")
        XCTAssertTrue(button("Copied").waitForExistence(timeout: 2), "no Copied mark")
        XCTAssertTrue(button("Copy").waitForExistence(timeout: 4), "the mark didn't go back")
    }

    func testHeaderCopyOnDrawnText() { checkHeaderCopy(drawn: true) }
    func testHeaderCopyOnTextView() { checkHeaderCopy(drawn: false) }

    /// A box has nothing to press, and every line.
    func testABoxHasNoButtonsAndEveryLine() {
        launch(drawn: false)
        _ = codeText()
        for label in ["Copy", "Expand"] { XCTAssertFalse(button(label).exists, "a box has \(label)") }
        XCTAssertFalse(button("Show the Remaining 2 lines").exists, "a box has a line limit")
        XCTAssertTrue(element("interactionLastCodeLine").exists, "a box leaves out lines past 15")
    }

    /// What a box offers for copying: selected text, and the system's menu over it.
    private func checkCopyingASelection(drawn: Bool) {
        launch(drawn: drawn)
        let word = codeText().coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 40, dy: 7))
        word.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a long press on code selected nothing")
        var copy = app.menuItems["Copy"]
        if !copy.waitForExistence(timeout: 2) {
            // A tap on what's selected brings the menu if the press didn't.
            word.tap()
            copy = app.menuItems["Copy"]
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "no Copy in the text's menu")
        copy.tap()
        Thread.sleep(forTimeInterval: 0.3)
        let copied = ask("pasteboard", ".pasteboard") ?? ""
        print("COPIED \(copied)")
        XCTAssertFalse(copied.isEmpty, "nothing copied")
        XCTAssertTrue("let interactionFirstCodeLine = 1".contains(copied.trimmingCharacters(in: .whitespacesAndNewlines)), "copied: \(copied.prefix(40))")
    }

    func testCopyingASelectionInDrawnCode() { checkCopyingASelection(drawn: true) }
    func testCopyingASelectionInATextView() { checkCopyingASelection(drawn: false) }

    private func checkSheet(opening label: String) {
        let opener = button(label)
        XCTAssertTrue(opener.waitForExistence(timeout: 5), "no \(label)")
        opener.tap()
        let copy = app.navigationBars.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), "no Copy on the sheet")
        copy.tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue((ask("pasteboard", ".pasteboard") ?? "").contains("let interactionLastCodeLine = 17"))
        let text = app.textViews["markdown.code.sheet"]
        XCTAssertTrue(text.exists, "no code on the sheet")
        XCTAssertTrue((text.value as? String)?.contains("let interactionLastCodeLine = 17") ?? false, "the sheet leaves out the lines past the limit")
        XCTAssertTrue(app.navigationBars.buttons["Copied"].waitForExistence(timeout: 2), "no Copied on the sheet")
    }

    func testHeaderExpandOpensTheSheet() {
        launch(drawn: true, header: true)
        _ = codeText()
        checkSheet(opening: "Expand")
    }

    func testHeaderShowRemainingOpensTheSheet() {
        launch(drawn: true, header: true)
        _ = codeText()
        let more = button("Show the Remaining 2 lines")
        for _ in 0..<4 where !(more.exists && more.isHittable) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        checkSheet(opening: "Show the Remaining 2 lines")
    }

    private func checkSelecting(drawn: Bool) {
        launch(drawn: drawn)
        let code = codeText()
        code.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 40, dy: 7)).press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a long press on code selected nothing")
    }

    func testLongPressSelectsDrawnCode() { checkSelecting(drawn: true) }
    func testLongPressSelectsCodeInATextView() { checkSelecting(drawn: false) }

    func testHeaderLongPressSelectsScrollingCode() {
        launch(drawn: true, scrolls: true, header: true)
        codeText().coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 40, dy: 7)).press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a long press on code selected nothing")
    }

    func testDoubleTapSelectsDrawnCode() {
        launch(drawn: true)
        codeText().coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 40, dy: 7)).doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(isSelected, "a double tap on code selected nothing")
    }

    private var listOffset: CGFloat {
        let text = ask("state", ".state") ?? ""
        return CGFloat(Double(text.components(separatedBy: "listOffset=").last?.components(separatedBy: " ").first ?? "") ?? -2)
    }

    private var codeOffset: CGFloat {
        let text = ask("state", ".state") ?? ""
        return CGFloat(Double(text.components(separatedBy: "codeOffset=").last ?? "") ?? -2)
    }

    /// A sideways drag on a long line moves the code and leaves the list.
    func testCodeScrollsSideways() {
        launch(drawn: true)
        let code = codeText()
        XCTAssertEqual(codeOffset, 0)
        let before = code.frame
        let list = listOffset
        let start = code.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 280, dy: 7))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -240, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        let offset = codeOffset
        print("SIDEWAYS offset \(offset) from \(before)")
        XCTAssertGreaterThan(offset, 50, "the code didn't scroll sideways")
        XCTAssertEqual(listOffset, list, accuracy: 1, "a sideways drag moved the list")
    }

    /// A drag up and down starting on the block moves the list, and the code stays where it is
    /// across, in a box or in a header's lines, wrapped or scrolling sideways.
    private func checkVerticalScroll(scrolls: Bool, header: Bool) {
        launch(drawn: true, scrolls: scrolls, header: header)
        let code = codeText()
        let before = listOffset
        let start = code.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 120, dy: 30))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 120)))
        Thread.sleep(forTimeInterval: 1)
        let after = listOffset
        print("VERTICAL scrolls \(scrolls) list from \(before) to \(after)")
        XCTAssertLessThan(after, before - 40, "a drag starting on the block didn't move the list")
        if scrolls { XCTAssertEqual(codeOffset, 0, "a drag down moved the code sideways") }
    }

    func testVerticalScrollStartsOnBox() { checkVerticalScroll(scrolls: true, header: false) }
    func testVerticalScrollStartsOnWrappedHeaderBlock() { checkVerticalScroll(scrolls: false, header: true) }
    func testVerticalScrollStartsOnScrollingHeaderBlock() { checkVerticalScroll(scrolls: true, header: true) }

    /// Scrolling over code, as over text, doesn't make text views of it.
    func testScrollingUpgradesAtMostTheBlockTouched() {
        launch(drawn: true)
        _ = codeText()
        app.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        let upgrades = ask("state", ".state")?.components(separatedBy: "upgrades=").last?.components(separatedBy: " ").first.flatMap(Int.init) ?? -1
        print("CODE upgrades \(upgrades)")
        XCTAssertLessThanOrEqual(upgrades, 9, "more rows upgraded than touches")
    }
}
