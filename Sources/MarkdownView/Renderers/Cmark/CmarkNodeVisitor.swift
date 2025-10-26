//
//  CmarkNodeVisitor.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import SwiftUI
import Markdown

@MainActor
@preconcurrency
struct CmarkNodeVisitor: @preconcurrency MarkupVisitor {
    var configuration: MarkdownRendererConfiguration
    var isTable: Bool = false
    init(configuration: MarkdownRendererConfiguration) {
        self.configuration = configuration
    }
    
    func makeBody(for markup: any Markup) -> some View {
        var visitor = self
        return visitor
            .visit(markup)
            .environment(\.markdownRendererConfiguration, configuration)
    }

    func visitDocument(_ document: Document) -> MarkdownNodeView {
        var renderer = self
        let nodeViews = document.children.map {
            renderer.visit($0)
        }
        return MarkdownNodeView(nodeViews, layoutPolicy: .linebreak)
    }
    
    func defaultVisit(_ markup: Markdown.Markup) -> MarkdownNodeView {
        descendInto(markup)
    }
    
    func descendInto(_ markup: any Markup) -> MarkdownNodeView {
        var nodeViews = [MarkdownNodeView]()
        for child in markup.children {
            var renderer = self
            let nodeView = renderer.visit(child)
            nodeViews.append(nodeView)
        }
        return MarkdownNodeView(nodeViews)
    }
    
    func visitText(_ text: Markdown.Text) -> MarkdownNodeView {
        if configuration.math.shouldRender {
            InlineMathOrText(text: text.plainText)
                .makeBody(configuration: configuration)
        } else {
            MarkdownNodeView {
                Text(verbatim: text.plainText)
            }
        }
    }
    
    func visitBlockDirective(_ blockDirective: BlockDirective) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownBlockDirective(blockDirective: blockDirective)
        }
    }
    
    func visitBlockQuote(_ blockQuote: BlockQuote) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownBlockQuote(blockQuote: blockQuote)
        }
    }
    
    func visitSoftBreak(_ softBreak: SoftBreak) -> MarkdownNodeView {
        MarkdownNodeView {
            Text(verbatim: " ")
        }
    }
    
    func visitThematicBreak(_ thematicBreak: ThematicBreak) -> MarkdownNodeView {
        MarkdownNodeView {
            Divider()
        }
    }
    
    func visitLineBreak(_ lineBreak: LineBreak) -> MarkdownNodeView {
        MarkdownNodeView {
            Text(verbatim: "\n")
        }
    }
    
    func visitInlineCode(_ inlineCode: InlineCode) -> MarkdownNodeView {
        var attributedString = AttributedString(stringLiteral: inlineCode.code)
        attributedString.foregroundColor = configuration.inlineCodeTintColor
        attributedString.backgroundColor = configuration.inlineCodeTintColor.opacity(0.1)
        return MarkdownNodeView {
            Text(attributedString)
        }
    }
    
    func visitInlineHTML(_ inlineHTML: InlineHTML) -> MarkdownNodeView {
        MarkdownNodeView {
            Text(verbatim: inlineHTML.rawHTML)
        }
    }
    
    func visitImage(_ image: Markdown.Image) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownImage(image: image)
        }
    }
    
    func visitCodeBlock(_ codeBlock: CodeBlock) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownStyledCodeBlock(
                configuration: CodeBlockStyleConfiguration(
                    language: codeBlock.language,
                    code: codeBlock.code,
                    showFullCode: configuration.showFullCode
                )
            )
        }
    }
    
    func visitHTMLBlock(_ html: HTMLBlock) -> MarkdownNodeView {
        MarkdownNodeView {
            Text(verbatim: html.rawHTML)
        }
    }
    
    func visitListItem(_ listItem: ListItem) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownListItem(listItem: listItem)
        }
    }
    
    func visitOrderedList(_ orderedList: OrderedList) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownList(listItemsContainer: orderedList)
        }
    }
    
    func visitUnorderedList(_ unorderedList: UnorderedList) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownList(listItemsContainer: unorderedList)
        }
    }
    
    func visitTable(_ table: Markdown.Table) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownTable(table: table)
        }
    }
    
    func visitTableHead(_ head: Markdown.Table.Head) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownTableRow(
                rowIndex: 0,
                cells: Array(head.cells)
            )
        }
    }
    
    func visitTableBody(_ body: Markdown.Table.Body) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownTableBody(tableBody: body)
        }
    }
    
    func visitTableRow(_ row: Markdown.Table.Row) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownTableRow(
                rowIndex: row.indexInParent + 1 /* header */,
                cells: Array(row.cells)
            )
        }
    }
    
    func visitTableCell(_ cell: Markdown.Table.Cell) -> MarkdownNodeView {
        var cellViews = [MarkdownNodeView]()
        for child in cell.children {
            var renderer = CmarkNodeVisitor(configuration: configuration)
            let cellView = renderer.visit(child)
            cellViews.append(cellView)
        }
        return MarkdownNodeView(
            cellViews,
            alignment: cell.horizontalAlignment
        )
    }
    
    func visitParagraph(_ paragraph: Paragraph) -> MarkdownNodeView {
        let content = defaultVisit(paragraph)
                return MarkdownNodeView {
                    VStack(alignment: .leading, spacing: configuration.componentSpacing) {
                        content
                    }
                    .padding(.vertical, 5)
                }
    }
    
    func visitHeading(_ heading: Heading) -> MarkdownNodeView {
        MarkdownNodeView {
            MarkdownHeading(heading: heading)
        }
    }
    
    func visitEmphasis(_ emphasis: Markdown.Emphasis) -> MarkdownNodeView {
        var textStorage = TextComposer()
        for child in emphasis.children {
            var renderer = self
            guard let text = renderer.visit(child).asText else { continue }
            textStorage.append(text.italic())
        }
        return MarkdownNodeView(textStorage.text)
    }
    
    func visitStrong(_ strong: Strong) -> MarkdownNodeView {
        var textStorage = TextComposer()
        for child in strong.children {
            var renderer = self
            guard let text = renderer.visit(child).asText else { continue }
            if #available(iOS 17.0, *) {
                textStorage.append(text.bold().foregroundStyle(configuration.preferredColor))
            } else {
                textStorage.append(text.bold())
            }
        }
        return MarkdownNodeView(textStorage.text)
    }
    
    func visitStrikethrough(_ strikethrough: Strikethrough) -> MarkdownNodeView {
        var textStorage = TextComposer()
        for child in strikethrough.children {
            var renderer = self
            guard let text = renderer.visit(child).asText else { continue }
            textStorage.append(text.strikethrough())
        }
        return MarkdownNodeView(textStorage.text)
    }
    
    mutating func visitLink(_ link: Markdown.Link) -> MarkdownNodeView {
        guard let destination = link.destination,
              let url = URL(string: destination)
        else { return descendInto(link) }
        
        let nodeView = descendInto(link)
        switch nodeView.contentType {
        case .text:
            return MarkdownNodeView {
                WebViewPopoverView(url: url, view: nodeView)
                                    .foregroundStyle(configuration.linkTintColor)
            }
        case .view:
            return MarkdownNodeView {
                WebViewPopoverView(url: url, view: nodeView)
                                    .foregroundStyle(configuration.linkTintColor)
            }
        }
    }
}

import SafariServices


struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.preferredBarTintColor = UIColor.systemBackground
        safari.preferredControlTintColor = UIColor.label
        safari.modalPresentationStyle = .pageSheet
        
        //print("[SafariView] 🌐 Opening 3D model with AR support in Safari: \(url)")
        
        return safari
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // Safari视图不需要更新
    }
}




struct WebViewPopoverView: View {
    var url: URL
    var view: MarkdownNodeView
    
    @State var show: Bool = false
    var body: some View {
        Button(action: {
            show = true
        }, label: {
            view
                .font(.caption2)
                .padding(2)
                .padding(.horizontal, 5)
                .background(.tertiary.opacity(0.3))
                .clipShape(Capsule())
        })
        .popover(isPresented: $show, content: {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    SafariView(url: url)
                        .ignoresSafeArea()
                }
                .frame(idealWidth: 500, idealHeight: 700)
               
            } else {
                NavigationView {
                    SafariView(url: url)
                }
            }
        })
        
    }
    
}
