import XCTest

/// Rows mustn't move by themselves once a scroll ends (ChatJumpWatch logs any that do).
@MainActor
final class JumpUITests: XCTestCase {
    private func run(selects: Bool) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-ApplePersistenceIgnoreState", "YES",
            "-chatOpen", "YES", "-chatRenderer", "uikit", "-chatDrawsText", "YES",
            "-chatJumpWatch", "YES", "-chatSelectsAcrossBlocks", selects ? "YES" : "NO",
        ]
        app.launch()
        Thread.sleep(forTimeInterval: 3)
        for _ in 0..<8 {
            app.swipeDown(velocity: 4000)
            Thread.sleep(forTimeInterval: 2.5)
        }
        for _ in 0..<2 {
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 2.5)
        }
        let log = (try? String(contentsOfFile: "/tmp/md-jump.log", encoding: .utf8)) ?? "<no log>"
        print("JUMPLOG selects=\(selects)\n\(log)JUMPEND")
        let jumps = log.split(separator: "\n").filter { !$0.hasPrefix("attached") && !$0.contains("alive") }
        XCTAssertTrue(log.hasPrefix("attached"), "the watch didn't run")
        XCTAssertEqual(jumps, [], "rows moved by themselves")
        app.terminate()
    }

    func testWithSelection() { run(selects: true) }
    
}
