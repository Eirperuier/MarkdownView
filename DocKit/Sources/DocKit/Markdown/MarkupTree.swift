//
//  MarkupTree.swift
//  DocKit
//
//  A block as the markdown tree it reads as, built straight from the model: what the
//  editing markdown (`markdown(of:style: .editing)`) would parse into, without writing
//  it or parsing it. A renderer that takes trees (MarkdownView's MarkdownTree) then
//  shows the block exactly: nothing escaped, nothing in its text read as syntax. What
//  markdown has no node for is an inline attributes node, as MarkdownView reads them:
//  a colour, a highlight, a pen mark (`color: red`, `highlight`, `pen: circle, ink:
//  blue`) and inline maths (`math`, its LaTeX as the text); display maths is a `math`
//  directive, its LaTeX as the text inside.
//

public import Markdown

extension Doc {
    /// The block as a tree, with how deep it is: a paragraph, a heading, a quote, a caption, a list
    /// item as a list of one (numbered as it is in its list), code, maths, a divider, a
    /// card or a view (its fence) or a table. Nil for an image, a link or a file (no tree holds
    /// what they show) and a database the doc doesn't have.
    public func markupTree(of id: DocBlockID) -> (document: Document, depth: Int)? {
        var layout = ListLayout()
        for block in blocks {
            let placement = layout.place(block)
            guard block.id == id else { continue }
            let inlines = InlineTreeBuilder.inlines(block.text, singleLine: false)
            switch block.kind {
            case .paragraph:
                return (Document(Paragraph(inlines)), 0)
            case .heading(let level):
                return (Document(Heading(level: level, InlineTreeBuilder.inlines(block.text, singleLine: true))), 0)
            case .quote:
                return (Document(BlockQuote(Paragraph(inlines))), 0)
            case .caption:
                // Its text (the markdown's `<small>` tags aren't content): the renderer
                // sets a caption's type.
                return (Document(Paragraph(inlines)), 0)
            case .listItem(let style):
                guard placement != nil else { return nil }
                let checkbox: Checkbox? = if case .task(let done) = style { done ? .checked : .unchecked } else { nil }
                let item = ListItem(checkbox: checkbox, Paragraph(inlines))
                if style == .numbered {
                    var list = OrderedList([item])
                    list.startIndex = UInt(layout.ordinal)
                    return (Document(list), layout.depth)
                }
                return (Document(UnorderedList([item])), layout.depth)
            case .code(let language):
                let code = block.text.string
                return (Document(CodeBlock(language: language.flatMap { $0.isEmpty ? nil : $0 }, code.isEmpty ? "" : code + "\n")), 0)
            case .math:
                return (Document(BlockDirective(name: "math", children: [Paragraph(Text(block.text.string))])), 0)
            case .divider:
                return (Document(ThematicBreak()), 0)
            case .card(let card):
                guard let json = Self.json(of: card) else { return nil }
                return (Document(CodeBlock(language: "floo.card", json + "\n")), 0)
            case .view(let view):
                guard let json = Self.json(of: view) else { return nil }
                return (Document(CodeBlock(language: "floo.view", json + "\n")), 0)
            case .database(let id, let view):
                guard let table = databases[id]?.cells(view: view) else { return nil }
                func cell(_ text: String) -> Table.Cell {
                    text.isEmpty ? Table.Cell() : Table.Cell(Text(text.replacing("\n", with: " ")))
                }
                return (Document(Table(
                    columnAlignments: Array(repeating: nil, count: table.header.count),
                    header: Table.Head(table.header.map(cell)),
                    body: Table.Body(table.rows.map { Table.Row($0.map(cell)) })
                )), 0)
            case .image, .link, .file:
                return nil
            }
        }
        return nil
    }
}

/// A block's text as inline nodes, nested the way the markdown writer nests its
/// delimiters (InlineWriter): at each cut the marks that end close, innermost first,
/// and the ones that start open, the longest outermost.
enum InlineTreeBuilder {
    static func inlines(_ text: DocText, singleLine: Bool) -> [any InlineMarkup] {
        // An empty block, or an empty last line, keeps its line with a zero-width space
        // (as the editing markdown's `&#8203;`).
        guard !text.isEmpty else { return [Text("\u{200B}")] }
        let units = Array(text.string.utf16)
        let atoms = Dictionary(text.marks.filter { $0.mark.kind.isAtom }.map { ($0.range.lowerBound, $0.mark) }, uniquingKeysWith: { a, _ in a })
        let spans = text.marks.filter { !$0.mark.kind.isAtom }
        var cuts = Set([0, units.count])
        for span in spans { cuts.formUnion([span.range.lowerBound, span.range.upperBound]) }
        for offset in atoms.keys { cuts.formUnion([offset, offset + 1]) }

        var stack: [(span: MarkSpan?, children: [any InlineMarkup])] = [(nil, [])]
        func close(through index: Int) {
            while stack.count > index {
                let frame = stack.removeLast()
                stack[stack.count - 1].children.append(container(frame.span!.mark, frame.children))
            }
        }
        let bounds = cuts.sorted()
        for (lower, upper) in zip(bounds, bounds.dropFirst()) {
            let active = spans.filter { $0.range.lowerBound <= lower && upper <= $0.range.upperBound }
            if let first = stack.indices.dropFirst().first(where: { !active.contains(stack[$0].span!) }) {
                close(through: first)
            }
            let open = active.filter { span in span.mark != .code && !stack.contains { $0.span == span } }
                .sorted { ($0.range.upperBound, -$0.mark.kind.sortOrder) > ($1.range.upperBound, -$1.mark.kind.sortOrder) }
            for span in open { stack.append((span, [])) }
            let piece = String(decoding: units[lower..<upper], as: UTF16.self)
            if let atom = atoms[lower] {
                stack[stack.count - 1].children.append(Self.atom(atom))
            } else if active.contains(where: { $0.mark == .code }) {
                stack[stack.count - 1].children.append(InlineCode(piece.replacing("\n", with: " ")))
            } else {
                stack[stack.count - 1].children += lines(piece, singleLine: singleLine)
            }
        }
        close(through: 1)
        var result = stack[0].children
        if !singleLine, text.string.hasSuffix("\n") { result.append(Text("\u{200B}")) }
        return result
    }

    /// Text with its line breaks as hard breaks (the editing markdown writes them so), or
    /// as spaces in a single line (a heading).
    private static func lines(_ piece: String, singleLine: Bool) -> [any InlineMarkup] {
        guard piece.contains("\n") else { return [Text(piece)] }
        if singleLine { return [Text(piece.replacing("\n", with: " "))] }
        var nodes: [any InlineMarkup] = []
        for (index, line) in piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { nodes.append(LineBreak()) }
            if !line.isEmpty { nodes.append(Text(String(line))) }
        }
        return nodes
    }

    private static func atom(_ mark: Mark) -> any InlineMarkup {
        switch mark {
        case .inlineMath(let latex): InlineAttributes(attributes: "math", Text(latex))
        case .cite(let url, let label): Link(destination: url, title: "cite", [Text(label)])
        case .mention(_, _, let label): Text(label)
        default: Text("")
        }
    }

    /// The node a mark is, around its children. (The typed initialisers take only the
    /// inline nodes that can nest in themselves, not inline attributes, which cmark
    /// nests anywhere: the children go in unchecked.)
    private static func container(_ mark: Mark, _ children: [any InlineMarkup]) -> any InlineMarkup {
        let node: any InlineMarkup = switch mark {
        case .bold: Strong()
        case .italic: Emphasis()
        case .strike: Strikethrough()
        case .link(let url): Link(destination: url)
        case .highlight(let color): InlineAttributes(attributes: color.map { "highlight: \($0)" } ?? "highlight")
        case .color(let color): InlineAttributes(attributes: "color: \(color)")
        case .pen(let kind, let color): InlineAttributes(attributes: "pen: \(kind)" + (color.map { ", ink: \($0)" } ?? ""))
        case .code, .mention, .inlineMath, .cite: Text("")
        }
        return node.withUncheckedChildren(children.map { $0 as any Markup }) as! any InlineMarkup
    }
}
