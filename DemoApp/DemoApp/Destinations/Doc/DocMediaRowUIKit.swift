//
//  DocMediaRowUIKit.swift
//  DemoApp
//
//  A link, file or image as a UIKit row, where the list placed it across the page (a run of
//  cards, a gallery's line, or a line of its own): a link or a file is floo-uikit's media card
//  in the block's style; an image its box at the width it's given (alone, as its fit and size
//  make it; in a gallery, its place's), its picture drawn at its fit's size, centred and cut to
//  the box, its blur until the picture is here. Chosen, floo-uikit's outline goes round it.
//  What DocMediaCell drew, in frames.
//

import DocKit
import FlooUIKit
import MessagingUI
import Observation
import UIKit

/// A link, file or image row's content: what it shows and who selects it.
@MainActor
struct DocMediaRowContent: TiledUIKitCellContent {
    /// Its row runs a reshape's animation and the rows round it move in its frames.
    var drivesRowMoves: Bool { true }

    let row: DocRow
    let block: DocBlockID
    let kind: BlockKind
    let blocks: DocBlockController

    /// The kinds it draws (a floo card or a view is the card language's, DocRowView's).
    static func draws(_ kind: BlockKind) -> Bool {
        switch kind {
        case .link, .file, .image: true
        default: false
        }
    }

    static func makeRowView() -> DocMediaRowView { DocMediaRowView() }

    func configure(_ view: DocMediaRowView, context: TiledUIKitCellContext) {
        view.show(row, block: block, kind: kind, blocks: blocks, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        DocMediaRowView.height(of: row, kind: kind, width: width)
    }

    static func prepareForReuse(_ view: DocMediaRowView) {
        view.reset()
    }
}

@MainActor
final class DocMediaRowView: DocRowUIKitView {
    private let media = DocMediaContentView()
    private var block: DocBlockID?
    private var kind: BlockKind?

    init() {
        super.init(content: media)
    }

    func show(_ row: DocRow, block: DocBlockID, kind: BlockKind, blocks: DocBlockController, context: TiledUIKitCellContext) {
        self.block = block
        self.kind = kind
        take(row, blocks: blocks, context: context)
        media.show(kind, inGallery: row.run?.kind == .gallery)
        follow(blocks, block: block, kind: kind)
        layOutShown()
    }

    override func reset() {
        super.reset()
        block = nil
        kind = nil
    }

    override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let kind, let row else { return 0 }
        return Self.contentHeight(kind, inGallery: row.run?.kind == .gallery, width: width)
    }

    /// Chosen while the block is selected; an image's picture once it's loaded.
    private func follow(_ blocks: DocBlockController, block: DocBlockID, kind: BlockKind) {
        withObservationTracking {
            media.isChosen = blocks.isSelected(block)
            if case .image(let image) = kind { media.showPicture(DocMediaLayout.picture(image.source)) }
        } onChange: { [weak self, weak blocks] in
            DispatchQueue.main.async {
                guard let self, let blocks, self.block == block, self.kind == kind else { return }
                self.follow(blocks, block: block, kind: kind)
                // A picture here now may be a size its box didn't know.
                guard let row = self.row else { return }
                Self.heights.forget(row.id)
                if self.bounds.width > 0, Self.height(of: row, kind: kind, width: self.bounds.width) != self.bounds.height {
                    self.contentHeightChanged()
                }
            }
        }
    }

    // MARK: Heights

    private static var heights = DocRowHeights<BlockKind>()

    static func height(of row: DocRow, kind: BlockKind, width: CGFloat) -> CGFloat {
        heights.height(of: row, showing: kind, width: width) { width in
            contentHeight(kind, inGallery: row.run?.kind == .gallery, width: width)
        }
    }

    static func contentHeight(_ kind: BlockKind, inGallery: Bool, width: CGFloat) -> CGFloat {
        DocMediaContentView.size(of: kind, inGallery: inGallery, width: width).height
    }
}

/// A link or a file's card, or an image's box, at the top left of the width it's given.
@MainActor
final class DocMediaContentView: UIView {
    private var card: FlooMediaCard?
    private let image = DocImageBox()
    private let outline = FlooMediaOutline()
    private var kind: BlockKind?
    private var inGallery = false

    var isChosen = false { didSet { showChosen() } }

    /// A card draws its own outline; an image has this one.
    private func showChosen() {
        card?.isChosen = isChosen
        outline.isHidden = !isChosen || card?.isHidden == false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.isHidden = true
        outline.isHidden = true
        addSubview(image)
        addSubview(outline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ kind: BlockKind, inGallery: Bool) {
        guard kind != self.kind || inGallery != self.inGallery else { return }
        self.kind = kind
        self.inGallery = inGallery
        if let (content, style) = Self.card(kind) {
            let card = self.card ?? {
                let card = FlooMediaCard(content, style: style)
                insertSubview(card, belowSubview: outline)
                self.card = card
                return card
            }()
            card.content = content
            // Its parts go to the new style in the row's layout motion.
            card.setStyle(style, animated: false)
            card.isHidden = false
            image.isHidden = true
        } else if case .image(let shown) = kind {
            image.show(shown)
            image.isHidden = false
            card?.isHidden = true
        }
        showChosen()
        setNeedsLayout()
    }

    func showPicture(_ picture: UIImage?) {
        image.showPicture(picture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let kind else { return }
        let frame = CGRect(origin: .zero, size: Self.size(of: kind, inGallery: inGallery, width: bounds.width, sizing: card))
        if let card, !card.isHidden { card.frame = frame }
        if !image.isHidden { image.frame = frame }
        outline.frame = frame
    }

    // MARK: Sizes

    /// A link or a file's card content and style; nil for an image.
    static func card(_ kind: BlockKind) -> (FlooMediaCard.Content, FlooMediaStyle)? {
        switch kind {
        case .link(let link):
            let address = link.url.removingPercentEncoding ?? link.url
            return (.link(title: link.title.isEmpty ? address : link.title, summary: link.summary.isEmpty ? nil : link.summary,
                          host: DocMediaLayout.host(link.url), preview: DocMediaLayout.picture(link.image)), link.layout.style)
        case .file(let file):
            return (.file(name: file.name, kind: DocMediaLayout.kind(of: file.name), size: file.size.map(DocMediaLayout.bytes)), file.layout.style)
        default:
            return nil
        }
    }

    private static let sizingCard = FlooMediaCard(.file(name: "", kind: "", size: nil))

    /// Its box at a width: a card's at that width (up to the widest page), a small one as wide
    /// as its text; an image's as DocMediaLayout has it.
    static func size(of kind: BlockKind, inGallery: Bool, width: CGFloat, sizing: FlooMediaCard? = nil) -> CGSize {
        if let (content, style) = card(kind) {
            let card = sizing ?? sizingCard
            if card === sizingCard {
                card.content = content
                card.setStyle(style, animated: false)
            }
            return card.sizeThatFits(CGSize(width: min(width, DocMediaLayout.widestPage), height: .greatestFiniteMagnitude))
        }
        guard case .image(let image) = kind else { return .zero }
        if inGallery { return CGSize(width: width, height: width / DocMediaLayout.aspect(.image(image: image))) }
        return DocMediaLayout.imageBox(image, width: width)
    }
}

/// An image's box: its picture drawn at its fit's size in it, centred, cut to the box's
/// corners; its blur, or the raised surface, until the picture is here.
@MainActor
final class DocImageBox: UIView {
    private let picture = UIImageView()
    private var image: DocImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = DocTokens.Component.MediaCard.cornerRadius
        layer.cornerCurve = .continuous
        picture.contentMode = .scaleToFill
        addSubview(picture)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ image: DocImage) {
        self.image = image
        accessibilityLabel = image.alt
        showPicture(DocMediaLayout.picture(image.source))
        setNeedsLayout()
    }

    func showPicture(_ loaded: UIImage?) {
        let blur = image?.blurHash.flatMap(DocBlobImages.blur)
        picture.image = loaded ?? blur
        picture.backgroundColor = picture.image == nil ? .floo(.markdownPageRaised) : nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image else { return }
        // The blur, or the surface, stands in for the picture at its size.
        picture.bounds = CGRect(origin: .zero, size: DocMediaLayout.drawnSize(image, in: bounds.size))
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
