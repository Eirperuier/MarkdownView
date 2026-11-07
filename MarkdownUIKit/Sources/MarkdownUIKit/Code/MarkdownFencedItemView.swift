//
//  MarkdownFencedItemView.swift
//  MarkdownUIKit
//
//  A list item holding a code fence: the text before the fence (marker included), then the rest
//  as blocks of its own, indented to the item's content. An item that starts with a fence has
//  its marker on a line of its own, and its code under it from the edge, as MarkdownView draws it.
//
//  MarkdownView's also has empty code boxes after such an item: it takes the closing line for the
//  fence, in its own split and when it checks that fences are closed. That isn't copied here.
//

import FlooUIKit
import Markdown
import MarkdownCore
import RichTextCore
import UIKit

@MainActor
final class MarkdownFencedItemView: UIView {
    /// The block changed height by itself.
    var onHeightChange: (() -> Void)?

    private let host = MarkdownTextHost()
    private var hostIsShowing = false
    private var rest: [MarkdownBlockView] = []
    private var splitter = MarkdownBlockSplitter()
    private var style = MarkdownStyle()
    private var leading: CGFloat = 0
    private var restIndent: CGFloat = 0
    private var gate: MarkdownRevealGate?
    /// The lead's plain length: the rest appears when a reveal gets past it.
    private var gateThreshold = -1

    private var firstSpacing: CGFloat = 6

    /// An item with a fence: its text, and what's from the fence on.
    struct Split {
        var lead: String
        var rest: String
        /// The fence opens the item: the code goes from the edge.
        var startsWithFence: Bool
    }

    static func split(_ source: String) -> Split? {
        guard source.contains("```") || source.contains("~~~") else { return nil }
        let lines = source.components(separatedBy: "\n")
        // `- ```swift`: the fence is on the marker's line. Its closing line isn't the fence.
        if let first = lines.first, let fence = first.range(of: "```") ?? first.range(of: "~~~"),
           first[..<fence.lowerBound].allSatisfy({ !$0.isLetter && $0 != "`" && $0 != "~" }) {
            let opening = String(first[fence.lowerBound...])
            return Split(lead: String(first[..<fence.lowerBound]), rest: dedented([opening] + lines.dropFirst(), keepingFirst: true), startsWithFence: true)
        }
        func isFence(_ line: String) -> Bool {
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }
        guard let index = lines.firstIndex(where: isFence), index > 0 else { return nil }
        let lead = lines[..<index].joined(separator: "\n")
        guard !lead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Split(lead: lead, rest: dedented(Array(lines[index...])), startsWithFence: false)
    }

    /// The rest loses its common indent and becomes top level; the view restores the indent.
    private static func dedented(_ lines: [String], keepingFirst: Bool = false) -> String {
        let measured = (keepingFirst ? Array(lines.dropFirst()) : lines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let indent = measured.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return lines.enumerated().map { index, line in
            if keepingFirst, index == 0 { return line }
            return String(line.dropFirst(min(indent, line.prefix(while: { $0 == " " }).count)))
        }.joined(separator: "\n")
    }

    func configure(_ split: Split, depth: Int, ordered: Bool, style: MarkdownStyle, reveal: MarkdownReveal?, inlineMath: [String: String]?, displayMath: [UUID: String]?) {
        self.style = style
        leading = CGFloat(depth) * 20
        restIndent = split.startsWithFence ? 0 : leading + 12 + (ordered ? 15 : 7) + 8
        firstSpacing = split.startsWithFence ? 10 : 6
        let text = MarkdownTextBuilder.build(markdown: split.lead, style: style, listDepthOffset: depth, inlineMath: inlineMath, displayMath: displayMath)
        if style.addsEdgeInsets {
            host.insets = UIEdgeInsets(top: text.topEdgeInset, left: 0, bottom: text.bottomEdgeInset, right: 0)
        }
        if hostIsShowing {
            host.update(text, style: style, reveal: reveal)
        } else {
            host.apply(text, style: style, reveal: reveal)
            addSubview(host.view)
            hostIsShowing = true
        }
        let blocks = splitter.split(split.rest)
        while rest.count > blocks.count { rest.removeLast().removeFromSuperview() }
        for (index, block) in blocks.enumerated() {
            let view: MarkdownBlockView
            if index < rest.count {
                view = rest[index]
            } else {
                view = MarkdownBlockView()
                view.onHeightChange = { [weak self] in
                    self?.setNeedsLayout()
                    self?.onHeightChange?()
                }
                addSubview(view)
                rest.append(view)
            }
            view.configure(block, style: style)
        }
        followGate(reveal, threshold: text.revealTotal)
        setNeedsLayout()
    }

    func setReveal(_ reveal: MarkdownReveal?) {
        host.setReveal(reveal)
        followGate(reveal, threshold: host.text?.revealTotal ?? 0)
    }

    private func followGate(_ reveal: MarkdownReveal?, threshold: Int) {
        guard let reveal else {
            gate?.stop()
            gate = nil
            rest.forEach { $0.alpha = 1 }
            return
        }
        if gate == nil || gateThreshold != threshold {
            gate?.stop()
            gateThreshold = threshold
            gate = MarkdownRevealGate(threshold: threshold) { [weak self] isOpen, fades in
                guard let self else { return }
                let change = { self.rest.forEach { $0.alpha = isOpen ? 1 : 0 } }
                if fades {
                    FlooMotion.markdownBlockReveal.animate(change)
                } else {
                    change()
                }
            }
        }
        gate?.follow(reveal.manager)
    }

    func release() {
        gate?.stop()
        gate = nil
        host.release()
        hostIsShowing = false
        rest.forEach { $0.prepareForReuse() }
    }

    var textViews: [UITextView] {
        [host.textView] + rest.flatMap(\.textViews)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        var height = host.height(forWidth: width - leading)
        for (index, view) in rest.enumerated() {
            height += (index == 0 ? firstSpacing : style.componentSpacing) + view.height(forWidth: width - restIndent)
        }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y = host.height(forWidth: bounds.width - leading)
        host.layout(in: CGRect(x: leading, y: 0, width: bounds.width - leading, height: y), isRightToLeft: false)
        for (index, view) in rest.enumerated() {
            y += index == 0 ? firstSpacing : style.componentSpacing
            let height = view.height(forWidth: bounds.width - restIndent)
            view.frame = CGRect(x: restIndent, y: y, width: bounds.width - restIndent, height: height).markdownPixelAligned()
            y += height
        }
    }
}
