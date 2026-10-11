//
//  DocMedia.swift
//  DemoApp
//
//  Links, files and images on the page, as Craft draws them. Links and files share one
//  set of layouts: small (a pill as wide as its name), regular (a row: thumbnail,
//  title, details) and card (half the page: the preview on top, the text below).
//  Images fit or fill, at their own size or the page's width.
//

import SwiftUI
import DocKit

/// A link, file or image block's view.
struct DocMediaView: View {
    let kind: BlockKind
    /// While blocks are selected a small one leaves room for its dot.
    var reservesDot = false

    var body: some View {
        switch kind {
        case .link(let link): DocLinkView(link: link, reservesDot: reservesDot)
        case .file(let file): DocFileView(file: file, reservesDot: reservesDot)
        case .image(let image): DocImageView(image: image)
        default: EmptyView()
        }
    }

    /// The kinds this view draws.
    static func draws(_ kind: BlockKind) -> Bool {
        switch kind {
        case .link, .file, .image: true
        default: false
        }
    }
}

// MARK: Links

/// A link. A click selects it and a double click opens it (DocBlockController: the
/// list's taps, not a SwiftUI gesture, which a reused cell carries into later rows).
struct DocLinkView: View {
    let link: DocLink
    var reservesDot = false

    var body: some View {
        DocMediaBox(shown: link.layout) {
            switch link.layout {
            case .small: small
            case .regular: regular
            case .card: card
            }
        }
    }

    private var small: some View {
        // Craft's: the thumbnail at the left edge, as tall as the row.
        HStack(spacing: 10) {
            DocMediaPreview(source: link.image) { DocLinkIcon(link: link, size: 20) }
                .frame(width: (36 * 1.4).rounded(), height: 36)
                .clipped()
            Text(title)
                .font(.system(size: 15))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.trailing, reservesDot ? 34 : 12)
        .frame(height: 36)
        .docLayout(.small)
    }

    private var regular: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                DocMediaPreview(source: link.image) { DocLinkIcon(link: link, size: 28) }
                    .frame(width: 82, height: 62)
                    .clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17))
                        .lineLimit(1)
                    Text(link.summary.isEmpty ? address : link.summary)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, reservesDot ? 34 : 12)
                .frame(height: 62)
            }
            DocLinkFooter(link: link)
        }
        .docLayout(.regular)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            DocMediaPreview(source: link.image) { DocLinkIcon(link: link, size: 36) }
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                if !link.summary.isEmpty {
                    Text(link.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            DocLinkFooter(link: link)
        }
        .frame(width: DocMediaLayout.cardWidth, height: 222)
        .docLayout(.card)
    }

    private var title: String { link.title.isEmpty ? address : link.title }
    /// The address as it reads (not percent-encoded).
    private var address: String { link.url.removingPercentEncoding ?? link.url }
}

/// The strip under a link: where it goes.
private struct DocLinkFooter: View {
    let link: DocLink

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 11))
            Text(DocMediaLayout.host(link.url))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) { Rectangle().fill(DocMediaLayout.border).frame(height: 1) }
    }
}

/// A link with no preview of its own: a globe on a soft square.
private struct DocLinkIcon: View {
    let link: DocLink
    let size: CGFloat

    var body: some View {
        Image(systemName: "globe")
            .font(.system(size: size * 0.55))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: size * 0.22, style: .continuous))
    }
}

// MARK: Files

struct DocFileView: View {
    let file: DocFile
    var reservesDot = false

    var body: some View {
        DocMediaBox(shown: file.layout) {
            switch file.layout {
            case .small: small
            case .regular: regular
            case .card: card
            }
        }
    }

    private var small: some View {
        HStack(spacing: 8) {
            DocFileIcon(name: file.name, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DocMediaLayout.kind(of: file.name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, reservesDot ? 34 : 10)
        .frame(height: 42)
        .docLayout(.small)
    }

    private var regular: some View {
        HStack(spacing: 14) {
            DocFileIcon(name: file.name, height: 52)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 17))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details.joined(separator: "\n"))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, reservesDot ? 34 : 14)
        .padding(.vertical, 10)
        .docLayout(.regular)
    }

    private var card: some View {
        VStack(spacing: 0) {
            DocFileIcon(name: file.name, height: 72)
                .frame(maxWidth: .infinity)
                .frame(height: 104)
                .background(Color(.secondarySystemBackground))
            VStack(spacing: 2) {
                Text(file.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details.joined(separator: "\n"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .frame(width: DocMediaLayout.cardWidth, height: 182)
        .docLayout(.card)
    }

    private var details: [String] {
        [DocMediaLayout.kind(of: file.name)] + (file.size.map { [DocMediaLayout.bytes($0)] } ?? [])
    }
}

/// A sheet of paper with a corner folded, its type on a colored tag (as the Finder
/// and Craft draw a document).
struct DocFileIcon: View {
    let name: String
    let height: CGFloat

    var body: some View {
        let width = height * 0.78
        ZStack(alignment: .bottomLeading) {
            DocPage(fold: height * 0.24)
                .fill(Color.white)
                .overlay(DocPage(fold: height * 0.24).stroke(Color.black.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                .frame(width: width, height: height)
            Text(tag)
                .font(.system(size: height * 0.2, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, height * 0.07)
                .frame(minWidth: width * 0.62)
                .frame(height: height * 0.3)
                .background(color, in: .rect(cornerRadius: height * 0.05))
                .offset(x: -height * 0.06, y: -height * 0.16)
        }
        .frame(width: width, height: height)
    }

    private var tag: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }

    private var color: Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "doc", "docx", "pages", "rtf": Color(red: 0.17, green: 0.36, blue: 0.9)
        case "xls", "xlsx", "numbers", "csv": Color(red: 0.12, green: 0.56, blue: 0.24)
        case "ppt", "pptx", "key": Color(red: 0.85, green: 0.33, blue: 0.12)
        case "pdf": Color(red: 0.9, green: 0.15, blue: 0.16)
        default: Color(.systemGray)
        }
    }
}

private struct DocPage: Shape {
    let fold: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 2
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        // The folded corner.
        path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        return path
    }
}

// MARK: Images

struct DocImageView: View {
    let image: DocImage

    var body: some View {
        let natural = DocMediaLayout.naturalSize(image.source)
        GeometryReader { proxy in
            let width = image.size == .large ? proxy.size.width : min(proxy.size.width, natural?.width ?? proxy.size.width)
            DocMediaPreview(source: image.source, fill: image.fit == .fill) { Color(.secondarySystemBackground) }
                .frame(width: width, height: DocMediaLayout.imageHeight(image, width: proxy.size.width))
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .frame(height: DocMediaLayout.imageHeight(image, width: DocMediaLayout.pageWidth))
        .accessibilityLabel(image.alt)
    }
}

// MARK: Shared

/// A preview image from a source: an asset (`asset:name`, the demo's), or a URL.
private struct DocMediaPreview<Placeholder: View>: View {
    let source: String?
    var fill = true
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        if let source, let image = DocMediaLayout.asset(source) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: fill ? .fill : .fit)
        } else if let source, let url = URL(string: source), url.scheme?.hasPrefix("http") == true,
                  let image = DocImageCache.shared.image(url) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: fill ? .fill : .fit)
        } else {
            placeholder()
        }
    }
}

enum DocMediaLayout {
    static let border = Color(.separator).opacity(0.5)
    /// Half the page, less the gap between two cards.
    static var cardWidth: CGFloat { min(240, (pageWidth - 12) / 2) }
    /// The page's text width (as wide as a block can be).
    static var pageWidth: CGFloat {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }.first ?? 390
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }.first ?? screen
        return min(720, window - DocBlockController.leadingGutter - DocBlockController.trailingGutter)
    }

    /// Fill: a 4:3 box the image covers; fit: the image's own shape.
    static func imageHeight(_ image: DocImage, width: CGFloat) -> CGFloat {
        let natural = naturalSize(image.source)
        let shown = image.size == .large ? width : min(width, natural?.width ?? width)
        guard image.fit == .fit, let natural, natural.width > 0 else { return (shown * 3 / 4).rounded() }
        return min(640, (shown * natural.height / natural.width).rounded())
    }

    static func naturalSize(_ source: String) -> CGSize? {
        asset(source).map { $0.size }
    }

    static func asset(_ source: String) -> UIImage? {
        source.hasPrefix("asset:") ? UIImage(named: String(source.dropFirst("asset:".count))) : nil
    }

    /// The box a link, file or image alone in its row takes, at the page's `width`:
    /// a card's or a small pill's own size, a regular row's the page's, an image's as
    /// it shows.
    @MainActor static func boxSize(_ kind: BlockKind, width: CGFloat) -> CGSize? {
        switch kind {
        case .image(let image):
            let shown = image.size == .large ? width : min(width, naturalSize(image.source)?.width ?? width)
            return CGSize(width: shown, height: imageHeight(image, width: width))
        case .link, .file:
            let key = BoxKey(kind: kind, width: width)
            if let size = boxSizes[key] { return size }
            let host = UIHostingController(rootView: DocMediaView(kind: kind))
            let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            boxSizes[key] = size
            return size
        default:
            return nil
        }
    }

    private struct BoxKey: Hashable {
        let kind: BlockKind
        let width: CGFloat
    }

    @MainActor private static var boxSizes: [BoxKey: CGSize] = [:]

    static func host(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "DOCX File"
    static func kind(of name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "File") : String(localized: "\(ext) File")
    }

    /// "9.0 KB", "2.4 MB"
    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    /// Rough heights for the list before it measures (DocRow.estimatedHeight).
    static func estimatedHeight(_ kind: BlockKind) -> CGFloat? {
        switch kind {
        case .link(let link): [DocLayout.small: 36, .regular: 88, .card: 222][link.layout]
        case .file(let file): [DocLayout.small: 42, .regular: 92, .card: 182][file.layout]
        case .image(let image): imageHeight(image, width: pageWidth)
        default: nil
        }
    }
}

/// A link or file's box (white, a light border, rounded corners) around its layout, as
/// big as the layout it shows. A new layout is the box going from the old one's size to
/// the new one's, with the change's animation (Craft's): the new layout fades in at its
/// own size and the old one out at its own, both cut to the box as it goes.
private struct DocMediaBox<Content: View>: View {
    let shown: DocLayout
    @ViewBuilder let content: () -> Content

    var body: some View {
        DocMediaBoxLayout(shown: shown) { content() }
            .docMediaBox()
    }
}

/// Sized by the layout shown; one going away keeps its own size under it.
private struct DocMediaBoxLayout: Layout {
    let shown: DocLayout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let current = subviews.first { $0[DocLayoutKey.self] == shown } ?? subviews.last
        return current?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
    }
}

private struct DocLayoutKey: LayoutValueKey {
    static let defaultValue: DocLayout? = nil
}

private extension View {
    /// A layout's content in its box: it fades as the box changes to or from it.
    func docLayout(_ layout: DocLayout) -> some View {
        layoutValue(key: DocLayoutKey.self, value: layout)
            .transition(.opacity)
    }
}

extension View {
    func docMediaBox() -> some View {
        background(Color(.systemBackground))
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DocMediaLayout.border, lineWidth: 1))
    }
}

// MARK: Runs

extension DocMediaLayout {
    static let gap: CGFloat = 12

    /// What run a block joins (cards with cards, images with images); nil: it stands
    /// alone. A large image always does.
    enum Run { case cards, gallery }

    static func run(_ kind: BlockKind) -> Run? {
        switch kind {
        case .link(let link) where link.layout == .card: .cards
        case .file(let file) where file.layout == .card: .cards
        case .image(let image) where image.size == .auto: .gallery
        default: nil
        }
    }

    /// Where each block of a run sits, from the run's top left, at `width`: cards in as many
    /// columns as fit, each line as tall as its tallest; images in lines of up to four,
    /// one height per line, as wide together as the page (no taller than 280).
    static func runFrames(_ kinds: [BlockKind], width: CGFloat) -> [CGRect] {
        guard let first = kinds.first, let run = run(first) else { return [] }
        var frames: [CGRect] = []
        var y: CGFloat = 0
        switch run {
        case .cards:
            let card = cardWidth
            let columns = max(1, Int((width + gap) / (card + gap)))
            for line in stride(from: 0, to: kinds.count, by: columns) {
                let members = kinds[line..<min(line + columns, kinds.count)]
                let height = members.map(cardHeight).max() ?? 0
                for (column, kind) in members.enumerated() {
                    frames.append(CGRect(x: CGFloat(column) * (card + gap), y: y, width: card, height: cardHeight(kind)))
                }
                y += height + gap
            }
        case .gallery:
            for line in stride(from: 0, to: kinds.count, by: 4) {
                let ratios = kinds[line..<min(line + 4, kinds.count)].map(aspect)
                let height = min(280, (width - gap * CGFloat(ratios.count - 1)) / ratios.reduce(0, +)).rounded(.down)
                var x: CGFloat = 0
                for ratio in ratios {
                    let w = (ratio * height).rounded(.down)
                    frames.append(CGRect(x: x, y: y, width: w, height: height))
                    x += w + gap
                }
                y += height + gap
            }
        }
        return frames
    }

    private static func cardHeight(_ kind: BlockKind) -> CGFloat {
        if case .file = kind { 182 } else { 222 }
    }

    /// An image's width over its height in a gallery (4:3 when it fills, or unknown).
    private static func aspect(_ kind: BlockKind) -> CGFloat {
        guard case .image(let image) = kind, image.fit == .fit, let size = naturalSize(image.source), size.height > 0 else { return 4 / 3 }
        return size.width / size.height
    }
}

/// A link, file or image with what selecting adds: a dot inside its box at its right,
/// a tinted outline around it (Craft's); on the Mac a right-click offers its layouts.
/// `size` sets an image's box in a gallery.
struct DocMediaCell: View {
    let id: DocBlockID
    let kind: BlockKind
    let blocks: DocBlockController
    var size: CGSize?

    var body: some View {
        let isSelected = blocks.selected.contains(id)
        content
            .overlay(alignment: .trailing) {
                if blocks.isSelecting {
                    DocSelectionDot(isOn: isSelected)
                        .padding(.trailing, 10)
                        .transition(.opacity)
                }
            }
            .animation(FlooDesignTokens.Motion.feedback, value: blocks.isSelecting)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .modifier(DocMediaContextMenu(kind: kind, block: id, blocks: blocks))
    }

    @ViewBuilder
    private var content: some View {
        if case .image(let image) = kind, let size {
            DocMediaPreview(source: image.source, fill: image.fit == .fill) { Color(.secondarySystemBackground) }
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(image.alt)
        } else {
            DocMediaView(kind: kind, reservesDot: blocks.isSelecting)
        }
    }
}

/// The dot inside a selected link, file or image: a ring, filled with the tint when
/// the block is selected.
private struct DocSelectionDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Color.accentColor : Color(.systemBackground))
            .overlay { if !isOn { Circle().strokeBorder(Color(.systemGray3), lineWidth: 1.5) } }
            .frame(width: 14, height: 14)
    }
}

/// On the Mac a right-click offers a link, file or image's layouts.
private struct DocMediaContextMenu: ViewModifier {
    let kind: BlockKind
    let block: DocBlockID
    let blocks: DocBlockController

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.contextMenu { DocMediaMenu(kind: kind, block: block, blocks: blocks) }
        #else
        content
        #endif
    }
}
