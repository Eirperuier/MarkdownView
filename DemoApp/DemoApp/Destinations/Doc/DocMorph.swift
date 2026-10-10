//
//  DocMorph.swift
//  DemoApp
//
//  A change that reshapes blocks, without a jump, as Craft's: every block on screen
//  goes from where it was to where the change puts it. Each frame of the animation
//  lays its content out again at the size it has reached, so a link or file reflows
//  into its new layout as its box grows or shrinks; its old layout stays under it while
//  the new one fades in. Text is its picture, moving, its new picture fading in over
//  it when its shape changes. Drawn over the list, the colour of the page, while the
//  list takes the change underneath.
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

/// One block at a point of the change: `progress` 0 is before, 1 after.
private struct DocMorphPiece: View, @preconcurrency Animatable {
    let item: DocMorph.Item
    let blocks: DocBlockController
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let frame = self.frame
        ZStack(alignment: .topLeading) {
            if let kind = item.fromKind, DocMediaView.draws(kind), item.toKind != kind {
                DocMediaCell(id: item.id, kind: kind, blocks: blocks, size: frame.size, fills: true)
            }
            if let kind = item.toKind ?? item.fromKind, DocMediaView.draws(kind) {
                // The new layout fades in over the old one in the first third.
                let changed = item.fromKind != nil && item.toKind != nil && item.fromKind != item.toKind
                DocMediaCell(id: item.id, kind: kind, blocks: blocks, size: frame.size, fills: true)
                    .opacity(changed ? min(1, progress * 3) : 1)
            } else {
                if let old = item.old { Image(uiImage: old).resizable() }
                if let new = item.new { Image(uiImage: new).resizable().opacity(min(1, progress * 3)) }
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .position(x: frame.midX, y: frame.midY)
        .opacity(item.from == nil ? progress : item.to == nil ? 1 - progress : 1)
    }

    /// Between where it was and where it goes (where it is, if it only comes or goes).
    private var frame: CGRect {
        guard let from = item.from ?? item.to, let to = item.to ?? item.from else { return .zero }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
}

extension DocBlockController {
    /// Room around a block for what's drawn about it (a selection's outline).
    static let morphOutset = CGSize(width: 6, height: 4)
}
