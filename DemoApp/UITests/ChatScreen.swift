import XCTest

extension XCUIApplication {
    /// What says `words`, in the middle of the screen, the list moved to bring it there if it has
    /// to be: the page's bar lies over the list's top, and what's under it still counts as
    /// hittable, so a tap there goes to the bar. A reply may repeat: the nearest one comes.
    @MainActor
    func elementInMiddle(saying words: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let matches = descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 20), "nothing says \(words)", file: file, line: line)
        let screen = windows.firstMatch.frame
        func inMiddle(_ element: XCUIElement) -> Bool {
            let y = element.frame.midY
            return y > screen.minY + screen.height * 0.3 && y < screen.minY + screen.height * 0.75
        }
        for _ in 0..<10 {
            for index in 0..<matches.count where inMiddle(matches.element(boundBy: index)) && matches.element(boundBy: index).isHittable {
                Thread.sleep(forTimeInterval: 0.5)
                return matches.element(boundBy: index)
            }
            // The nearest is drawn to the middle, slowly so the list doesn't fling past it.
            let middleY = screen.midY
            let nearest = (0..<matches.count).map { matches.element(boundBy: $0).frame.midY }.filter(\.isFinite).min { abs($0 - middleY) < abs($1 - middleY) }
            let shift = max(-screen.height * 0.4, min(screen.height * 0.4, middleY - (nearest ?? screen.maxY)))
            let start = windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)), withVelocity: 300, thenHoldForDuration: 0.3)
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("nothing saying \(words) in the middle of the screen", file: file, line: line)
        return matches.firstMatch
    }
}
