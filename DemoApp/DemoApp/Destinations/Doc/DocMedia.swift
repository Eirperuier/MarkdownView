//
//  DocMedia.swift
//  DemoApp
//
//  Links, files, images and cards on the page, as Craft draws them. Links and files are
//  FlooDesign's cards in the block's layout: small (a pill as wide as its name), regular
//  (a row: thumbnail, title, details) and card (a column of the page: the preview on
//  top, the text below). Images fit or fill, at their own size or the page's width.
//  Cards (floo's) are drawn at their size's design and scaled to the page. Views (floo's
//  too) aren't cards: the page's width, as tall as they draw, nothing round them.
//

import FlooUIKit
import SwiftUI
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import DocKit
import FlooDesign
import CardModel
import CardUI

/// A link, file or image block's view.
struct DocMediaView: View {
    let kind: BlockKind

    var body: some View {
        switch kind {
        case .link(let link): DocLinkView(link: link)
        case .file(let file): DocFileView(file: file)
        case .image(let image): DocImageView(image: image)
        case .card(let card): DocCardView(card: card)
        case .view(let view): DocViewView(view: view)
        default: EmptyView()
        }
    }

    /// The kinds this view draws.
    static func draws(_ kind: BlockKind) -> Bool {
        switch kind {
        case .link, .file, .image, .card, .view: true
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
        DocMediaCardView(content: .link(title: link.title.isEmpty ? address : link.title,
                                        summary: link.summary.isEmpty ? nil : link.summary,
                                        host: DocMediaLayout.host(link.url), preview: DocMediaLayout.picture(link.image)),
                         style: link.layout.style)
    }

    /// The address as it reads (not percent-encoded).
    private var address: String { link.url.removingPercentEncoding ?? link.url }
}

/// A file.
struct DocFileView: View {
    let file: DocFile

    var body: some View {
        DocMediaCardView(content: .file(name: file.name, kind: DocMediaLayout.kind(of: file.name),
                                        size: file.size.map(DocMediaLayout.bytes)),
                         style: file.layout.style)
    }
}

/// floo-uikit's card, which is UIKit's: as wide as it's given, up to the widest page.
private struct DocMediaCardView: UIViewRepresentable {
    let content: FlooMediaCard.Content
    let style: FlooMediaStyle

    func makeUIView(context: Context) -> FlooMediaCard { FlooMediaCard(content, style: style) }

    func updateUIView(_ card: FlooMediaCard, context: Context) {
        card.content = content
        card.setStyle(style, animated: context.transaction.animation != nil)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView card: FlooMediaCard, context: Context) -> CGSize? {
        card.sizeThatFits(CGSize(width: min(proposal.width ?? DocMediaLayout.widestPage, DocMediaLayout.widestPage),
                                 height: .greatestFiniteMagnitude))
    }
}

// MARK: Cards

/// A card, drawn at its size's design on the page's grid (CardFrame, a 360-point column,
/// DocMediaLayout.cardGrid) and scaled whole to the width it's given: its parts don't
/// re-flow as the page narrows or widens. Its box is a link's or an image's (square
/// inside, rounded and edged once scaled, so the corners are theirs at any scale).
struct DocCardView: View {
    let card: DocCard

    var body: some View {
        let size = DocMediaLayout.size(of: card)
        CardFrame(layout: CardLayout(size: size), grid: DocMediaLayout.cardGrid, cornerRadius: 0) {
            CardView(tree: DocMediaLayout.session(for: card).tree)
        }
        .docScaled(designWidth: CGFloat(size.width(grid: DocMediaLayout.cardGrid)))
        .flooMediaBox()
    }
}

/// A view: the page's width, as tall as it draws there (ViewFrame), its parts laid out
/// for that width (not scaled), on the page with no box. Its controls are FlooDesign's
/// where it doesn't style them itself, and where it names a style FlooDesign has: a
/// segmented picker FlooDesign's, a prominent button its primary one.
struct DocViewView: View {
    let view: DocView

    var body: some View {
        ViewFrame { CardView(tree: DocMediaLayout.session(for: view).tree) }
            .environment(\.cardSegmentedPicker, Self.segments)
            .environment(\.cardButtonStyles, ["borderedProminent": CardHostButtonStyle(FlooSwiftUIButtonStyle(.primary))])
            .buttonStyle(.floo(.tertiary))
            .textFieldStyle(FlooTextFieldStyle())
            .tint(DocTokens.ColorRole.Accent.primary)
    }

    private static let segments = CardSegmentedPicker { selection, segments in
        let index = Binding(get: { segments.firstIndex { $0.tag == selection.wrappedValue } ?? -1 },
                            set: { selection.wrappedValue = segments[$0].tag })
        return AnyView(FlooDesignSegmentedPicker(selection: index, options: Array(segments.indices)) { segments[$0].label })
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
            DocMediaPreview(source: image.source) {
                // Its blur while the picture isn't here (kept with the block, DocImage.blurHash).
                if let blur = image.blurHash.flatMap(DocBlobImages.blur) {
                    Image(uiImage: blur).resizable()
                } else {
                    DocTokens.Component.MediaCard.panel
                }
            }
        }
        .clipShape(.rect(cornerRadius: DocTokens.Component.MediaCard.cornerRadius, style: .continuous))
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

/// An image from a source: an asset (`asset:name`, the demo's), kept content (a blob
/// ref, DocBlobs), or a URL. It takes the
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
    static let cardHeight = DocTokens.Component.MediaCard.cardHeight

    /// Fill: a 4:3 box the image covers; fit: the image's own shape.
    static func imageHeight(_ image: DocImage, width: CGFloat) -> CGFloat {
        let natural = naturalSize(image)
        let shown = image.size == .large ? width : min(width, natural?.width ?? width)
        guard image.fit == .fit, let natural, natural.width > 0 else { return (shown * 3 / 4).rounded() }
        return min(640, (shown * natural.height / natural.width).rounded())
    }

    /// Its own size: the block's, else what its source tells here (an asset's, a kept
    /// image's header).
    static func naturalSize(_ image: DocImage) -> CGSize? {
        if let width = image.width, let height = image.height, width > 0, height > 0 { return CGSize(width: width, height: height) }
        return naturalSize(image.source)
    }

    static func naturalSize(_ source: String) -> CGSize? {
        if let ref = DocBlobRef(source: source) { return DocBlobImages.naturalSize(ref) }
        return asset(source).map { $0.size }
    }

    static func asset(_ source: String) -> UIImage? {
        source.hasPrefix("asset:") ? UIImage(named: String(source.dropFirst("asset:".count))) : nil
    }

    /// The box a link, file or image alone in its row takes, at the page's `width`:
    /// a card's or a small pill's own size, a regular row's the page's, an image's as
    /// it shows.
    /// An image alone: large, as wide as the page; else its own width at most.
    static func imageBox(_ image: DocImage, width: CGFloat) -> CGSize {
        let shown = image.size == .large ? width : min(width, naturalSize(image)?.width ?? width)
        return CGSize(width: shown, height: imageHeight(image, width: width))
    }

    /// The picture's size in its box: covering it (fill) or inside it (fit), its shape kept.
    @MainActor static func drawnSize(_ image: DocImage, in box: CGSize) -> CGSize {
        guard let natural = picture(image.source)?.size ?? naturalSize(image), natural.width > 0, natural.height > 0, box.width > 0, box.height > 0 else {
            return box
        }
        let scales = (box.width / natural.width, box.height / natural.height)
        let scale = image.fit == .fill ? max(scales.0, scales.1) : min(scales.0, scales.1)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    /// The picture a source has here: an asset, or kept content's or a URL's once it's
    /// loaded.
    @MainActor static func picture(_ source: String?) -> UIImage? {
        guard let source else { return nil }
        if let image = asset(source) { return image }
        if let ref = DocBlobRef(source: source) { return DocImageCache.shared.image(ref) }
        guard let url = URL(string: source), url.scheme?.hasPrefix("http") == true else { return nil }
        return DocImageCache.shared.image(url)
    }

    @MainActor static func boxSize(_ kind: BlockKind, width: CGFloat) -> CGSize? {
        switch kind {
        case .image(let image):
            return imageBox(image, width: width)
        case .card(let card):
            return CGSize(width: width, height: width * cardAspect(card))
        case .link, .file:
            return DocMediaContentView.size(of: kind, inGallery: false, width: width)
        case .view:
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

    private typealias Card = DocTokens.Component.MediaCard

    /// Rough heights for the list before it measures (DocRow.estimatedHeight).
    static func estimatedHeight(_ kind: BlockKind, width: CGFloat) -> CGFloat? {
        switch kind {
        case .link(let link): link.layout.pick(Card.smallLinkHeight, Card.regularLinkHeight, cardHeight)
        case .file(let file): file.layout.pick(Card.smallFileHeight, Card.regularFileHeight, cardHeight)
        case .image(let image): imageHeight(image, width: width)
        case .card(let card): width * cardAspect(card)
        // As tall as it draws, which isn't known until it is.
        case .view: width * 0.75
        default: nil
        }
    }
}

// MARK: Cards

extension DocMediaLayout {
    /// The page's cards are pieces of one grid, the gap between media apart across and
    /// down (CardGrid.tiled).
    static let cardGrid = CardGrid.tiled(gap: Double(gap))

    /// The size a card shows at: the one it was drawn for, but a collection shows as a
    /// detail (a page has no extra large); one this version doesn't know as a summary.
    static func size(of card: DocCard) -> CardSize {
        let size = CardSize(token: card.size) ?? .summary
        return size == .collection ? .detail : size
    }

    /// A card block's size; nil for any other block.
    static func cardSize(_ kind: BlockKind) -> CardSize? {
        if case .card(let card) = kind { size(of: card) } else { nil }
    }

    /// Columns of cards across a page `width` wide: two (two summaries side by side)
    /// while a card is drawn at least three quarters of its design's size, else one.
    static func flooColumns(in width: CGFloat) -> Int {
        width / columnsWidth(2) >= 0.75 ? 2 : 1
    }

    /// What a card is drawn at, over its design, on a page `width` wide.
    static func flooScale(in width: CGFloat) -> CGFloat {
        width / columnsWidth(flooColumns(in: width))
    }

    /// The gutter above a card `width` wide (DocCardGap); none above anything else.
    static func cardGap(_ kind: BlockKind, width: CGFloat) -> CGFloat {
        cardSize(kind).map { CGFloat(CardSize.gutter(grid: cardGrid)) * width / CGFloat($0.width(grid: cardGrid)) } ?? 0
    }

    /// The gutter above each card (DocCardGap), on a page `width` wide.
    static func flooGap(in width: CGFloat) -> CGFloat {
        CGFloat(CardSize.gutter(grid: cardGrid)) * flooScale(in: width)
    }

    /// The design's width of `count` columns and the gutters between them.
    private static func columnsWidth(_ count: Int) -> CGFloat {
        CGFloat(CardSize.summary.width(grid: cardGrid)) * CGFloat(count) + CGFloat(CardSize.gutter(grid: cardGrid)) * CGFloat(count - 1)
    }

    /// A card's height over its width, as designed on the page's grid.
    static func cardAspect(_ card: DocCard) -> CGFloat {
        let size = size(of: card)
        return CGFloat(size.height(grid: cardGrid) / size.width(grid: cardGrid))
    }

    /// The cards' standard catalog (their library compiled: ~240 ms, the first time),
    /// built off the main thread at launch, so a document's first card doesn't wait for it.
    nonisolated static func prewarm() {
        Task.detached(priority: .userInitiated) { _ = Catalog.standard }
    }

    /// A card's session: its source compiled with its data, once per card.
    @MainActor static func session(for card: DocCard) -> CardSession {
        session(SessionKey(source: card.source ?? "", data: card.data))
    }

    /// A view's session, as a card's.
    @MainActor static func session(for view: DocView) -> CardSession {
        session(SessionKey(source: view.source, data: view.data))
    }

    @MainActor private static func session(_ key: SessionKey) -> CardSession {
        if let session = sessions[key] { return session }
        let data = key.data.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(CardValue.self, from: $0) }
        let session = CardSession(data: data ?? .object([:]))
        session.append(key.source)
        session.finish()
        sessions[key] = session
        return session
    }

    private struct SessionKey: Hashable {
        let source: String
        let data: JSONValue?
    }

    @MainActor private static var sessions: [SessionKey: CardSession] = [:]
}

extension DocLayout {
    /// FlooDesign's style for it.
    var style: FlooMediaStyle { pick(.small, .regular, .card) }

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
    /// floo's cards go in columns (`floo`, cardColumns).
    enum Run { case cards, gallery, floo }

    static func run(_ kind: BlockKind) -> Run? {
        switch kind {
        case .link(let link) where link.layout == .card: .cards
        case .file(let file) where file.layout == .card: .cards
        case .image(let image) where image.size == .auto: .gallery
        case .card: .floo
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
        case .floo:
            // Slots of a glance's width with the gutter between, two to a column: a glance
            // takes one, every other size a column. A card that doesn't fit on the line
            // starts the next, the gutter below; a line is as tall as its tallest card.
            let scale = flooScale(in: room)
            let slot = CGFloat(CardSize.glance.width(grid: cardGrid) + CardSize.gutter(grid: cardGrid)) * scale
            let slots = flooColumns(in: room) * 2
            var (used, y, lineHeight) = (0, CGFloat(0), CGFloat(0))
            for (index, size) in run.cards.enumerated() {
                let span = size == .glance ? 1 : 2
                if used > 0, used + span > slots {
                    (used, y, lineHeight) = (0, y + lineHeight + CGFloat(CardSize.gutter(grid: cardGrid)) * scale, 0)
                }
                let frame = CGRect(x: CGFloat(used) * slot, y: y,
                                   width: CGFloat(size.width(grid: cardGrid)) * scale, height: CGFloat(size.height(grid: cardGrid)) * scale)
                if index == run.index { return (frame, used > 0) }
                used += span
                lineHeight = max(lineHeight, frame.height)
            }
            return (.zero, false)
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
        let cards = kinds.compactMap(cardSize)
        return kinds.indices.map { place(DocRowRun(kind: run, index: $0, aspects: aspects, cards: cards), inPage: width).frame }
    }

    /// A member's width over its height in a run: an image's in a gallery (4:3 when it
    /// fills, or unknown); a card's are all alike.
    static func aspect(_ kind: BlockKind) -> CGFloat {
        guard case .image(let image) = kind else { return 1 }
        guard image.fit == .fit, let size = naturalSize(image), size.height > 0 else { return 4 / 3 }
        return size.width / size.height
    }
}

/// A link, file or image with what selecting adds: a tinted outline around it (Craft's;
/// its dot is the selection's, over its box). In a gallery an image's box is its place's.
struct DocMediaCell: View {
    let id: DocBlockID
    let kind: BlockKind
    let blocks: DocBlockController
    var inGallery = false

    var body: some View {
        let cell = content
            // What a card asks of the app (its tools, its pictures).
            .environment(\.cardHost, blocks.cardHost)
            .flooMediaChosen(blocks.isSelected(id))
        if case .card(let card) = kind {
            DocCardGap(designWidth: CGFloat(DocMediaLayout.size(of: card).width(grid: DocMediaLayout.cardGrid))) { cell }
        } else {
            cell
        }
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

/// A card with the grid's gap above it at its own scale, as across: cards are as far
/// apart down as side by side.
private struct DocCardGap: Layout {
    let designWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let card = subviews.first else { return .zero }
        let size = card.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height + gap(size.width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let gap = gap(bounds.width)
        card.place(at: CGPoint(x: bounds.minX, y: bounds.minY + gap), anchor: .topLeading,
                   proposal: ProposedViewSize(width: bounds.width, height: bounds.height - gap))
    }

    private func gap(_ width: CGFloat) -> CGFloat {
        CGFloat(CardSize.gutter(grid: DocMediaLayout.cardGrid)) * width / designWidth
    }
}

// MARK: Kept images

/// Images kept by the store (DocBlobs), read with ImageIO: their size from their header
/// (no decoding, so a page lays out at once), their picture decoded off the main thread
/// at most a page's size (DocImageCache).
enum DocBlobImages {
    /// Decoded no larger than this, in pixels across: a page at its widest, at 3×.
    static let largest = 2400

    /// Whether ImageIO reads the file as an image.
    static func reads(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
    }

    /// Its size in points (`size(of:)`); nil while it isn't here.
    static func naturalSize(_ ref: DocBlobRef) -> CGSize? {
        if let size = sizes.withLock({ $0[ref] }) { return size }
        guard let file = DocBlobs.store.local(ref), let size = size(of: file) else { return nil }
        sizes.withLock { $0[ref] = size }
        return size
    }

    /// What a block keeps of an image (DocImage's width, height and blurHash): its size,
    /// and its blur from a picture a few dozen pixels across.
    static func facts(_ file: URL) -> (size: CGSize, blurHash: String?)? {
        guard let size = size(of: file) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
        ]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return (size, nil) }
        let width = small.width, height = small.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (size, nil) }
        return (size, BlurHash.encode(rgba: rgba, width: width, height: height, components: BlurHash.components(width: width, height: height)))
    }

    /// A blur drawn small (it's shown stretched; it has no detail to lose), kept by its hash.
    static func blur(_ hash: String) -> UIImage? {
        if let image = blurs.withLock({ $0[hash] }) { return image }
        let width = 32, height = 32
        guard let rgba = BlurHash.decode(hash, width: width, height: height),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let blur = UIImage(cgImage: image)
        blurs.withLock { $0[hash] = blur }
        return blur
    }

    private static let blurs = Mutex<[String: UIImage]>([:])

    /// Its size in points: its pixels at its resolution (a 144 dpi screenshot is half
    /// its pixels), turned as it's shown.
    static func size(of file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = 72 / max(72, dpi)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? CGSize(width: height * scale, height: width * scale) : CGSize(width: width * scale, height: height * scale)
    }

    private static let sizes = Mutex<[DocBlobRef: CGSize]>([:])

    /// The picture, turned as it's shown, at most `largest` pixels across.
    static func decode(_ file: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    /// Its type, as ImageIO reads it (for a name to open it by).
    static func type(_ file: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source) else { return nil }
        return UTType(type as String)
    }
}

extension View {
    /// The view laid out `designWidth` wide and scaled whole to the width it's given.
    fileprivate func docScaled(designWidth: CGFloat) -> some View {
        DocScaledLayout(designWidth: designWidth) { self }
            .visualEffect { content, proxy in
                content.scaleEffect(proxy.size.width / designWidth, anchor: .topLeading)
            }
    }
}

/// Lays its one subview out at the design width, from its top left, and takes the width it's
/// given and that height at the given width's scale.
private struct DocScaledLayout: Layout {
    let designWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width ?? designWidth
        let height = content.sizeThatFits(ProposedViewSize(width: designWidth, height: nil)).height
        return CGSize(width: width, height: height * width / designWidth)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: designWidth, height: nil))
    }
}
