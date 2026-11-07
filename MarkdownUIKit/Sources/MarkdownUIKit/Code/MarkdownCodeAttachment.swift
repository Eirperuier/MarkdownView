//
//  MarkdownCodeAttachment.swift
//  MarkdownUIKit
//
//  A code block inside other text: a fence in a quote, as wide as the line.
//

import Markdown
import RichTextCore
import UIKit

final class MarkdownCodeAttachment: RichTextAttachment {
    private let view: any MarkdownCodeDisplay
    private let source: String

    @MainActor
    init(id: AnyHashable, code: CodeBlock, style: MarkdownStyle) {
        source = code.format()
        view = style.codeBlock.makeDisplay(for: code.language)
        super.init(id: id, sizing: .fittingLineFragment)
        view.configure(code: code.code, language: code.language, style: style, reveal: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    override var contentView: UIView { view }

    @MainActor
    override func sizeThatFits(in proposal: CGSize) -> CGSize? {
        CGSize(width: proposal.width, height: view.height(forWidth: proposal.width))
    }

    override func replacementText() -> NSAttributedString? { NSAttributedString(string: source) }
}
