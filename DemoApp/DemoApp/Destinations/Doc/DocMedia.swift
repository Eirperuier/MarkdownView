//
//  DocMedia.swift
//  DemoApp
//
//  Links, files and images on the page, as Craft draws them. Links and files are
//  FlooDesign's cards in the block's layout: small (a pill as wide as its name), regular
//  (a row: thumbnail, title, details) and card (a column of the page: the preview on
//  top, the text below). Images fit or fill, at their own size or the page's width.
//

import SwiftUI
import DocKit
import FlooDesign

/// A link, file or image block's view.
struct DocMediaView: View {
    let kind: BlockKind

    var body: some View {
        switch kind {
        case .link(let link): DocLinkView(link: link)
        case .file(let file): DocFileView(file: file)
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

// MARK: Links and files

/// A link (FlooDesign's link card). A click selects it and a double click opens it
/// (DocBlockController: the list's taps, not a SwiftUI gesture, which a reused cell
/// carries into later rows).
struct DocLinkView: View {
    let link: DocLink

    var body: some View {
        FlooDesignLinkCard(style: link.layout.style, title: link.title.isEmpty ? address : link.title,
                           summary: link.summary.isEmpty ? address : link.summary, hasSummary: !link.summary.isEmpty,
                           host: DocMediaLayout.host(link.url), preview: DocMediaLayout.picture(link.image),
                           widest: DocMediaLayout.widestPage)
    }

    /// The address as it reads (not percent-encoded).
    private var address: String { link.url.removingPercentEncoding ?? link.url }
}

/// A file (FlooDesign's file card).
struct DocFileView: View {
    let file: DocFile

    var body: some View {
        FlooDesignFileCard(style: file.layout.style, name: file.name, kind: DocMediaLayout.kind(of: file.name),
                           size: file.size.map(DocMediaLayout.bytes), widest: DocMediaLayout.widestPage)
    }
}

// MARK: Images

/// An image in its box: alone, as its fit and size make it at the width it's given; in a
/// gallery, that width at its shape (DocMediaLayout.aspect). The picture is drawn at the
/// size its fit gives it in the box, covering it or inside it, centred and cut to the
/// box: a new fit, size or place is the box and the picture each going from one size to
/// the other.
struct DocImageView: View {
    let image: DocImage
    var inGallery = false

    var body: some View {
        DocImageLayout(image: image, inGallery: inGallery) {
            DocMediaPreview(source: image.source) { FlooDesignTokens.Component.MediaCard.panel }
        }
        .clipShape(.rect(cornerRadius: FlooDesignTokens.Component.MediaCard.cornerRadius, style: .continuous))
        .accessibilityLabel(image.alt)
    }
}

/// An image's box at the width it's given, its picture centred in it at its drawn size.
private struct DocImageLayout: Layout {
    let image: DocImage
    let inGallery: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? DocMediaLayout.widestPage
        if inGallery { return CGSize(width: width, height: width / DocMediaLayout.aspect(.image(image: image))) }
        return DocMediaLayout.imageBox(image, width: width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let drawn = MainActor.assumeIsolated { DocMediaLayout.drawnSize(image, in: bounds.size) }
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(drawn))
    }
}

// MARK: Shared

/// An image from a source: an asset (`asset:name`, the demo's), or a URL. It takes the
/// frame it's given (its caller keeps its shape).
private struct DocMediaPreview<Placeholder: View>: View {
    let source: String?
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        if let picture = DocMediaLayout.picture(source) {
            Image(uiImage: picture).resizable()
        } else {
            placeholder()
        }
    }
}

enum DocMediaLayout {
    /// Half the page, less the gap between two cards.
    /// Cards side by side (Craft's, measured as its window narrows): three columns across
    /// the page while each is at least 140 wide, then two while each is at least 100, then
    /// one; a card is a column wide, alone or in a run.
    static func cardColumns(in width: CGFloat) -> Int {
        if (width - gap * 2) / 3 >= 140 { return 3 }
        if (width - gap) / 2 >= 100 { return 2 }
        return 1
    }

    static func cardWidth(in width: CGFloat) -> CGFloat {
        let columns = CGFloat(cardColumns(in: width))
        return (width - gap * (columns - 1)) / columns
    }
    /// The widest the page gets (DocBlockController.pageWidth): for a view given no width.
    static let widestPage: CGFloat = 720
    /// Every card's, link or file.
    static let cardHeight = FlooDesignTokens.Component.MediaCard.cardHeight

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
    /// An image alone: large, as wide as the page; else its own width at most.
    static func imageBox(_ image: DocImage, width: CGFloat) -> CGSize {
        let shown = image.size == .large ? width : min(width, naturalSize(image.source)?.width ?? width)
        return CGSize(width: shown, height: imageHeight(image, width: width))
    }

    /// The picture's size in its box: covering it (fill) or inside it (fit), its shape kept.
    @MainActor static func drawnSize(_ image: DocImage, in box: CGSize) -> CGSize {
        guard let natural = picture(image.source)?.size, natural.width > 0, natural.height > 0, box.width > 0, box.height > 0 else {
            return box
        }
        let scales = (box.width / natural.width, box.height / natural.height)
        let scale = image.fit == .fill ? max(scales.0, scales.1) : min(scales.0, scales.1)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    /// The picture a source has here: an asset, or a URL's once it's loaded.
    @MainActor static func picture(_ source: String?) -> UIImage? {
        guard let source else { return nil }
        if let image = asset(source) { return image }
        guard let url = URL(string: source), url.scheme?.hasPrefix("http") == true else { return nil }
        return DocImageCache.shared.image(url)
    }

    @MainActor static func boxSize(_ kind: BlockKind, width: CGFloat) -> CGSize? {
        switch kind {
        case .image(let image):
            return imageBox(image, width: width)
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

    private typealias Card = FlooDesignTokens.Component.MediaCard

    /// Rough heights for the list before it measures (DocRow.estimatedHeight).
    static func estimatedHeight(_ kind: BlockKind, width: CGFloat) -> CGFloat? {
        switch kind {
        case .link(let link): link.layout.pick(Card.smallLinkHeight, Card.regularLinkHeight, cardHeight)
        case .file(let file): file.layout.pick(Card.smallFileHeight, Card.regularFileHeight, cardHeight)
        case .image(let image): imageHeight(image, width: width)
        default: nil
        }
    }
}

extension DocLayout {
    /// FlooDesign's style for it.
    var style: FlooDesignMediaStyle { pick(.small, .regular, .card) }

    /// The value for this layout.
    func pick<Value>(_ small: Value, _ regular: Value, _ card: Value) -> Value {
        switch self {
        case .small: small
        case .regular: regular
        case .card: card
        }
    }
}

// MARK: Runs

extension DocMediaLayout {
    static let gap: CGFloat = 8

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

    /// Where a run's member goes across a page `page` wide, from the run's top left, and
    /// whether it's on the line of the member before it: cards in as many columns as the
    /// page takes (cardColumns), filling it; images in lines of up to four, one height
    /// per line, as wide together as the page (no taller than 280). A row on a line of
    /// its own spans the page, less its inset.
    static func place(_ run: DocRowRun, inPage page: CGFloat) -> (frame: CGRect, sharesLine: Bool) {
        let room = page - run.inset * 2
        switch run.kind {
        case nil:
            return (CGRect(x: run.inset, y: 0, width: room, height: 0), false)
        case .cards:
            let columns = cardColumns(in: room)
            let card = cardWidth(in: room)
            let (line, column) = run.index.quotientAndRemainder(dividingBy: columns)
            return (CGRect(x: CGFloat(column) * (card + gap), y: CGFloat(line) * (cardHeight + gap), width: card, height: cardHeight), column > 0)
        case .gallery:
            let (line, column) = run.index.quotientAndRemainder(dividingBy: 4)
            var y: CGFloat = 0
            for start in stride(from: 0, through: line * 4, by: 4) {
                let ratios = run.aspects[start..<min(start + 4, run.aspects.count)]
                let height = min(280, (room - gap * CGFloat(ratios.count - 1)) / ratios.reduce(0, +)).rounded(.down)
                guard start == line * 4 else {
                    y += height + gap
                    continue
                }
                let x = ratios.prefix(column).reduce(0) { $0 + $1 * height + gap }
                return (CGRect(x: x, y: y, width: run.aspects[run.index] * height, height: height), column > 0)
            }
            return (.zero, false)
        }
    }

    /// Where each block of a run of `kinds` goes across a page `width` wide.
    static func runFrames(_ kinds: [BlockKind], width: CGFloat) -> [CGRect] {
        guard let first = kinds.first, let run = run(first) else { return [] }
        let aspects = kinds.map(aspect)
        return kinds.indices.map { place(DocRowRun(kind: run, index: $0, aspects: aspects), inPage: width).frame }
    }

    /// A member's width over its height in a run: an image's in a gallery (4:3 when it
    /// fills, or unknown); a card's are all alike.
    static func aspect(_ kind: BlockKind) -> CGFloat {
        guard case .image(let image) = kind else { return 1 }
        guard image.fit == .fit, let size = naturalSize(image.source), size.height > 0 else { return 4 / 3 }
        return size.width / size.height
    }
}

/// A link, file or image with what selecting adds: a tinted outline around it (Craft's;
/// its dot is the selection's, over its box); on the Mac a right-click offers its
/// layouts. In a gallery an image's box is its place's.
struct DocMediaCell: View {
    let id: DocBlockID
    let kind: BlockKind
    let blocks: DocBlockController
    var inGallery = false

    var body: some View {
        content
            .flooDesignMediaSelection(blocks.isSelected(id))
            .modifier(DocMediaContextMenu(kind: kind, block: id, blocks: blocks))
    }

    @ViewBuilder
    private var content: some View {
        // An image is the same view alone or in a gallery: its box goes from one to the other.
        if case .image(let image) = kind {
            DocImageView(image: image, inGallery: inGallery)
        } else {
            DocMediaView(kind: kind)
        }
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
