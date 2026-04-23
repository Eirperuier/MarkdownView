//
//  CmarkNodeVisitor.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/12.
//

import Markdown
import SafariServices
import SwiftUI

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
    return
      visitor
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
        MarkdownNodeView(text.plainText)
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
      MarkdownNodeView("\n")
  }

  func visitThematicBreak(_ thematicBreak: ThematicBreak) -> MarkdownNodeView {
    MarkdownNodeView {
      RoundedRectangle(cornerRadius: 2)
            .frame(height: 1)
            .foregroundStyle(.gray.opacity(0.1))
            .padding(.vertical, 15)
    }
  }

  func visitLineBreak(_ lineBreak: LineBreak) -> MarkdownNodeView {
      MarkdownNodeView("\n")
  }

  func visitInlineCode(_ inlineCode: InlineCode) -> MarkdownNodeView {
    var attributedString = AttributedString(stringLiteral: inlineCode.code)
    attributedString.foregroundColor = configuration.inlineCodeTintColor
    attributedString.backgroundColor = configuration.inlineCodeTintColor.opacity(0.1)
    return MarkdownNodeView(attributedString)
  }

  func visitInlineHTML(_ inlineHTML: InlineHTML) -> MarkdownNodeView {
    MarkdownNodeView(
      AttributedString(inlineHTML.rawHTML)
    )
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
    MarkdownNodeView(
      AttributedString(html.rawHTML)
    )
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
    var nodeViews = [MarkdownNodeView]()
    for child in emphasis.children {
      var renderer = self
      let childView = renderer.visit(child)
      if let text = childView.asAttributedString {
        let intent = text.inlinePresentationIntent ?? []
        nodeViews.append(MarkdownNodeView(text.mergingAttributes(
          AttributeContainer()
            .inlinePresentationIntent(intent.union(.emphasized))
        )))
      } else {
        // View-type children (e.g., links) - apply italic modifier
        nodeViews.append(MarkdownNodeView { childView.italic() })
      }
    }
    if nodeViews.count == 1 { return nodeViews[0] }
    return MarkdownNodeView(nodeViews)
  }

  func visitStrong(_ strong: Strong) -> MarkdownNodeView {
    var nodeViews = [MarkdownNodeView]()
    for child in strong.children {
      var renderer = self
      let childView = renderer.visit(child)
      if let text = childView.asAttributedString {
        let intent = text.inlinePresentationIntent ?? []
        nodeViews.append(MarkdownNodeView(text.mergingAttributes(
          AttributeContainer()
            .inlinePresentationIntent(intent.union(.stronglyEmphasized))
            .foregroundColor(configuration.preferredColor)
        )))
      } else {
        // View-type children (e.g., links) - apply bold modifier
        nodeViews.append(MarkdownNodeView { childView.bold() })
      }
    }
    if nodeViews.count == 1 { return nodeViews[0] }
    return MarkdownNodeView(nodeViews)
  }

  func visitStrikethrough(_ strikethrough: Strikethrough) -> MarkdownNodeView {
    var nodeViews = [MarkdownNodeView]()
    for child in strikethrough.children {
      var renderer = self
      let childView = renderer.visit(child)
      if let text = childView.asAttributedString {
        let intent = text.inlinePresentationIntent ?? []
        nodeViews.append(MarkdownNodeView(text.mergingAttributes(
          AttributeContainer()
            .inlinePresentationIntent(intent.union(.strikethrough))
        )))
      } else {
        // View-type children (e.g., links) - apply strikethrough modifier
        nodeViews.append(MarkdownNodeView { childView.strikethrough() })
      }
    }
    if nodeViews.count == 1 { return nodeViews[0] }
    return MarkdownNodeView(nodeViews)
  }

  mutating func visitLink(_ link: Markdown.Link) -> MarkdownNodeView {
    guard let destination = link.destination,
      let url = URL(string: destination)
    else { return descendInto(link) }

    let nodeView = descendInto(link)
    if let text = nodeView.asAttributedString {
      var linked = text
      linked.link = url
      linked.underlineStyle = .single
      linked.foregroundColor = configuration.linkTintColor
      return MarkdownNodeView(linked)
    } else {
      return MarkdownNodeView {
        WebViewPopoverView(url: url, view: nodeView)
          .foregroundStyle(configuration.linkTintColor)
      }
    }
  }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        // 验证 URL scheme
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            print("❌ [SafariView] Invalid URL scheme: \(url.scheme ?? "nil")")
            print("❌ [SafariView] Full URL: \(url.absoluteString)")
            // 返回一个安全的默认 URL
            let fallbackURL = URL(string: "https://www.apple.com")!
            return createSafariViewController(with: fallbackURL)
        }
        
        print("✅ [SafariView] Opening valid URL: \(url.absoluteString)")
        return createSafariViewController(with: url)
    }
    
    private func createSafariViewController(with url: URL) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        #if os(iOS)
        config.barCollapsingEnabled = true
        #endif
        
        let safari = SFSafariViewController(url: url, configuration: config)
        #if os(iOS)
        safari.preferredBarTintColor = UIColor.systemBackground
        safari.preferredControlTintColor = UIColor.label
        #endif
        
        return safari
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // Safari视图不需要更新
    }
}

import LinkPresentation
import UniformTypeIdentifiers

enum ImageStatus {
    case loading
    case finished(SwiftUI.Image)
    case failed(Error)
}

enum LoadingError: Error {
    case contentUnavailable
    case contentTypeNotSupported
}

struct LinkItemView: View {
    @State private var url: URL?
    var view: MarkdownNodeView
    @State private var isValidUrl = true
    @State private var metadata: LPLinkMetadata? = nil
    @State private var imageStatus: ImageStatus = .loading

    init(link: String, view: MarkdownNodeView) {
        _url = State(wrappedValue: URL(string: link))
        self.view = view
    }

    var body: some View {
        VStack {
            /// Valid link
            
            if isValidUrl, let url {
                HStack(alignment: .center) {
                    VStack {
                        switch imageStatus {
                        case .loading:
                            ProgressView()

                        case .finished(let image):
                            image
                                .resizable()
                                .scaledToFill()

                        case .failed:
                            Image(systemName: "photo")
                                .resizable()
                                .scaledToFit()
                                .padding()
                                .foregroundStyle(.gray)
                        }
                    }
                    .clipped()
                    .frame(width: 10, height: 10)
                    .clipShape(Circle())
                    Text(metadata?.title ?? "url title placeholder")
                }
            }
            /// Invalid link
            else {
                view
            }
        }
        .font(.caption2)
        .padding(2)
        .padding(.horizontal, 5)
        .background {
            Capsule().opacity(0.1)
        }
        .task(id: url) {
            await fetchMetadata()
        }
    }

    private func fetchMetadata() async {
        guard let url else {
            isValidUrl = false
            return
        }

        do {
            metadata = try await LPMetadataProvider().startFetchingMetadata(for: url)
            await loadImage(from: metadata?.imageProvider)
        }
        catch {
            //print("Error fetching URL metadata: \(error.localizedDescription)")
            isValidUrl = false
        }
    }

    private func loadImage(from imageProvider: NSItemProvider?) async {
        let imageType = UTType.image.identifier

        do {
            guard let imageProvider, imageProvider.hasItemConformingToTypeIdentifier(imageType) else {
                imageStatus = .failed(LoadingError.contentUnavailable)
                return
            }

            let item = try await imageProvider.loadItem(forTypeIdentifier: imageType)

            if item is UIImage, let image = item as? UIImage {
                imageStatus = .finished(Image(uiImage: image))
            }
            else if item is URL {
                guard let url = item as? URL,
                      let data = try? Data(contentsOf: url),
                      let image = UIImage(data: data)
                else {
                    imageStatus = .failed(LoadingError.contentTypeNotSupported)
                    return
                }
                imageStatus = .finished(Image(uiImage: image))
            }
            else if item is Data {
                guard let data = item as? Data, let image = UIImage(data: data) else {
                    imageStatus = .failed(LoadingError.contentTypeNotSupported)
                    return
                }
                imageStatus = .finished(Image(uiImage: image))
            }
        }
        catch {
            //print("Error loading Image: \(error.localizedDescription)")
            imageStatus = .failed(error)
        }
    }
}
struct WebViewPopoverView: View {
  var url: URL
  var view: MarkdownNodeView

  @State var show: Bool = false
    @Environment(\.openURL) var openURL
  var body: some View {
    Button(
      action: {
        openURL(url)
      },
      label: {
          view
              .multilineTextAlignment(.leading)
              
              .underline()
      }
    )
    .popover(
      isPresented: $show,
      content: {
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
