import FlooUIKit
@testable import MarkdownUIKit
import UIKit
import XCTest

final class MarkdownColorRolesTests: XCTestCase {
    private func traits(_ theme: FlooTheme, style: UIUserInterfaceStyle = .light) -> UITraitCollection {
        UITraitCollection { $0.userInterfaceStyle = style; $0.flooTheme = theme }
    }

    func testSystemThemeIsTheSystemColours() {
        let light = traits(.system)
        XCTAssertEqual(UIColor.floo(.markdownText).resolvedColor(with: light), UIColor.label.resolvedColor(with: light))
        XCTAssertEqual(UIColor.floo(.markdownSecondaryText).resolvedColor(with: light), UIColor.secondaryLabel.resolvedColor(with: light))
        XCTAssertEqual(UIColor.floo(.markdownLink).resolvedColor(with: light), UIColor.systemBlue.resolvedColor(with: light))
    }

    func testRolesFollowTheThemeTheyFallBackTo() {
        let theme = FlooTheme.system.setting([.label: .systemPink, .accent: .systemOrange])
        let themed = traits(theme)
        XCTAssertEqual(UIColor.floo(.markdownText).resolvedColor(with: themed), UIColor.systemPink.resolvedColor(with: themed))
        XCTAssertEqual(UIColor.floo(.markdownLink).resolvedColor(with: themed), UIColor.systemOrange.resolvedColor(with: themed))
    }

    func testThemeCanSetAMarkdownRoleAlone() {
        let theme = FlooTheme.system.setting(.markdownLink, to: .systemGreen)
        let themed = traits(theme)
        XCTAssertEqual(UIColor.floo(.markdownLink).resolvedColor(with: themed), UIColor.systemGreen.resolvedColor(with: themed))
        XCTAssertEqual(UIColor.floo(.accent).resolvedColor(with: themed), UIColor.systemBlue.resolvedColor(with: themed))
    }
}
