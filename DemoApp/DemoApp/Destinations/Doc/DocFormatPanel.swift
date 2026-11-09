//
//  DocFormatPanel.swift
//  DemoApp
//
//  What holds the settings (DocSettings) as floo's menu sections: the Mac's panel from the
//  bar's Aa and a block's right-click, a cell's menu, and for now a cell's panel and the
//  layouts on a phone. Style and format together, with layout a level in; a menu takes each
//  as a submenu. A phone's page for blocks is DocFormatPage.
//

import FlooUIKit
import SwiftUI
import DocKit

private typealias Tokens = DocTokens

/// The editor's selection, observable.
@MainActor
@Observable
final class DocCursor {
    var selection: DocSelection?
}

/// The format panels' state.
@MainActor
@Observable
final class DocPanels {
    /// The Mac's format panel (-docFormat YES opens with it).
    var showsFormat = UserDefaults.standard.bool(forKey: "docFormat")
    /// The phone's and iPad's, over the selected blocks or the edited cell.
    var showsSheet = false
    /// What Copy Format took, for Paste Format.
    var copiedFormat: DocCopiedFormat?
}

/// Read inside something following what it reads, so the holder follows the document and
/// the selection.
@MainActor
struct DocFormatMenu {
    let editor: DocEditor
    /// A caret stands for its whole block, where the panel takes the keyboard's place.
    var caretTakesBlock = !DocBlockController.usesHandles

    var formatting: DocFormatting { DocFormatting(editor: editor, caretTakesBlock: caretTakesBlock) }

    var target: any DocMenuTarget {
        let formatting = formatting
        if let cell = formatting.cell { return DocSelectedCells(cell: cell, formatting: formatting) }
        return DocSelectedBlocks(formatting: formatting)
    }

    var style: [FlooMenuSection] { target.menu.style }
    var format: [FlooMenuSection] { target.menu.format }
    var layout: [FlooMenuSection] { target.menu.layout }

    /// A panel of them.
    var sections: [FlooMenuSection] {
        let menu = target.menu
        var sections = menu.style + menu.format
        var more: [FlooMenuItem] = []
        if !menu.layout.isEmpty {
            more.append(.submenu(String(localized: "Layout"), symbol: "rectangle.split.2x1", menu.layout))
        }
        if !formatting.inCell {
            more.append(.submenu(String(localized: "Manage Format"), symbol: "doc.on.clipboard", [formatActions(copies: formatting.decorated.count == 1)]))
        }
        sections.append(.init(more))
        return sections
    }

    /// A menu's three submenus.
    func submenus(formatFirst: [FlooMenuSection] = []) -> [FlooMenuItem] {
        [
            .submenu(String(localized: "Style"), symbol: "paintbrush", style),
            .submenu(String(localized: "Format"), symbol: "textformat", formatFirst + format),
            .submenu(String(localized: "Layout"), symbol: "rectangle.split.2x1", isEnabled: !layout.isEmpty, layout),
        ]
    }

    /// Copy Format only for one block (`copies`).
    func formatActions(copies: Bool) -> FlooMenuSection {
        .init(Self.formatKeys(formatting, copies: copies).map { key in
            .action(key.title, isEnabled: key.isEnabled) { key.press() }
        })
    }

    /// Copy, paste and clear a format.
    static func formatKeys(_ formatting: DocFormatting, copies: Bool) -> [DocKey] {
        let editor = formatting.editor
        let copied = editor.panels.copiedFormat
        return [
            DocKey(id: "copy-format", title: String(localized: "Copy Format"), look: .symbol("doc.on.clipboard"), isEnabled: copies, isMomentary: true,
                   action: .perform { editor.panels.copiedFormat = formatting.format }),
            DocKey(id: "paste-format", title: String(localized: "Paste Format"), look: .symbol("doc.on.clipboard.fill"), isEnabled: copied != nil, isMomentary: true,
                   action: .perform { if let copied { formatting.paste(copied) } }),
            DocKey(id: "clear-format", title: String(localized: "Clear Format"), look: .symbol("eraser"), isMomentary: true, action: .perform {
                let ids = Set(formatting.decorated.map(\.id))
                editor.blocks.reshape { editor.clearFormat(of: ids) }
            }),
        ]
    }

    /// Craft's fills: none, six hues by three strengths twice, any colour.
    /// `none`: what None sets (a stripe's is `TableStyle.noStripe`, a cell's nil).
    static func fills(_ title: String, current: String?, none: String? = nil, set: @escaping (String?) -> Void) -> FlooMenuItem {
        let custom: String? = if let current, current.hasPrefix("#") { current } else { nil }
        return .docSwatches(title, DocColors.fillGrid.enumerated().map { index, swatch in
            let token = swatch ?? none
            return DocSwatch(id: token ?? "none-\(index)", title: swatch.map(DocColors.fillTitle) ?? String(localized: "None"),
                             color: token.flatMap(DocColors.fill) ?? Tokens.ColorRole.Surface.canvas, isOn: current == token) { set(token) }
        }, well: .init(title: String(localized: "Other Color"), selected: custom.flatMap(DocColors.fill).map { UIColor($0) }) { set(DocColors.hex(Color(uiColor: $0))) })
    }

    /// Plain text, number and percent; a currency in a submenu (Craft's).
    static func numbers(_ current: CellNumberFormat?, set: @escaping (CellNumberFormat?) -> Void) -> [FlooMenuSection] {
        let currencies = CellNumberFormat.currencies.map { code in
            FlooMenuItem.action(CellNumberFormat.currency(code: code).title, isOn: current == .currency(code: code), keepsOpen: true) {
                set(.currency(code: code))
            }
        }
        return [
            .init([
                .action(String(localized: "Plain Text"), isOn: current == nil, keepsOpen: true) { set(nil) },
                .action(CellNumberFormat.number.title, isOn: current == .number, keepsOpen: true) { set(.number) },
                .action(CellNumberFormat.percent.title, isOn: current == .percent, keepsOpen: true) { set(.percent) },
            ]),
            .init([.submenu(String(localized: "Currency"), [.init(currencies)])]),
        ]
    }
}
