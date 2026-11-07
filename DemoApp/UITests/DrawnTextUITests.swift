import XCTest

/// Rows that draw their text until touched, with real touches: selecting, links and scrolling
/// must be a text view's own, and changing over mustn't show.
@MainActor
final class DrawnTextUITests: XCTestCase {
    private let probe = "/tmp/md-drawn-probe"
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        launch(drawn: true)
    }

    private func launch(drawn: Bool) {
        for suffix in ["", ".link", ".state"] { try? FileManager.default.removeItem(atPath: probe + suffix) }
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatCorpus", "interaction",
            "-chatDrawsText", drawn ? "YES" : "NO", "-chatProbe", probe,
        ]
        app.launch()
    }

    /// What the app says: how many rows upgraded, and whether text is selected.
    private func state() -> (upgrades: Int, selected: Bool) {
        try? "state \(probe).state".write(toFile: probe, atomically: true, encoding: .utf8)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.1)
            if let text = try? String(contentsOfFile: probe + ".state", encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: probe + ".state")
                let upgrades = text.components(separatedBy: "upgrades=").last?.components(separatedBy: " ").first.flatMap(Int.init) ?? -1
                return (upgrades, text.contains("selected=true"))
            }
        }
        XCTFail("the probe didn't answer")
        return (-1, false)
    }

    /// A row's text by what it says, drawn or in a text view.
    private func row(_ words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    private func waitForRow(_ words: String) -> XCUIElement {
        let element = row(words)
        XCTAssertTrue(element.waitForExistence(timeout: 20), "no row with \(words)")
        Thread.sleep(forTimeInterval: 1)
        return element
    }

    private func point(in element: XCUIElement, x: CGFloat) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: x, dy: 0))
    }

    func testNothingUpgradesUntilTouched() {
        _ = waitForRow("Interaction first paragraph")
        XCTAssertEqual(state().upgrades, 0, "rows upgraded with nothing touching them")
    }

    func testScrollingUpgradesAtMostTheRowTouched() {
        let element = waitForRow("Interaction first paragraph")
        let before = element.frame.minY
        for _ in 0..<3 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 1)
        let now = state()
        print("SCROLL upgrades \(now.upgrades), row moved from \(before) to \(row("Interaction").frame.minY)")
        XCTAssertLessThanOrEqual(now.upgrades, 3, "more rows upgraded than touches")
    }

    func testLongPressSelects() {
        let element = waitForRow("Interaction first paragraph")
        point(in: element, x: 60).press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(state().selected, "a long press on drawn text selected nothing")
        XCTAssertTrue(app.menuItems["Copy"].exists || app.buttons["Copy"].exists, "no Copy in the menu")
    }

    func testDoubleTapSelects() {
        let element = waitForRow("Interaction first paragraph")
        point(in: element, x: 60).doubleTap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(state().selected, "a double tap on drawn text selected nothing")
    }

    func testFirstTapOpensALink() {
        let element = waitForRow("Open the test link")
        point(in: element, x: 40).tap()
        Thread.sleep(forTimeInterval: 1)
        let link = try? String(contentsOfFile: probe + ".link", encoding: .utf8)
        XCTAssertEqual(link, "https://example.com/drawn", "the first tap on a drawn link opened nothing")
    }

    func testSecondTapOpensALink() {
        let element = waitForRow("Open the test link")
        let frame = element.frame
        print("LINKROW drawn frame \(frame) \(element.elementType.rawValue)")
        point(in: element, x: 40).tap()
        Thread.sleep(forTimeInterval: 1)
        print("LINKROW after first tap upgrades \(state().upgrades) link \(String(describing: try? String(contentsOfFile: probe + ".link", encoding: .utf8)))")
        let again = row("Open the test link")
        print("LINKROW text view frame \(again.frame) \(again.elementType.rawValue)")
        point(in: again, x: 40).tap()
        Thread.sleep(forTimeInterval: 1)
        let link = try? String(contentsOfFile: probe + ".link", encoding: .utf8)
        XCTAssertEqual(link, "https://example.com/drawn", "a second tap opened nothing")
    }

    /// The control: a text view from the start, so a failure above is drawn text's.
    func testLinkOnATextView() {
        app.terminate()
        launch(drawn: false)
        let element = waitForRow("Open the test link")
        print("LINKROW control frame \(element.frame) \(element.elementType.rawValue)")
        point(in: element, x: 40).tap()
        Thread.sleep(forTimeInterval: 1)
        let link = try? String(contentsOfFile: probe + ".link", encoding: .utf8)
        XCTAssertEqual(link, "https://example.com/drawn", "a tap on a text view's link opened nothing")
    }

    func testChangingOverDoesNotShow() {
        let element = waitForRow("Interaction first paragraph")
        let frame = element.frame
        let before = XCUIScreen.main.screenshot().image
        point(in: element, x: frame.width - 40).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(state().upgrades, 0, "the tap didn't upgrade the row")
        let after = XCUIScreen.main.screenshot().image
        let different = Self.differingPixels(before, after, in: frame)
        add(XCTAttachment(image: before))
        add(XCTAttachment(image: after))
        print("OVER differing pixels \(different)")
        XCTAssertEqual(different, 0, "the row's pixels changed when its text view took over")
    }

    private static func differingPixels(_ a: UIImage, _ b: UIImage, in frame: CGRect) -> Int {
        let scale = a.scale
        let box = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let ca = a.cgImage?.cropping(to: box), let cb = b.cgImage?.cropping(to: box) else { return -1 }
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        let pa = pixels(ca), pb = pixels(cb)
        guard pa.count == pb.count else { return -2 }
        return stride(from: 0, to: pa.count, by: 4).reduce(0) { $0 + (pa[$1] != pb[$1] || pa[$1 + 1] != pb[$1 + 1] || pa[$1 + 2] != pb[$1 + 2] ? 1 : 0) }
    }
}
