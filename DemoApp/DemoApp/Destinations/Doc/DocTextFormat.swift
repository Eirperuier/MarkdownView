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

import SwiftUI
import UIKit
import DocKit
import FlooDesign

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
    func menuSections(linkFrom view: @escaping () -> UIView?, unfolded: Binding<Bool>? = nil) -> [FlooDesignActionMenuSection] {
        var keys = keys(linkFrom: view)
        let isUnfolded = unfolded?.wrappedValue ?? true
        if let unfolded {
            keys.append(.init(id: "more", symbol: isUnfolded ? "chevron.up" : "chevron.down",
                              title: isUnfolded ? String(localized: "Fewer Options") : String(localized: "More Options"), isOn: false) {
                withAnimation(FlooDesignTokens.Motion.step) { unfolded.wrappedValue.toggle() }
            })
        }
        let strip = FlooDesignActionMenuSection(controls: [.segments("text-marks", keys)])
        return isUnfolded ? [strip] + rest : [strip]
    }

    private func keys(linkFrom view: @escaping () -> UIView?) -> [FlooDesignSegments.Item] {
        [
            .init(id: "highlight", symbol: "highlighter", title: String(localized: "Highlight"), isOn: isOn(.highlight)) { toggleHighlight() },
        ] + Self.marks.map { item in
            .init(id: item.id, symbol: item.symbol, title: item.title, isOn: isOn(item.mark.kind)) { toggle(item.mark) }
        } + [
            .init(id: "link", symbol: "link", title: String(localized: "Link"), isOn: isOn(.link), isEnabled: ranges.count == 1) {
                if let view = view() { link(from: view) }
            },
        ]
    }

    /// Under the keys: the colours, the pen, the format panel.
    private var rest: [FlooDesignActionMenuSection] {
        let penTitle = Self.pens.first { $0.mark == pen }?.title ?? String(localized: "None")
        return [
            .init(controls: [
                .color(String(localized: "Highlight"), picked: highlightFill, id: "text-highlight", sections: [
                    .init(controls: [.swatches("text-highlights", highlightSwatches)]),
                ]),
                .color(String(localized: "Text Color"), picked: colorFill, id: "text-color", sections: [
                    .init(controls: [.swatches("text-colors", colorSwatches)]),
                ]),
            ]),
            .init(String(localized: "Pen"), controls: [
                .picker(String(localized: "Pen"), value: penTitle, id: "text-pen", sections: [
                    .init(.rows, [.action(String(localized: "None"), isOn: pen == nil) { setPen(nil) }]
                        + Self.pens.map { item in .action(item.title, symbol: item.symbol, isOn: pen == item.mark) { setPen(item.mark) } }),
                ]),
            ]),
            .init(.rows, [
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

    /// Craft's highlights (squares): none, the palette, any colour.
    private var highlightSwatches: FlooDesignMenuSwatches {
        let current = highlight
        let swatch = { (token: String?, title: String, fill: Color) in
            FlooDesignMenuSwatches.Swatch(id: token ?? "none", title: title, fill: fill,
                                          isOn: token == nil ? current == nil : current == .highlight(color: token),
                                          identifier: "highlight-\(token ?? "none")") { setHighlight(token) }
        }
        let custom = customHighlight
        return FlooDesignMenuSwatches(shape: .rounded, chosen: .ring(FlooDesignTokens.ColorRole.Content.primary),
                                      [swatch(nil, String(localized: "None"), FlooDesignTokens.ColorRole.Surface.canvas)]
                                          + DocColors.highlights.map { swatch($0.token, $0.title, DocColors.highlightSwatch($0.token)) },
                                      well: .init(title: String(localized: "Other Highlight Color"), picked: custom.map(DocColors.highlightSwatch),
                                                  selection: Binding { custom.map(DocColors.highlightSwatch) ?? .yellow } set: { pickHighlight($0) },
                                                  identifier: "highlight-custom"))
    }

    /// Craft's text colours (circles): the default, the palette, any colour.
    private var colorSwatches: FlooDesignMenuSwatches {
        let current = color
        let swatch = { (token: String?, title: String) in
            FlooDesignMenuSwatches.Swatch(id: token ?? "none", title: title, fill: token.map(DocColors.swatch) ?? FlooDesignTokens.ColorRole.Content.primary,
                                          isOn: current == token.map(Mark.color), identifier: "text-color-\(token ?? "none")") { setColor(token) }
        }
        let custom = customColor
        return FlooDesignMenuSwatches(chosen: .ring(FlooDesignTokens.ColorRole.Content.primary),
                                      [swatch(nil, String(localized: "Default"))] + DocColors.texts.map { swatch($0.token, $0.title) },
                                      well: .init(title: String(localized: "Other Text Color"), picked: custom.map(DocColors.swatch),
                                                  selection: Binding { custom.map(DocColors.swatch) ?? .primary } set: { pickColor($0) },
                                                  identifier: "text-color-custom"))
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
