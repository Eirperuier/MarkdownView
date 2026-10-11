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

    var body: some View {
        switch kind {
        case .link(let link): DocLinkView(link: link)
        case .file(let file): DocFileView(file: file)
        case .image(let image): DocImageView(image: image, size: DocMediaLayout.imageBox(image, width: DocMediaLayout.pageWidth))
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
/// Its parts are the same views in every layout, placed by the layout (DocLinkLayout): a
/// new layout is each part going from its place to the new one, its text from one size
/// to the other (SwiftUI's own animations, in step with the rows the list moves).
struct DocLinkView: View {
    let link: DocLink

    var body: some View {
        let layout = link.layout
        DocLinkLayout(layout: layout, hasSummary: !link.summary.isEmpty) {
            // Craft's: the thumbnail at the left edge, as tall as the row; a card's on top.
            // As big as its place, whatever the image's shape (a filling image overflows it).
            Color.clear
                .overlay {
                    DocMediaPreview(source: link.image) {
                        DocLinkIcon(link: link, size: 36)
                            .scaleEffect(layout.pick(20, 28, 36) as CGFloat / 36)
                    }
                }
                .clipped()
            Text(title)
                .font(.system(size: layout.pick(15, 17, 15), weight: layout == .card ? .medium : .regular))
                .lineLimit(layout == .card ? 2 : 1)
                .truncationMode(layout == .small ? .middle : .tail)
                .contentTransition(.interpolate)
            Text(link.summary.isEmpty ? address : link.summary)
                .font(.system(size: layout.pick(15, 15, 13)))
                .foregroundStyle(.secondary)
                .lineLimit(layout == .card ? 2 : 1)
                .contentTransition(.interpolate)
                .opacity(layout == .regular || layout == .card && !link.summary.isEmpty ? 1 : 0)
            DocLinkFooter(link: link)
                .opacity(layout == .small ? 0 : 1)
        }
        .docMediaBox()
    }

    private var title: String { link.title.isEmpty ? address : link.title }
    /// The address as it reads (not percent-encoded).
    private var address: String { link.url.removingPercentEncoding ?? link.url }
}

/// Where a link's parts (preview, title, summary, footer) go in each layout: small, a
/// pill (the thumbnail, the title beside it); regular, a row (thumbnail, title and
/// summary, the footer under them); card, half the page (the preview on top, the text,
/// the footer at the bottom).
private struct DocLinkLayout: Layout {
    let layout: DocLayout
    let hasSummary: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? DocMediaLayout.pageWidth, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: proposal.width ?? bounds.width, subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let (title, summary) = (subviews[1], subviews[2])
        switch layout {
        case .small:
            let trailing: CGFloat = 12
            let text = title.sizeThatFits(ProposedViewSize(width: max(0, width - 60 - trailing), height: nil))
            let size = CGSize(width: min(width, 60 + text.width + trailing), height: 36)
            let titleFrame = CGRect(x: 60, y: (36 - text.height) / 2, width: text.width, height: text.height)
            return (size, [CGRect(x: 0, y: 0, width: 50, height: 36), titleFrame, titleFrame,
                           CGRect(x: 0, y: 36, width: size.width, height: 26)])
        case .regular:
            let room = ProposedViewSize(width: max(0, width - 94 - 12), height: nil)
            let (a, b) = (title.sizeThatFits(room), summary.sizeThatFits(room))
            let top = (62 - a.height - 2 - b.height) / 2
            return (CGSize(width: width, height: 88), [
                CGRect(x: 0, y: 0, width: 82, height: 62),
                CGRect(x: 94, y: top, width: a.width, height: a.height),
                CGRect(x: 94, y: top + a.height + 2, width: b.width, height: b.height),
                CGRect(x: 0, y: 62, width: width, height: 26),
            ])
        case .card:
            let card = DocMediaLayout.cardWidth
            let room = ProposedViewSize(width: card - 20, height: nil)
            let (a, b) = (title.sizeThatFits(room), summary.sizeThatFits(room))
            return (CGSize(width: card, height: 222), [
                CGRect(x: 0, y: 0, width: card, height: 104),
                CGRect(x: 10, y: 112, width: a.width, height: a.height),
                CGRect(x: 10, y: 112 + a.height + 4, width: b.width, height: hasSummary ? b.height : 0),
                CGRect(x: 0, y: 196, width: card, height: 26),
            ])
        }
    }
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

/// A file, its parts placed by the layout (DocFileLayout) as a link's are.
struct DocFileView: View {
    let file: DocFile

    var body: some View {
        let layout = file.layout
        let icon: CGFloat = layout.pick(26, 52, 72)
        DocFileLayout(layout: layout, hasSize: file.size != nil) {
            // A card's panel behind the icon.
            Color(.secondarySystemBackground)
                .opacity(layout == .card ? 1 : 0)
            // Drawn at a card's size and scaled, so it goes from one size to the other.
            DocFileIcon(name: file.name, height: 72)
                .scaleEffect(icon / 72, anchor: .topLeading)
                .frame(width: icon * 0.78, height: icon, alignment: .topLeading)
            Text(file.name)
                .font(.system(size: layout.pick(15, 17, 15), weight: layout == .card ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.interpolate)
            Text(DocMediaLayout.kind(of: file.name))
                .font(.system(size: layout.pick(11, 15, 13)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.interpolate)
            Text(file.size.map(DocMediaLayout.bytes) ?? "")
                .font(.system(size: layout.pick(15, 15, 13)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.interpolate)
                .opacity(layout == .small ? 0 : 1)
        }
        .docMediaBox()
    }
}

/// Where a file's parts (a card's panel, the icon, the name, its kind and size) go in
/// each layout: small, a pill (the icon, the name over its kind); regular, a row (the
/// icon, then name, kind and size); card, half the page (the icon on the panel, the
/// text centred under it).
private struct DocFileLayout: Layout {
    let layout: DocLayout
    let hasSize: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? DocMediaLayout.pageWidth, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: proposal.width ?? bounds.width, subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let (name, kind, size) = (subviews[2], subviews[3], subviews[4])
        switch layout {
        case .small:
            let icon = CGSize(width: 26 * 0.78, height: 26)
            let trailing: CGFloat = 10
            let room = ProposedViewSize(width: max(0, width - 18 - icon.width - trailing), height: nil)
            let (a, b) = (name.sizeThatFits(room), kind.sizeThatFits(room))
            let top = (42 - a.height - b.height) / 2
            let iconFrame = CGRect(x: 10, y: 8, width: icon.width, height: icon.height)
            let kindFrame = CGRect(x: 18 + icon.width, y: top + a.height, width: b.width, height: b.height)
            return (CGSize(width: min(width, 18 + icon.width + max(a.width, b.width) + trailing), height: 42), [
                iconFrame, iconFrame,
                CGRect(x: 18 + icon.width, y: top, width: a.width, height: a.height),
                kindFrame, kindFrame,
            ])
        case .regular:
            let icon = CGSize(width: 52 * 0.78, height: 52)
            let room = ProposedViewSize(width: max(0, width - 80 - 14), height: nil)
            let (a, b, c) = (name.sizeThatFits(room), kind.sizeThatFits(room), size.sizeThatFits(room))
            let text = a.height + 2 + b.height + (hasSize ? 1 + c.height : 0)
            let height = max(52, text) + 20
            let top = (height - text) / 2
            let iconFrame = CGRect(x: 14 + (52 - icon.width) / 2, y: (height - 52) / 2, width: icon.width, height: icon.height)
            return (CGSize(width: width, height: height), [
                iconFrame, iconFrame,
                CGRect(x: 80, y: top, width: a.width, height: a.height),
                CGRect(x: 80, y: top + a.height + 2, width: b.width, height: b.height),
                CGRect(x: 80, y: top + a.height + 2 + b.height + 1, width: c.width, height: hasSize ? c.height : 0),
            ])
        case .card:
            let card = DocMediaLayout.cardWidth
            let icon = CGSize(width: 72 * 0.78, height: 72)
            let room = ProposedViewSize(width: card - 20, height: nil)
            let (a, b, c) = (name.sizeThatFits(room), kind.sizeThatFits(room), size.sizeThatFits(room))
            func centred(_ size: CGSize, _ y: CGFloat) -> CGRect {
                CGRect(x: (card - size.width) / 2, y: y, width: size.width, height: size.height)
            }
            return (CGSize(width: card, height: 182), [
                CGRect(x: 0, y: 0, width: card, height: 104),
                CGRect(x: (card - icon.width) / 2, y: 16, width: icon.width, height: icon.height),
                centred(a, 114),
                centred(b, 114 + a.height + 2),
                centred(hasSize ? c : CGSize(width: c.width, height: 0), 114 + a.height + 2 + b.height + 2),
            ])
        }
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

/// An image in its box (`size`: alone, as its fit and size make it on the page; in a
/// gallery, its place there). The picture is drawn at the size its fit gives it in the
/// box, covering it or inside it, centred and cut to the box: a new fit, size or place is
/// the box and the picture each going from one size to the other.
struct DocImageView: View {
    let image: DocImage
    let size: CGSize

    var body: some View {
        let drawn = DocMediaLayout.drawnSize(image, in: size)
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay {
                DocMediaPreview(source: image.source, contentMode: nil) { Color(.secondarySystemBackground) }
                    .frame(width: drawn.width, height: drawn.height)
            }
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(image.alt)
    }
}

// MARK: Shared

/// A preview image from a source: an asset (`asset:name`, the demo's), or a URL. With no
/// content mode it takes the frame it's given (its caller keeps its shape).
private struct DocMediaPreview<Placeholder: View>: View {
    let source: String?
    var contentMode: ContentMode? = .fill
    @ViewBuilder let placeholder: () -> Placeholder

    var body: some View {
        if let picture = DocMediaLayout.picture(source) {
            if let contentMode {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(uiImage: picture)
                    .resizable()
            }
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

extension DocLayout {
    /// The value for this layout.
    func pick<Value>(_ small: Value, _ regular: Value, _ card: Value) -> Value {
        switch self {
        case .small: small
        case .regular: regular
        case .card: card
        }
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

/// A link, file or image with what selecting adds: a tinted outline around it (Craft's;
/// its dot is the selection's, over its box); on the Mac a right-click offers its
/// layouts. `size` sets an image's box (its place in a gallery, or alone, its own on the
/// page).
struct DocMediaCell: View {
    let id: DocBlockID
    let kind: BlockKind
    let blocks: DocBlockController
    var size: CGSize?

    var body: some View {
        content
            .overlay {
                if blocks.isSelected(id) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .modifier(DocMediaContextMenu(kind: kind, block: id, blocks: blocks))
    }

    @ViewBuilder
    private var content: some View {
        // An image is the same view alone or in a gallery: its box goes from one to the other.
        if case .image(let image) = kind {
            DocImageView(image: image, size: size ?? DocMediaLayout.imageBox(image, width: DocMediaLayout.pageWidth))
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
