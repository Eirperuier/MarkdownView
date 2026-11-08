import FlooColor
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

    func testAHighlightStaysFaintUnderATheme() {
        // A derived theme moves fills apart from its surface: a highlight keeps its alpha, so
        // the text on it still has the surface's contrast.
        let dark = traits(.tinted(.systemPurple), style: .dark)
        var alpha: CGFloat = 0
        MarkdownInk.highlightFill("yellow")!.resolvedColor(with: dark).getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertEqual(alpha, 0.32, accuracy: 0.01)
    }

    func testTextOnAHighlightReads() {
        // Yellow on a yellow ground: made to read on the ground as drawn; white on it already does.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = traits(.system, style: style)
            let ground = MarkdownInk.highlightFill("yellow")!
            let drawn = SRGBColor(ground.resolvedColor(with: traits).composited(on: .systemBackground.resolvedColor(with: traits)))
            let text = UIColor.markdown(text: MarkdownInk.text("yellow")!, onGround: ground).resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(ReadableColor.contrast(SRGBColor(text), on: drawn), 59.5, "\(style.rawValue)")
        }
        let dark = traits(.system, style: .dark)
        let white = UIColor.white
        XCTAssertEqual(UIColor.markdown(text: white, onGround: MarkdownInk.highlightFill("yellow")!).resolvedColor(with: dark), white)
    }

    func testANameIsOneColourEverywhere() {
        // A word, a pen and a theme's choice in red agree.
        let theme = FlooTheme.system.setting(.markdownInk(.red), to: .systemPink)
        let themed = traits(theme)
        XCTAssertEqual(MarkdownInk.text("red")?.resolvedColor(with: themed), UIColor.systemPink.resolvedColor(with: themed))
        XCTAssertEqual(MarkdownInk.pen("red")?.resolvedColor(with: themed), UIColor.systemPink.resolvedColor(with: themed))
        XCTAssertEqual(MarkdownInk.pen("error")?.resolvedColor(with: themed), UIColor.floo(.destructive).resolvedColor(with: themed))
        XCTAssertEqual(MarkdownInk.callout(.caution).resolvedColor(with: themed), UIColor.floo(.destructive).resolvedColor(with: themed))
    }
}
