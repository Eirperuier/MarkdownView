//
//  DocTextFormat.swift
//  DemoApp
//
//  What selected text takes, one list for every place that offers it: the marks it turns
//  on and off (highlight, bold, italic, strikethrough, code, a link), its colour, its
//  highlight's colour and a pen mark, each with what the text has now. The places draw
//  it their own way:
//  - the Mac's menu over the selection (DocSelectionToolbar): FlooDesign's action menu,
//    the marks as keys (a strip, until its last key unfolds the rest), the colours as its
//    colour settings whose palettes open as the menu's next level, the pen as a choice;
//  - the Format submenu of the text's system menu (a right-click; the phone's edit menu,
//    the phone's only one for selected text);
//  - the format panels take its marks.
//  The colours are Craft's for selected text (DocColors.texts, .highlights), and any
//  colour from the system's picker.
//

import FlooUIKit
import SwiftUI
import UIKit
import DocKit

@MainActor
struct DocTextFormat {
    let editor: DocEditor
    /// The selected text: a range in each block.
    let ranges: [(block: DocBlockID, range: Range<Int>)]

    /// The marks text turns on and off, in the order they're offered (Craft's).
    static let marks: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("bold", "bold", String(localized: "Bold"), .bold),
        ("italic", "italic", String(localized: "Italic"), .italic),
        ("strike", "strikethrough", String(localized: "Strikethrough"), .strike),
        ("code", "chevron.left.forwardslash.chevron.right", String(localized: "Code"), .code),
    ]

    static let pens: [(id: String, symbol: String, title: String, mark: Mark)] = [
        ("circle", "circle.dashed", String(localized: "Circle"), .pen(kind: "circle", color: nil)),
        ("wavy", "water.waves", String(localized: "Wavy Line"), .pen(kind: "wavy", color: nil)),
    ]

    // MARK: What the text has

    /// Whether all of the selected text has the mark.
    func isOn(_ kind: MarkKind) -> Bool {
        !ranges.isEmpty && ranges.allSatisfy { range in
            editor.textBlock(range.block).map { DocEditor.covers($0.text, range.range, with: kind) } ?? false
        }
    }

    var color: Mark? { editor.common(.color, over: ranges) }
    var highlight: Mark? { editor.common(.highlight, over: ranges) }
    var pen: Mark? { editor.common(.pen, over: ranges) }

    /// A colour picked from the system's picker (a `#rrggbb` token), not the palette's.
    private static func custom(_ token: String?) -> String? {
        token.flatMap { $0.hasPrefix("#") ? $0 : nil }
    }

    private var customColor: String? {
        if case .color(let token)? = color { Self.custom(token) } else { nil }
    }

    private var customHighlight: String? {
        if case .highlight(let token)? = highlight { Self.custom(token) } else { nil }
    }

    // MARK: What it does

    func toggle(_ mark: Mark) {
        editor.toggle(mark, over: ranges)
    }

    /// The plain highlight on, or any highlight off (⌘⇧B).
    func toggleHighlight() {
        editor.set(.highlight, to: highlight == nil ? .highlight(color: nil) : nil, over: ranges)
    }

    func setColor(_ token: String?) {
        editor.endColorChanges()
        editor.set(.color, to: token.map(Mark.color), over: ranges)
    }

    func setHighlight(_ token: String?) {
        editor.endColorChanges()
        editor.set(.highlight, to: token.map { .highlight(color: $0) }, over: ranges)
    }

    func setPen(_ mark: Mark?) {
        editor.set(.pen, to: mark, over: ranges)
    }

    /// A colour being picked: one step however long it's dragged.
    private func pickColor(_ color: Color) {
        editor.set(.color, to: .color(DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
    }

    private func pickHighlight(_ color: Color) {
        editor.set(.highlight, to: .highlight(color: DocColors.hex(color)), over: ranges, merge: editor.colorMergeKey(over: ranges))
    }

    /// The link over the text, asked for beside `view` (one range: the text in one block).
    func link(from view: UIView) {
        guard ranges.count == 1, let range = ranges.first else { return }
        editor.promptLink(over: range.range, in: range.block, from: view)
    }

    private var linkTitle: String {
        isOn(.link) ? String(localized: "Edit Link…") : String(localized: "Link…")
    }

    // MARK: The Mac's menu over the selection

    /// The marks as keys; the colours as colour settings, their palettes the next level;
    /// the pen as a choice; then the format panel. With `unfolded`, the keys end with one
    /// that unfolds the rest and folds it again, and folded the keys are all there is (a
    /// strip over the text).
    func menuSections(linkFrom view: @escaping () -> UIView?, unfolded: Binding<Bool>? = nil) -> [FlooMenuSection] {
        var keys = keys(linkFrom: view)
        let isUnfolded = unfolded?.wrappedValue ?? true
        if let unfolded {
            keys.append(FlooMenuTile(isUnfolded ? String(localized: "Fewer Options") : String(localized: "More Options"), symbol: isUnfolded ? "chevron.up" : "chevron.down",
                                     showsTitle: false, isOn: false, isMomentary: true) { _ in
                unfolded.wrappedValue.toggle()
            })
        }
        let strip = FlooMenuSection([.docKeys("text-marks", keys)])
        return isUnfolded ? [strip] + rest : [strip]
    }

    private func keys(linkFrom view: @escaping () -> UIView?) -> [FlooMenuTile] {
        [
            FlooMenuTile(String(localized: "Highlight"), symbol: "highlighter", showsTitle: false, isOn: isOn(.highlight)) { _ in toggleHighlight() },
        ] + Self.marks.map { item in
            FlooMenuTile(item.title, symbol: item.symbol, showsTitle: false, isOn: isOn(item.mark.kind)) { _ in toggle(item.mark) }
        } + [
            FlooMenuTile(String(localized: "Link"), symbol: "link", showsTitle: false, isOn: isOn(.link), isEnabled: ranges.count == 1, isMomentary: true) { _ in
                if let view = view() { link(from: view) }
            },
        ]
    }

    /// Under the keys: the colours, the pen, the format panel.
    private var rest: [FlooMenuSection] {
        let pens: [Mark?] = [nil] + Self.pens.map(\.mark)
        return [
            .init([
                .docColor(String(localized: "Highlight"), picked: highlightFill, [.init([highlightSwatches])]),
                .docColor(String(localized: "Text Color"), picked: colorFill, [.init([colorSwatches])]),
            ]),
            .init(String(localized: "Pen"), [
                .choice(String(localized: "Pen"), options: [String(localized: "None")] + Self.pens.map(\.title), selected: pens.firstIndex(of: pen)) { setPen(pens[$0]) },
            ]),
            .init([
                .action(String(localized: "Format Panel"), symbol: "slider.horizontal.3") { editor.panels.showsFormat = true },
            ]),
        ]
    }

    private var colorFill: Color? {
        if case .color(let token)? = color { DocColors.swatch(token) } else { nil }
    }

    private var highlightFill: Color? {
        if case .highlight(let token)? = highlight { DocColors.highlightSwatch(token ?? "yellow") } else { nil }
    }

    /// Craft's highlights: none, the palette, any colour.
    private var highlightSwatches: FlooMenuItem {
        let current = highlight
        let swatch = { (token: String?, title: String, fill: Color) in
            DocSwatch(id: token ?? "none", title: title, color: fill, isOn: token == nil ? current == nil : current == .highlight(color: token)) { setHighlight(token) }
        }
        return .docSwatches("text-highlights", [swatch(nil, String(localized: "None"), DocTokens.ColorRole.Surface.canvas)]
                                + DocColors.highlights.map { swatch($0.token, $0.title, DocColors.highlightSwatch($0.token)) },
                            well: .init(title: String(localized: "Other Highlight Color"), selected: customHighlight.map { UIColor(DocColors.highlightSwatch($0)) }) { pickHighlight(Color(uiColor: $0)) })
    }

    /// Craft's text colours: the default, the palette, any colour.
    private var colorSwatches: FlooMenuItem {
        let current = color
        let swatch = { (token: String?, title: String) in
            DocSwatch(id: token ?? "none", title: title, color: token.map(DocColors.swatch) ?? DocTokens.ColorRole.Content.primary, isOn: current == token.map(Mark.color)) { setColor(token) }
        }
        return .docSwatches("text-colors", [swatch(nil, String(localized: "Default"))] + DocColors.texts.map { swatch($0.token, $0.title) },
                            well: .init(title: String(localized: "Other Text Color"), selected: customColor.map { UIColor(DocColors.swatch($0)) }) { pickColor(Color(uiColor: $0)) })
    }

    // MARK: The system's menu

    /// The Format submenu of the text's system menu: the marks, the link, then the
    /// colours, the highlight and the pen as choices (any colour is only the Mac's menu's).
    func systemMenu(linkFrom view: UIView) -> UIMenu {
        let state = { (on: Bool) -> UIMenuElement.State in on ? .on : .off }
        let marks = [UIAction(title: String(localized: "Highlight"), image: UIImage(systemName: "highlighter"), state: state(isOn(.highlight))) { _ in
            toggleHighlight()
        }] + Self.marks.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol), state: state(isOn(item.mark.kind))) { _ in toggle(item.mark) }
        }
        let link = UIAction(title: linkTitle, image: UIImage(systemName: "link")) { [weak view] _ in
            if let view { self.link(from: view) }
        }
        let color = color, highlight = highlight, pen = pen
        let colors = UIMenu(title: String(localized: "Text Color"), image: UIImage(systemName: "paintpalette"), children: [
            UIAction(title: String(localized: "Default"), state: state(color == nil)) { _ in setColor(nil) },
        ] + DocColors.texts.map { item in
            UIAction(title: item.title, image: DocColors.dot(item.token), state: state(color == .color(item.token))) { _ in setColor(item.token) }
        })
        let highlights = UIMenu(title: String(localized: "Highlight Color"), image: UIImage(systemName: "highlighter"), children: [
            UIAction(title: String(localized: "None"), state: state(highlight == nil)) { _ in setHighlight(nil) },
        ] + DocColors.highlights.map { item in
            UIAction(title: item.title, image: DocColors.dot(item.token, highlight: true), state: state(highlight == .highlight(color: item.token))) { _ in
                setHighlight(item.token)
            }
        })
        let pens = UIMenu(title: String(localized: "Pen"), image: UIImage(systemName: "pencil.tip.crop.circle"), children: [
            UIAction(title: String(localized: "None"), state: state(pen == nil)) { _ in setPen(nil) },
        ] + Self.pens.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol), state: state(pen == item.mark)) { _ in setPen(item.mark) }
        })
        return UIMenu(title: String(localized: "Format"), image: UIImage(systemName: "textformat"),
                      children: [UIMenu(options: .displayInline, children: marks + [link]), colors, highlights, pens])
    }
}
