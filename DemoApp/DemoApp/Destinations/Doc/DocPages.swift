//
//  DocPages.swift
//  DemoApp
//
//  Pages (Craft's): a page block opens a document of its own, and the window goes into
//  it; the bar's back arrow and path go back out. Each page is its own DocKit document
//  with its own undo history (a page opened again is as it was left). A page's title is
//  its first heading, edited there; the block in the page above keeps a copy, brought up
//  to date (one undo step there) when the page is left.
//

import SwiftUI
import DocKit
import FlooDesign

enum DocPageMetrics {
    static let rowHeight: CGFloat = 40
    static let icon: CGFloat = 26
    static let gap = FlooDesignTokens.Space.sm
}

/// One open page: its document, its editor, and the block in the page above that opened it.
@MainActor
final class DocOpenPage {
    let demo: DocDemo
    let editor: DocEditor
    let parent: (page: DocOpenPage, block: DocBlockID)?

    var id: DocID { demo.doc.id }

    init(demo: DocDemo, parent: (page: DocOpenPage, block: DocBlockID)? = nil) {
        self.demo = demo
        self.editor = DocEditor(demo: demo)
        self.parent = parent
    }

    /// Its title: the first heading's words; the root's, or "Untitled".
    var title: String {
        let heading = demo.doc.blocks.first { if case .heading = $0.kind { true } else { false } }?.text.string ?? ""
        return heading.isEmpty ? String(localized: "Untitled") : heading
    }
}

/// The pages open in the window: the way in from the first one to the one showing.
@MainActor
@Observable
final class DocPages {
    private(set) var path: [DocOpenPage]
    /// Pages opened before, kept as they were left.
    @ObservationIgnored private var opened: [DocID: DocOpenPage] = [:]
    /// The window's launch options run once, on its first page.
    @ObservationIgnored var ranLaunchOptions = false

    init(root: DocDemo) {
        let page = DocOpenPage(demo: root)
        path = [page]
        opened[page.id] = page
    }

    var current: DocOpenPage { path[path.count - 1] }
    var root: DocOpenPage { path[0] }

    /// Goes into the page a block of the current page opens: as it was left, or new, its
    /// title as its first heading and an empty line under it.
    func open(_ block: DocBlockID) {
        let from = current
        guard case .page(let page)? = from.demo.doc.block(block)?.kind else { return }
        let opening: DocOpenPage
        if let known = opened[page.doc] {
            opening = known
        } else {
            let doc = Doc(id: page.doc, blocks: [
                DocBlock(id: .generate(), kind: .heading(level: 1), text: DocText(string: page.title)),
                DocBlock(id: .generate(), kind: .paragraph),
            ])
            opening = DocOpenPage(demo: DocDemo(doc: doc), parent: (from, block))
            opened[page.doc] = opening
        }
        from.editor.blocks.clear()
        path.append(opening)
    }

    /// Back out to the page at `index` of the path (the one above, by default); each page
    /// left brings its block's title up to date.
    func back(to index: Int? = nil) {
        let target = index ?? path.count - 2
        guard target >= 0, target < path.count - 1 else { return }
        for page in path[(target + 1)...].reversed() {
            if let parent = page.parent {
                let heading = page.demo.doc.blocks.first { if case .heading = $0.kind { true } else { false } }?.text.string ?? ""
                parent.page.demo.setPageTitle(heading, of: parent.block)
            }
        }
        path.removeSubrange((target + 1)...)
    }
}

/// A page block: the page's icon and its title; a click (a tap) goes into it.
struct DocPageRowView: View {
    let block: DocBlockID
    let page: DocPage
    let blocks: DocBlockController
    @State private var hovering = false

    var body: some View {
        Button {
            blocks.openPage?(block)
        } label: {
            HStack(spacing: DocPageMetrics.gap) {
                Image(systemName: "doc.text")
                    .font(.system(size: FlooDesignTokens.Icon.standard))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                    .frame(width: DocPageMetrics.icon, height: DocPageMetrics.icon)
                    .background(FlooDesignTokens.ColorRole.Surface.control,
                                in: RoundedRectangle(cornerRadius: FlooDesignTokens.Radius.sm, style: .continuous))
                Text(page.title.isEmpty ? String(localized: "Untitled") : page.title)
                    .font(Font(DocTableCellField.bodyFont))
                    .fontWeight(.semibold)
                    .foregroundStyle(page.title.isEmpty ? FlooDesignTokens.ColorRole.Content.tertiary : FlooDesignTokens.ColorRole.Content.primary)
                    .underline(hovering, color: FlooDesignTokens.ColorRole.Content.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: FlooDesignTokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                Spacer(minLength: 0)
            }
            .frame(minHeight: DocPageMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityHint(String(localized: "Opens the page"))
    }
}

/// The way back in the bar: ‹ and the path of pages, each a step back out to it.
struct DocPagePath: View {
    let pages: DocPages

    var body: some View {
        HStack(spacing: FlooDesignTokens.Space.xs) {
            Button(String(localized: "Back"), systemImage: "chevron.left") { pages.back() }
                .labelStyle(.iconOnly)
                .keyboardShortcut("[", modifiers: .command)
                .buttonStyle(FlooDesignButtonStyle(.borderless))
            ForEach(Array(pages.path.enumerated()), id: \.element.id) { index, page in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: FlooDesignTokens.Icon.inline, weight: .semibold))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.tertiary)
                }
                if index == pages.path.count - 1 {
                    Text(page.title)
                        .font(FlooDesignTokens.Typography.body.font.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Button(page.title) { pages.back(to: index) }
                        .buttonStyle(FlooDesignButtonStyle(.borderless))
                        .foregroundStyle(FlooDesignTokens.ColorRole.Content.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
