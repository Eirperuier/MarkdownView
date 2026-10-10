//
//  DocMorph.swift
//  DemoApp
//
//  A change that reshapes blocks, without a jump, as Craft's: every block on screen
//  goes from where it was to where the change puts it (DocMorphPiece). Drawn over
//  the list, the colour of the page, while the list takes the change underneath.
//

import SwiftUI
import DocKit

@MainActor
@Observable
final class DocMorph {
    struct Item: Identifiable {
        let id: DocBlockID
        /// Where it was and is, over the list (nil: it comes, or goes).
        var from: CGRect?
        var to: CGRect?
        var fromKind: BlockKind?
        var toKind: BlockKind?
        /// Text's pictures: before, and after when its shape changed.
        var old: UIImage?
        var new: UIImage?

        init(id: DocBlockID, from: CGRect? = nil, fromKind: BlockKind? = nil, old: UIImage? = nil) {
            self.id = id
            self.from = from
            self.fromKind = fromKind
            self.old = old
        }
    }

    var items: [Item] = []
    var isDone = false
}

struct DocMorphView: View {
    let morph: DocMorph
    let blocks: DocBlockController

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            ForEach(morph.items) { item in
                DocMorphPiece(item: item, blocks: blocks, progress: morph.isDone ? 1 : 0)
            }
        }
        .ignoresSafeArea()
    }
}

/// One block at a point of the change, `progress` 0 before and 1 after, as Craft
/// draws it: the box (background, border, the selection's outline) goes from its old
/// frame to its new one. Inside, the new layout is laid out at the box's size as it
/// goes (its text at its own size; a picture follows the box), fading in; the old
/// layout stays as it was, at its own size, fading out. Text is its pictures at their
/// own size: the old one moving, the new one fading in over it.
private struct DocMorphPiece: View, @preconcurrency Animatable {
    let item: DocMorph.Item
    let blocks: DocBlockController
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let box = mix(from, to)
        ZStack(alignment: .topLeading) {
            if let kind = item.toKind ?? item.fromKind, DocMediaView.draws(kind) {
                media(kind, box: box)
            } else {
                text
            }
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
        .position(x: box.midX, y: box.midY)
        .opacity(item.from == nil ? progress : item.to == nil ? 1 - progress : 1)
    }

    @ViewBuilder
    private func media(_ kind: BlockKind, box: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let isImage = if case .image = kind { true } else { false }
        let changes = item.fromKind != nil && item.fromKind != kind
        if isImage {
            // An image is its picture, filling the box as it goes.
            DocMediaCell(id: item.id, kind: kind, blocks: blocks, size: box.size, isLayer: true)
        } else {
            // Sized to the box: in the stack the old layout, at its own size, is wider or
            // taller, and an unsized shape would take the stack's size.
            shape.fill(Color(.systemBackground))
                .frame(width: box.width, height: box.height)
            if changes, let old = item.fromKind, let from = item.from {
                // At its own size, inside the box: what the box no longer covers is cut off.
                DocMediaCell(id: item.id, kind: old, blocks: blocks, size: from.size, isLayer: true)
                    .frame(width: box.width, height: box.height, alignment: .topLeading)
                    .clipShape(shape)
                    .opacity(max(0, 1 - progress / 0.7))
            }
            DocMediaCell(id: item.id, kind: kind, blocks: blocks, size: box.size, isLayer: true)
                .clipShape(shape)
                .opacity(changes ? min(1, progress / 0.4) : 1)
            shape.strokeBorder(DocMediaLayout.border, lineWidth: 1)
                .frame(width: box.width, height: box.height)
        }
        if blocks.selected.contains(item.id) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                .padding(-3)
                .frame(width: box.width, height: box.height)
        }
    }

    @ViewBuilder
    private var text: some View {
        if let old = item.old {
            Image(uiImage: old).fixedSize()
                .opacity(item.new == nil ? 1 : max(0, 1 - progress / 0.7))
        }
        if let new = item.new {
            Image(uiImage: new).fixedSize()
                .opacity(min(1, progress / 0.4))
        }
    }

    private var from: CGRect { item.from ?? item.to ?? .zero }
    private var to: CGRect { item.to ?? item.from ?? .zero }

    private func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * progress }
        return CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
    }
}

extension DocBlockController {
    /// Room around a block for what's drawn about it (a selection's outline).
    static let morphOutset = CGSize(width: 6, height: 4)
}
