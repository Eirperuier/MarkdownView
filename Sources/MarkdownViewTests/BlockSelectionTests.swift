//
//  BlockSelectionTests.swift
//  MarkdownView
//

#if os(iOS)
import Testing
import UIKit
@testable import MarkdownView

@MainActor
private final class StackLayout: MarkdownBlockSelectionLayout {
    let containerView: UIView? = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    var layoutVersion: UInt = 0
    var offset: CGFloat = 0
    var frames: [String: CGRect] = [:]

    /// Stacks items top to bottom, 50 pt each.
    init(_ ids: [String]) {
        for (index, id) in ids.enumerated() {
            frames[id] = CGRect(x: 0, y: CGFloat(index) * 50, width: 400, height: 50)
        }
    }

    func contentOffsetY() -> CGFloat { offset }
    func visibleContentHeight() -> CGFloat? { 800 }
    func frame(forItem id: String) -> CGRect? { frames[id] }
    func contentFrames(intersecting rect: CGRect) -> [String: CGRect] {
        frames.filter { $0.value.intersects(rect) }
    }
    func scrollToContentOffsetY(_ y: CGFloat) { offset = y }
}

@MainActor
struct BlockSelectionTests {
    let items: [MarkdownBlockSelectionItem] = [
        .init(id: "h1", group: "m1", role: .groupHeader),
        .init(id: "a", group: "m1", role: .candidate),
        .init(id: "b", group: "m1", role: .candidate),
        .init(id: "h2", group: "m2", role: .groupHeader),
        .init(id: "c", group: "m2", role: .candidate),
        .init(id: "tool", group: "m2", role: .other),
    ]

    private func makeController() -> (MarkdownBlockSelectionController, StackLayout) {
        let layout = StackLayout(items.map(\.id))
        let controller = MarkdownBlockSelectionController()
        let items = items
        controller.itemsProvider = { items }
        controller.install(layout: layout)
        return (controller, layout)
    }

    @Test func groupsCandidatesUnderTheirHeaders() {
        let (controller, layout) = makeController()
        defer { withExtendedLifetime(layout) {} }
        let groups = controller.groups()
        #expect(groups.map(\.id) == ["m1", "m2"])
        #expect(groups.map(\.itemIDs) == [["a", "b"], ["c"]])
        #expect(groups.last?.dotAnchorFrame == CGRect(x: 0, y: 150, width: 400, height: 50))
    }

    @Test func groupDotAnchorsAboveTheFirstBlockWithoutAHeader() {
        let layout = StackLayout(["a"])
        let controller = MarkdownBlockSelectionController()
        controller.itemsProvider = { [.init(id: "a", group: "m", role: .candidate)] }
        controller.install(layout: layout)
        layout.offset = 10
        #expect(controller.groups().first?.dotAnchorFrame == CGRect(x: 0, y: -34, width: 400, height: 24))
    }

    @Test func selectingAGroupTakesOnlyItsCandidates() {
        let (controller, layout) = makeController()
        defer { withExtendedLifetime(layout) {} }
        var modes: [Bool] = []
        controller.onModeChanged = { modes.append($0) }

        controller.activateModeSelectingGroup("m2")
        #expect(controller.state.isActive)
        #expect(controller.state.selectedItemIDs == ["c"])

        controller.exitMode()
        #expect(!controller.state.isActive)
        #expect(controller.state.selectedItemIDs.isEmpty)
        #expect(modes == [true, false])
    }

    @Test func selectedItemsFollowListOrder() {
        let (controller, layout) = makeController()
        defer { withExtendedLifetime(layout) {} }
        controller.activateMode(preselect: ["c", "a"])
        #expect(controller.selectedItems().map(\.id) == ["a", "c"])
    }

    @Test func hooksAreStablePerItem() {
        let (controller, layout) = makeController()
        defer { withExtendedLifetime(layout) {} }
        #expect(controller.hooks(for: "a") === controller.hooks(for: "a"))
        #expect(controller.hooks(for: "a") !== controller.hooks(for: "b"))
    }
}
#endif
