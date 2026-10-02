//
//  MarkdownStreamBlockView.swift
//  MarkdownView
//
//  Renders one MarkdownStreamBlock, choosing the selectable text path where it holds up.
//  Moved from ios-flowith (SelectableMarkdownBlockLeaf and SelectableListItemWithFence in
//  Views/Components/MarkdownRenderView.swift, FootnoteDefinitionListView in
//  MessageFootnotes.swift); the on/off switch is the environment alone instead of a
//  debug-only user default.
//

#if canImport(RichText)
import SwiftUI

extension EnvironmentValues {
    /// Whether text blocks render through the selectable text view (default true).
    /// Turn it off for offscreen rendering such as share images and PDFs: a
    /// `UITextView` draws nothing under `ImageRenderer`.
    @Entry public var markdownSelectableTextEnabled = true
}

extension View {
    /// Turns the selectable text path on or off for this subtree.
    nonisolated public func markdownSelectableTextEnabled(_ enabled: Bool) -> some View {
        environment(\.markdownSelectableTextEnabled, enabled)
    }
}

/// One top-level markdown block: headings, paragraphs, list items and quotes render
/// selectable, with the same look and reveal as `MarkdownBlockView`; code, tables,
/// math and the rest stay on `MarkdownBlockView` (table body cells turn selectable too).
///
/// A list item that contains a code fence is the exception: heavy blocks hosted as
/// attachments inside the text flow don't size reliably, so only the text before the
/// fence is selectable.
///
/// Created from a ``MarkdownStreamBlock``, it renders the block's math itself: the
/// splitter moves math into storage and would otherwise leave display math blank.
/// Inject the reveal with `markdownStreaming(_:)`.
public struct MarkdownStreamBlockView: View {
    let content: MarkdownContent
    let descriptor: MarkdownBlockDescriptor
    let inlineMathStorage: [String: String]?
    let displayMathStorage: [UUID: String]?

    @Environment(\.markdownSelectableTextEnabled) private var selectableEnabled
    @Environment(\.markdownStreamBlockEdgeInsets) private var edgeInsets

    public init(_ block: MarkdownStreamBlock) {
        self.content = block.content
        self.descriptor = block.descriptor
        self.inlineMathStorage = block.inlineMathStorage
        self.displayMathStorage = block.displayMathStorage
    }

    public init(content: MarkdownContent, descriptor: MarkdownBlockDescriptor) {
        self.content = content
        self.descriptor = descriptor
        self.inlineMathStorage = nil
        self.displayMathStorage = nil
    }

    private var usesSelectableText: Bool {
        guard selectableEnabled else { return false }
        switch descriptor.kind {
        case .heading, .paragraph, .orderedList, .unorderedList:
            if descriptor.listItemContext != nil, containsFence(descriptor.sourceText) { return false }
            return true
        default:
            return false
        }
    }

    private func containsFence(_ source: String) -> Bool {
        source.contains("```") || source.contains("~~~")
    }

    /// Splits a list item with a fence: the text before it (marker included) is selectable,
    /// the fence onwards renders as usual. Nil when the fence is on the first line or
    /// nothing but whitespace precedes it.
    private var listItemFenceSplit: (leading: String, rest: String)? {
        guard selectableEnabled,
              descriptor.listItemContext != nil,
              containsFence(descriptor.sourceText) else { return nil }
        let lines = descriptor.sourceText.components(separatedBy: "\n")
        guard let fenceIndex = lines.firstIndex(where: { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }), fenceIndex > 0 else { return nil }
        let leading = lines[..<fenceIndex].joined(separator: "\n")
        guard !leading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // The rest loses its common indent and becomes top level; the view restores the indent.
        let restLines = Array(lines[fenceIndex...])
        let minIndent = restLines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }
            .min() ?? 0
        let rest = restLines
            .map { String($0.dropFirst(min(minIndent, $0.prefix(while: { $0 == " " }).count))) }
            .joined(separator: "\n")
        return (leading, rest)
    }

    private var isSelectableQuote: Bool {
        guard selectableEnabled else { return false }
        if case .blockQuote = descriptor.kind { return true }
        return false
    }

    /// A paragraph starting with a footnote definition (`[^id]: …`) renders one line per
    /// definition: cmark joins adjacent definition lines into one paragraph.
    private var footnoteDefinitionLines: [String]? {
        guard selectableEnabled, case .paragraph = descriptor.kind else { return nil }
        return FootnoteDefinitionList.split(descriptor.sourceText)
    }

    public var body: some View {
        if inlineMathStorage != nil || displayMathStorage != nil {
            leaf
                .markdownMathRenderingEnabled()
                .markdownInlineMathStorage(inlineMathStorage)
                .markdownDisplayMathStorage(displayMathStorage)
        } else {
            leaf
        }
    }

    @ViewBuilder
    private var leaf: some View {
        if isSelectableQuote {
            SelectableBlockQuote(quoteSource: descriptor.sourceText)
        } else if let lines = footnoteDefinitionLines {
            FootnoteDefinitionList(lines: lines)
        } else if usesSelectableText {
            let depth = descriptor.listItemContext?.depth ?? 0
            MarkdownSelectableText(descriptor.sourceText, listDepthOffset: depth, applyEdgeInsets: edgeInsets)
                // A nested item re-parsed alone has depth 0; add the 20 pt per level `MarkdownBlockView` uses.
                .padding(.leading, CGFloat(depth) * 20)
        } else if let split = listItemFenceSplit {
            SelectableListItemWithFence(
                leading: split.leading,
                rest: split.rest,
                depth: descriptor.listItemContext?.depth ?? 0,
                ordered: descriptor.listItemContext?.listType == .ordered
            )
        } else {
            MarkdownBlockView(content, block: descriptor)
                .markdownTableCellsSelectable(selectableEnabled)
        }
    }
}

/// A list item containing a code fence: the text before the fence is selectable, the
/// rest renders as usual, indented to the item's content (12 + marker + 8 + depth × 20).
private struct SelectableListItemWithFence: View {
    let leading: String
    let rest: String
    let depth: Int
    let ordered: Bool

    @Environment(\.markdownStreamBlockEdgeInsets) private var edgeInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownSelectableText(leading, listDepthOffset: depth, applyEdgeInsets: edgeInsets)
                .padding(.leading, CGFloat(depth) * 20)
            MarkdownView(rest)
                .padding(.leading, CGFloat(depth) * 20 + 12 + (ordered ? 15 : 7) + 8)
        }
    }
}

/// Footnote definitions, one selectable line each (number link and content), smaller and
/// secondary. The whole line carries the definition URL, so tapping anywhere on it works;
/// real links inside keep their own taps.
struct FootnoteDefinitionList: View {
    let lines: [String]
    @Environment(\.markdownRendererConfiguration.footnotes) private var footnotes

    /// Groups a paragraph by definition line (continuation lines join the previous
    /// group); nil unless the first line is a definition.
    static func split(_ source: String) -> [String]? {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, MarkdownFootnoteIndex.definitionLine(first) != nil else { return nil }
        var groups: [String] = []
        for line in lines {
            if MarkdownFootnoteIndex.definitionLine(line) != nil {
                groups.append(line)
            } else if !groups.isEmpty {
                groups[groups.count - 1] += "\n" + line
            }
        }
        return groups.isEmpty ? nil : groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                MarkdownSelectableText(line, applyEdgeInsets: false)
                    // Each line is re-parsed alone, so block-level plain offsets no longer apply.
                    .environment(\.markdownTextRangeDecorations, lineDecorations(line: line, index: index))
            }
        }
        .padding(.vertical, 5)
        .dynamicTypeSize(.xSmall)
        .markdownBaseTextColor(.secondary)
        // Inline anchors are in block coordinates, which don't survive the split.
        .environment(\.markdownTextInlineAnchors, [])
    }

    private func lineDecorations(line: String, index: Int) -> [MarkdownTextRangeDecoration] {
        guard let def = MarkdownFootnoteIndex.definitionLine(line),
              let url = footnotes?.references[def.id]?.definitionURL else { return [] }
        return [MarkdownTextRangeDecoration(
            id: "fndef-\(index)-\(def.id)",
            plainStart: 0,
            plainLength: max(line.count, 1),  // clamped to the storage end
            underlineColor: .clear,           // tappable, no underline
            tapURL: url,
            preservesInnerLinks: true
        )]
    }
}
#endif
