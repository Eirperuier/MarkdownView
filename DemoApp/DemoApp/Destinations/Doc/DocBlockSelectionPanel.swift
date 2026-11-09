//
//  DocBlockSelectionPanel.swift
//  DemoApp
//
//  The phone's actions on the selected blocks: floo's self-drawn floating panel of action
//  tiles at the foot of the window (`.floating(at:).selfDrawn()`). It follows the selection
//  alone, shown exactly while selecting under no sheet, so nothing can leave it on screen.
//  Style and Layout give way to pages of the selection's or the edited cell's settings
//  (DocSettingsPanel) in the same kind of panel.
//

import FlooUIKit
import SwiftUI
import UIKit

@MainActor
final class DocBlockSelectionPanel {
    private typealias Action = DocTokens.ColorRole.Action

    private enum Menu {
        case format, layout
    }

    private struct State: Equatable {
        var isShown: Bool
        var menu: Menu?
        var hasMedia: Bool
        var canGroup: Bool
    }

    private unowned let blocks: DocBlockController
    private var sheet: FlooActionTilesSheet?
    /// Kept by its panel alone, as long as that's in the window.
    private weak var lastOpened: FlooActionTilesSheet?
    private var pages: DocSettingsPanel?
    private var layoutTile: FlooActionTile?
    private var shownMenu: Menu?
    private var groupTile: FlooActionTile?
    /// Which `start` the tracking belongs to: one left behind stops at its next change.
    private var following = 0
    private var isFollowing = false

    var theme: FlooTheme? {
        didSet { if let theme, theme != oldValue { sheet?.setFlooTheme(theme, animated: false) } }
    }

    init(blocks: DocBlockController) {
        self.blocks = blocks
    }

    /// The page is on screen.
    func start() {
        guard !isFollowing else { return }
        isFollowing = true
        following += 1
        follow(following)
    }

    /// The page has gone, the panel with it (it stands in the window, not the page).
    func stop() {
        isFollowing = false
        following += 1
        close()
        closeMenu()
    }

    private var state: State {
        let hasMedia = !blocks.selectedLayouts.isEmpty || !blocks.selectedImageFits.isEmpty
        let menu: Menu? = blocks.showsSelectionSheet ? .format : blocks.isSelecting && blocks.isChoosingLayout && hasMedia ? .layout : nil
        return State(isShown: blocks.isSelecting && menu == nil, menu: menu, hasMedia: hasMedia, canGroup: blocks.canGroup)
    }

    private func follow(_ run: Int) {
        guard run == following else { return }
        let state = withObservationTracking {
            state
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow(run) } }
        }
        apply(state)
    }

    private func apply(_ state: State) {
        if let menu = state.menu {
            close()
            if shownMenu != menu {
                closeMenu()
                openMenu(menu)
            }
            if shownMenu == nil { retry() }
            return
        }
        closeMenu()
        guard state.isShown else { return close() }
        if sheet == nil { open() }
        guard let sheet else { return retry() }
        sheet.show(only: sheet.tiles.tiles.filter { tile in
            if tile === layoutTile { return state.hasMedia }
            if tile === groupTile { return state.canGroup }
            return true
        })
    }

    /// Selecting as the page comes up: the list isn't in the window yet, and nothing
    /// observable says when it is.
    private func retry() {
        let run = following
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, run == self.following else { return }
                self.apply(self.state)
            }
        }
    }

    private func openMenu(_ menu: Menu) {
        guard let presenter = blocks.presenter, presenter.viewIfLoaded?.window != nil else { return }
        let opened = DocSettingsPanel { [unowned blocks] in DocFormatMenu(editor: blocks.editor).target.pages }
        shownMenu = menu
        pages = opened
        if DocFormatMenu(editor: blocks.editor).formatting.inCell { blocks.editor.holdKeyboard() }
        let inCell = DocFormatMenu(editor: blocks.editor).formatting.inCell
        opened.open(from: presenter, at: placement(in: presenter), page: menu == .layout ? .layout : inCell ? .cellMain : .main, theme: theme) { [weak self] in
            guard let self else { return }
            self.shownMenu = nil
            self.pages = nil
            self.blocks.editor.releaseKeyboard()
            self.blocks.closeSheet()
        }
    }

    /// A level in: what's placed there.
    func openInner(_ page: DocPageID) { pages?.openInner(page) }

    func closeInner() { pages?.closeInner() }

    private func closeMenu() {
        guard shownMenu != nil else { return }
        shownMenu = nil
        pages?.close()
        pages = nil
        blocks.editor.releaseKeyboard()
    }

    private func open() {
        guard let presenter = blocks.presenter, presenter.viewIfLoaded?.window != nil else { return }
        let opened = FlooActionTilesSheet(FlooActionTiles(makeTiles()))
        if let theme { opened.setFlooTheme(theme, animated: false) }
        sheet = opened
        lastOpened = opened
        // Dragged down, the selection ends with it.
        let style = FlooSheetStyle.floating(at: placement(in: presenter)).selfDrawn().whenClosed { [weak self, weak opened] in
            guard let self, let opened, self.sheet === opened else { return }
            self.sheet = nil
            self.blocks.endSelecting()
        }
        presenter.flooPresentSheet(opened, style: style)
    }

    /// At the foot, in the middle of the page's column rather than of the window (iPad's
    /// sidebar is beside it).
    func placement(in presenter: UIViewController) -> FlooPanelPlacement {
        guard let column = blocks.listFrameInWindow, let window = presenter.view.window else { return .bottom }
        let across = column.midX - window.bounds.midX
        let rightToLeft = presenter.view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        return .bottom.offset(by: CGSize(width: rightToLeft ? -across : across, height: 0))
    }

    private func close() {
        sheet?.flooDismissSheet()
        sheet = nil
    }

    /// Tests: what's standing in the window, closing included, and the tiles it shows.
    private var testMenuView: UIView? { pages?.testTopView }
    var testMenuIsOpen: Bool { testMenuView?.window != nil }
    /// As a drag closes it: by its panel, not the selection.
    func testCloseAsDragged() { sheet?.flooDismissSheet() }
    var testMenuDepth: Int { pages?.testDepth ?? 0 }
    var testMenuFrame: CGRect? { testMenuView.map { $0.convert($0.bounds, to: nil) } }
    /// The open panel's key named `title`.
    func testMenuKey(_ title: String) -> UIControl? { pages?.testKey(title) }
    var testHoldsKeyboard: Bool { blocks.editor.holdsKeyboard }
    var testIsInWindow: Bool { lastOpened?.viewIfLoaded?.window != nil }
    var testTiles: [FlooActionTile] { sheet?.tiles.tiles.filter { !$0.isHidden } ?? [] }

    private func makeTiles() -> [FlooActionTile] {
        let neutral = UIColor(Action.neutral)
        let style = FlooActionTile(title: String(localized: "Style"), image: UIImage(systemName: "textformat"), color: UIColor(Action.format)) { [unowned blocks] in
            blocks.editor.panels.showsSheet = true
        }
        style.accessibilityIdentifier = "selection-style"
        let layout = FlooActionTile(title: String(localized: "Layout"), image: UIImage(systemName: "rectangle.split.2x1"), color: neutral) { [unowned blocks] in
            blocks.isChoosingLayout = true
        }
        layoutTile = layout
        // Several blocks into a page of their own (Craft's Group, the Mac's menu).
        let group = FlooActionTile(title: String(localized: "Group"), image: UIImage(systemName: "wand.and.sparkles"), color: neutral) { [unowned blocks] in
            blocks.groupSelection()
        }
        let actions = FlooActionTile(title: String(localized: "Actions"), image: UIImage(systemName: "square.and.arrow.up"), color: neutral)
        actions.menu = UIMenu(children: [FlooMenuSection(nil, [
            .action(String(localized: "Copy"), symbol: "doc.on.doc") { [unowned blocks] in
                blocks.copySelection()
                blocks.endSelecting()
            },
            .action(String(localized: "Duplicate"), symbol: "plus.square.on.square") { [unowned blocks] in
                blocks.duplicateSelection()
            },
        ])].systemElements())
        actions.showsMenuAsPrimaryAction = true
        let delete = FlooActionTile(title: String(localized: "Delete"), image: UIImage(systemName: "trash"), role: .destructive) { [unowned blocks] in
            blocks.deleteSelection()
        }
        groupTile = group
        return [style, layout, group, actions, delete]
    }
}
