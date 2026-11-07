//
//  MarkdownCodeBoxMetrics.swift
//  MarkdownUIKit
//
//  Every size of the code box, as DocKit measured it on Craft's Mac app with code at 13 points,
//  scaled with the font. Colours are roles (`markdownCodeBoxFill`), not here.
//

import UIKit

@MainActor
struct MarkdownCodeBoxMetrics {
    /// Code against the body text.
    static let fontScale: CGFloat = 0.86
    static let radius: CGFloat = 6
    static let border: CGFloat = 1
    static let separator: CGFloat = 0.5

    let font: UIFont

    /// `bodySize`: the body text style's size at the block's content size category.
    init(bodySize: CGFloat) {
        font = .monospacedSystemFont(ofSize: (bodySize * Self.fontScale).rounded(), weight: .regular)
    }

    private var scale: CGFloat { font.pointSize / 13 }

    /// A line's height as a layout manager gives it, measured once for a size.
    var lineHeight: CGFloat {
        if let height = Self.lineHeights[font.pointSize] { return height }
        let storage = NSTextStorage(string: "0", attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let height = manager.usedRect(for: container).height
        Self.lineHeights[font.pointSize] = height
        return height
    }

    private static var lineHeights: [CGFloat: CGFloat] = [:]

    /// From one line's text to the next's.
    var pitch: CGFloat { (20 * scale).rounded() }
    /// Above and below a line's text: the pitch's room past it, halved.
    var gap: CGFloat { (pitch - lineHeight) / 2 }
    /// From the border to the first line's room, and from the last line's to the border.
    var edge: CGFloat { (9 * scale).rounded() }
    /// From the numbers' right to the gutter's line.
    var numberTrailing: CGFloat { 10.5 * scale }
    /// From the gutter's line to the code, and from the code to the border.
    var codeLeading: CGFloat { 14 * scale }

    /// A digit's width.
    var digit: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }

    /// Room for two digits, a single digit on its right; wider only from a hundred lines.
    func gutterWidth(lines: Int) -> CGFloat {
        (9.5 * scale + CGFloat(max(2, String(lines).count)) * digit + numberTrailing).rounded()
    }

    /// The whole box's height, border included.
    func height(lines: Int) -> CGFloat {
        Self.border * 2 + edge * 2 + CGFloat(max(1, lines)) * pitch
    }
}
