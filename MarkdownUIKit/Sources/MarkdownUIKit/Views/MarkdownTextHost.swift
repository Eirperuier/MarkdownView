//
//  MarkdownTextHost.swift
//  MarkdownUIKit
//
//  A text view with its content: fills it, measures it, and places it on the pixel grid as a
//  layout does.
//

import RichTextCore
import UIKit

/// A layout's grid, in pixels per point. The screen's, not a window's: a height is measured
/// off-window too.
@MainActor
var markdownPixelScale: CGFloat { max(1, UIScreen.main.scale) }

/// To the nearest pixel: where a layout puts a frame's edges.
@MainActor
func markdownPixelRound(_ value: CGFloat) -> CGFloat {
    (value * markdownPixelScale).rounded() / markdownPixelScale
}

/// Up to a pixel: a layout's size for text and symbols.
@MainActor
func markdownPixelCeil(_ value: CGFloat) -> CGFloat {
    (value * markdownPixelScale).rounded(.up) / markdownPixelScale
}

@MainActor
func markdownPixelFloor(_ value: CGFloat) -> CGFloat {
    (value * markdownPixelScale).rounded(.down) / markdownPixelScale
}

extension CGRect {
    /// This rect with its edges on the pixel grid.
    @MainActor
    func markdownPixelAligned() -> CGRect {
        let x0 = markdownPixelRound(minX)
        let y0 = markdownPixelRound(minY)
        let x1 = markdownPixelRound(maxX)
        let y1 = markdownPixelRound(maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

@MainActor
final class MarkdownTextHost {
    let textView: InlineAttachmentTextView
    private let delegate = RichTextInteractionDelegate()
    private(set) var text: MarkdownText?
    /// The room a document gives it, or none.
    var insets = UIEdgeInsets.zero
    private var isRightToLeft = false
    private var rightToLeftHeights: [CGFloat: CGFloat] = [:]

    init() {
        textView = RichTextViewPool.acquire(usingTextLayoutManager: true)
        textView.configureForDisplay()
        // A first letter's overhang stays visible, as it does in a layout that doesn't clip.
        textView.clipsToBounds = false
        textView.redrawsOnChange(of: MarkdownColorTraits.all)
        delegate.textView = textView
        textView.delegate = delegate
        textView.textDragDelegate = delegate
    }

    func release() {
        RichTextViewPool.release(textView)
    }

    func apply(_ text: MarkdownText, style: MarkdownStyle) {
        self.text = text
        isRightToLeft = style.layoutDirection == .rightToLeft
        rightToLeftHeights.removeAll()
        textView.defaultForegroundColor = style.resolvedTextColor
        delegate.openLink = style.openURL
        // applyContent trusts a same-text prefix to be the same: an update starts clean.
        if textView.textStorage.length > 0 {
            textView.applyContent(NSMutableAttributedString())
        }
        textView.applyContent(NSMutableAttributedString(attributedString: text.attributed))
        textView.invalidateFittingSizes()
        MarkdownPenOverlayView.sync(on: textView)
    }

    /// The text's own size at `width`, inside the insets.
    func fittingSize(width: CGFloat) -> CGSize {
        let inner = max(0, width - insets.left - insets.right)
        guard isRightToLeft else {
            return textView.fittingSize(proposedWidth: inner, proposedHeight: nil)
        }
        // Right to left, a hanging indent makes the reported width too narrow, and cut to it an
        // item wraps early. It keeps all the room; its text is flush right anyway.
        if let height = rightToLeftHeights[inner] { return CGSize(width: inner, height: height) }
        let height = textView.sizeThatFits(CGSize(width: inner, height: 1_000_000)).height
        rightToLeftHeights[inner] = height
        return CGSize(width: inner, height: height)
    }

    /// With the insets.
    func height(forWidth width: CGFloat) -> CGFloat {
        fittingSize(width: width).height + insets.top + insets.bottom
    }

    /// Places the text in `rect`, at the size it asks for, at the leading edge.
    func layout(in rect: CGRect, isRightToLeft: Bool) {
        let size = fittingSize(width: rect.width)
        let x = isRightToLeft ? rect.maxX - insets.right - size.width : rect.minX + insets.left
        let frame = CGRect(x: x, y: rect.minY + insets.top, width: size.width, height: size.height).markdownPixelAligned()
        if textView.frame != frame {
            textView.frame = frame
            MarkdownPenOverlayView.sync(on: textView)
        }
    }
}
