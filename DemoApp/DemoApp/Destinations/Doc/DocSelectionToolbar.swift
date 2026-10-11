//
//  DocSelectionToolbar.swift
//  DemoApp
//
//  The Mac's toolbar over selected text (Craft's): a capsule above the selection's
//  first line, at the block's start, with the highlighter and its colours, the marks,
//  a link and the format panel. Its chevron turns it into a row of colours in place:
//  none, highlights (squares) and any highlight on a hue slider, text colours (circles)
//  and any text colour from the system's picker. It comes once the selection settles,
//  and goes when the selection collapses or leaves the text.
//

import SwiftUI
import UIKit
import DocKit

private typealias Tokens = FlooDesignTokens
private typealias Metrics = FlooDesignTokens.Component.SelectionToolbar

/// What the toolbar shows and acts on (the view reads it).
@MainActor
@Observable
final class DocSelectionToolbarModel {
    enum Mode { case marks, colors, customHighlight }

    var mode = Mode.marks
    /// The selected text it acts on.
    var block: DocBlockID?
    var range: Range<Int> = 0..<0
    /// The hue a custom highlight is being picked at.
    var hue: Double = 0.4

    var ranges: [(block: DocBlockID, range: Range<Int>)] {
        block.map { [($0, range)] } ?? []
    }
}

/// Shows and hides the toolbar as the selection changes (pointer devices only).
@MainActor
final class DocSelectionToolbarController {
    unowned let editor: DocEditor
    let model = DocSelectionToolbarModel()
    private let presenter = DocAnchoredPanelPresenter()
    private let anchor = UIView()
    private var pending: Task<Void, Never>?
    private(set) var isShown = false

    init(editor: DocEditor) {
        self.editor = editor
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
    }

    /// The selection changed: the toolbar goes, and comes back where it settles.
    func selectionChanged() {
        guard DocBlockController.usesHandles else { return }
        pending?.cancel()
        // The same selection (a mark applied over it) keeps the toolbar as it is.
        if isShown, let target = target(), target.block == model.block, target.range == model.range { return place(target.view) }
        hide()
        guard let selection = editor.selection, selection.anchor != selection.head else { return }
        // Checked again once it settles: the text view may only now be taking the focus.
        pending = Task { [weak self] in
            try? await Task.sleep(for: Metrics.settleDelay)
            guard let self, !Task.isCancelled, let target = self.target() else { return }
            self.show(target)
        }
    }

    func hide() {
        pending?.cancel()
        guard isShown else { return }
        isShown = false
        presenter.hide()
        anchor.removeFromSuperview()
    }

    /// Selected text in one block of text, being edited.
    private func target() -> (block: DocBlockID, range: Range<Int>, view: UITextView)? {
        guard editor.isEditable, let selection = editor.selection, selection.anchor.block == selection.head.block,
              let block = editor.demo.doc.block(selection.head.block), block.kind.allowsMarks,
              let view = editor.textView(for: block.id), view.isFirstResponder
        else { return nil }
        let range = min(selection.anchor.offset, selection.head.offset)..<max(selection.anchor.offset, selection.head.offset)
        return range.isEmpty ? nil : (block.id, range, view)
    }

    private func show(_ target: (block: DocBlockID, range: Range<Int>, view: UITextView)) {
        model.block = target.block
        model.range = target.range
        model.mode = .marks
        place(target.view)
        presenter.anchorView = anchor
        presenter.show(
            configuration: .init(preferredEdge: .above, horizontalAlignment: .leading, anchorGap: Metrics.gap,
                                 dismissesOnOutsideTouch: false),
            content: AnyView(DocSelectionToolbar(editor: editor, model: model)),
            onRequestDismiss: {}
        )
        isShown = true
    }

    /// The anchor: the selection's first line, from the text's start (the toolbar sits
    /// over the block, not over the selected words).
    private func place(_ view: UITextView) {
        guard let range = view.selectedTextRange else { return }
        let line = view.firstRect(for: range)
        guard !line.isNull, !line.isInfinite else { return }
        let start = view.textContainerInset.left + view.textContainer.lineFragmentPadding - Metrics.leadingOverhang
        if anchor.superview !== view { view.addSubview(anchor) }
        anchor.frame = CGRect(x: start, y: line.minY, width: max(1, line.maxX - start), height: line.height)
    }
}

/// The toolbar's content (the presenter draws no surface of its own).
struct DocSelectionToolbar: View {
    let editor: DocEditor
    @Bindable var model: DocSelectionToolbarModel

    var body: some View {
        Group {
            switch model.mode {
            case .marks: marks
            case .colors: colors
            case .customHighlight: customHighlight
            }
        }
        .padding(.horizontal, Metrics.horizontalInset)
        .frame(height: Metrics.height)
        .background(Capsule().fill(Tokens.ColorRole.Surface.canvas))
        .overlay(Capsule().strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.hairline))
        .compositingGroup()
        .shadow(color: Metrics.shadow.color, radius: Metrics.shadow.radius, y: Metrics.shadow.y)
        .animation(Tokens.Motion.feedback, value: model.mode)
    }

    // MARK: Marks

    private var marks: some View {
        HStack(spacing: 0) {
            let highlighted = editor.common(.highlight, over: model.ranges) != nil
            key("highlighter", label: String(localized: "Highlight"), help: String(localized: "Highlight · ⌘⇧B"), isOn: highlighted) {
                editor.set(.highlight, to: highlighted ? nil : .highlight(color: nil), over: model.ranges)
            }
            Button { model.mode = .colors } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: Tokens.Icon.inline, weight: .semibold))
                    .foregroundStyle(Tokens.ColorRole.Content.secondary)
                    .frame(width: Metrics.chevronWidth, height: Metrics.key)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Colors")
            .accessibilityLabel("Colors")
            ForEach(Self.marks, id: \.symbol) { item in
                key(item.symbol, label: item.title, help: item.shortcut, isOn: covers(item.mark.kind)) {
                    editor.toggle(item.mark, over: model.ranges)
                }
            }
            key("link", label: String(localized: "Link"), help: "⌘K", isOn: covers(.link)) {
                guard let block = model.block, let view = editor.textView(for: block) else { return }
                editor.promptLink(over: model.range, in: block, from: view)
            }
            divider
            key("slider.horizontal.3", label: String(localized: "Format"), help: String(localized: "Format"), isOn: editor.panels.showsFormat) {
                editor.panels.showsFormat.toggle()
            }
        }
    }

    private static let marks: [(symbol: String, title: String, shortcut: String, mark: Mark)] = [
        ("bold", String(localized: "Bold"), "⌘B", .bold),
        ("italic", String(localized: "Italic"), "⌘I", .italic),
        ("strikethrough", String(localized: "Strikethrough"), "⌘⇧X", .strike),
        ("chevron.left.forwardslash.chevron.right", String(localized: "Code"), "⌘E", .code),
    ]

    private func covers(_ kind: MarkKind) -> Bool {
        guard let block = model.block, let text = editor.demo.doc.block(block)?.text else { return false }
        return DocEditor.covers(text, model.range, with: kind)
    }

    /// A key: its symbol, in the tint's filled circle while it's on.
    private func key(_ symbol: String, label: String, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Icon.standard, weight: .medium))
                .foregroundStyle(isOn ? Tokens.ColorRole.Content.onAccent : Tokens.ColorRole.Content.primary)
                .frame(width: Metrics.key, height: Metrics.key)
                .background(Circle().fill(isOn ? Tokens.ColorRole.Accent.primary : .clear))
                .frame(width: Metrics.keySlot, height: Metrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(DocToolbarKeyStyle())
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var divider: some View {
        Rectangle().fill(Tokens.Border.separator).frame(width: Tokens.Border.standard, height: Metrics.dividerHeight)
            .padding(.horizontal, Tokens.Space.xs)
    }

    // MARK: Colours

    /// Craft's: highlights first (squares), then text colours (circles); each ends with
    /// any colour. A choice applies and the marks come back.
    private var colors: some View {
        let highlight = editor.common(.highlight, over: model.ranges)
        let color = editor.common(.color, over: model.ranges)
        return HStack(spacing: Metrics.swatchSpacing) {
            Button {
                editor.clearColors(over: model.ranges)
                model.mode = .marks
            } label: {
                Circle()
                    .strokeBorder(Tokens.Border.separator, lineWidth: Tokens.Border.standard)
                    .overlay(Rectangle().fill(Tokens.Border.separator).frame(width: Tokens.Border.standard, height: Metrics.swatch - 6)
                        .rotationEffect(.degrees(45)))
                    .frame(width: Metrics.swatch, height: Metrics.swatch)
            }
            .buttonStyle(.plain)
            .help("No Color")
            .accessibilityLabel("No Color")
            divider
            ForEach(DocColors.highlights, id: \.token) { item in
                swatch(Self.square, fill: DocColors.highlightSwatch(item.token), title: item.title,
                       isOn: highlight == .highlight(color: item.token)) {
                    editor.set(.highlight, to: .highlight(color: item.token), over: model.ranges)
                    model.mode = .marks
                }
            }
            let customHighlight: String? = if case .highlight(let token?)? = highlight, token.hasPrefix("#") { token } else { nil }
            swatch(Self.square, fill: customHighlight.map(DocColors.highlightSwatch) ?? .clear, title: String(localized: "Other Highlight Color"),
                   isOn: customHighlight != nil, rainbow: true) {
                model.mode = .customHighlight
            }
            divider
            ForEach(DocColors.texts, id: \.token) { item in
                swatch(Self.circle, fill: DocColors.swatch(item.token), title: item.title, isOn: color == .color(item.token)) {
                    editor.set(.color, to: .color(item.token), over: model.ranges)
                    model.mode = .marks
                }
            }
            customTextColor(color)
        }
    }

    private static let square = RoundedRectangle(cornerRadius: Tokens.Component.Swatch.cornerRadius, style: .continuous)
    private static let circle = Circle()

    /// A colour to pick: ticked when the text has it; any colour's is ringed in a rainbow.
    private func swatch(_ shape: some InsettableShape, fill: Color, title: String, isOn: Bool, rainbow: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            shape.fill(fill)
                .overlay(shape.strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Component.Swatch.border))
                .padding(rainbow ? Tokens.Component.Swatch.rainbowInset : 0)
                .overlay { if rainbow { shape.strokeBorder(DocColors.rainbow, lineWidth: Tokens.Component.Swatch.rainbowWidth) } }
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: Tokens.Icon.inline, weight: .bold))
                            .foregroundStyle(Tokens.ColorRole.Content.onAccent)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                    } else if rainbow {
                        Image(systemName: "chevron.down").font(.system(size: Tokens.Icon.inline - 2, weight: .bold))
                            .foregroundStyle(Tokens.ColorRole.Content.secondary)
                    }
                }
                .frame(width: Metrics.swatch, height: Metrics.swatch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Any text colour: the system's picker, clear over the rainbow circle, takes the click.
    private func customTextColor(_ current: Mark?) -> some View {
        let picked: String? = if case .color(let token)? = current, token.hasPrefix("#") { token } else { nil }
        return swatch(Self.circle, fill: picked.map(DocColors.swatch) ?? .clear, title: String(localized: "Other Text Color"), isOn: picked != nil,
                      rainbow: true) {}
            .overlay {
                ColorPicker("Other Text Color", selection: Binding {
                    picked.map(DocColors.swatch) ?? .primary
                } set: { color in
                    editor.set(.color, to: .color(DocColors.hex(color)), over: model.ranges, merge: editor.colorMergeKey(over: model.ranges))
                }, supportsOpacity: false)
                .labelsHidden()
                .opacity(0.02)
            }
    }

    // MARK: Any highlight

    /// A hue on a rainbow track, the colour it makes, and done (Craft's).
    private var customHighlight: some View {
        HStack(spacing: Tokens.Space.md) {
            DocHueSlider(hue: $model.hue) { hue in
                editor.set(.highlight, to: .highlight(color: DocColors.hex(DocColors.highlight(hue: hue))), over: model.ranges,
                           merge: editor.colorMergeKey(over: model.ranges))
            }
            .frame(width: Metrics.hueTrackWidth)
            Self.square
                .fill(DocColors.highlightSwatch(DocColors.hex(DocColors.highlight(hue: model.hue))))
                .frame(width: Metrics.swatch, height: Metrics.swatch)
            divider
            Button {
                editor.endColorChanges()
                model.mode = .colors
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: Tokens.Icon.inline, weight: .bold))
                    .foregroundStyle(Tokens.ColorRole.Content.onAccent)
                    .frame(width: Metrics.hueKnob, height: Metrics.hueKnob)
                    .background(Circle().fill(Color.primary.opacity(Tokens.Opacity.strong)))
            }
            .buttonStyle(.plain)
            .help("Done")
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, Tokens.Space.md)
    }
}

/// A hue picked along a rainbow capsule, its knob a white disc.
private struct DocHueSlider: View {
    @Binding var hue: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let knob = Metrics.hueKnob
            let travel = max(1, geometry.size.width - knob)
            ZStack(alignment: .leading) {
                Capsule().fill(DocColors.hues).frame(height: Metrics.hueTrackHeight)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Tokens.Border.subtle, lineWidth: Tokens.Border.hairline))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: CGFloat(hue) * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                hue = min(max(0, Double((value.location.x - knob / 2) / travel)), 1)
                onChange(hue)
            })
        }
        .frame(height: Tokens.Control.minimumHitTarget)
        .accessibilityElement()
        .accessibilityLabel("Highlight Color")
        .accessibilityValue("\(Int(hue * 360))°")
        .accessibilityAdjustableAction { direction in
            hue = min(max(0, hue + (direction == .increment ? 0.05 : -0.05)), 1)
            onChange(hue)
        }
    }
}

/// A key's press and hover: a soft disc behind it.
private struct DocToolbarKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DocToolbarKey(configuration: configuration)
    }

    private struct DocToolbarKey: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Circle()
                    .fill(configuration.isPressed ? Tokens.ColorRole.Surface.pressed : hovering ? Tokens.ColorRole.Surface.hover : .clear)
                    .frame(width: Metrics.key, height: Metrics.key))
                .onHover { hovering = $0 }
        }
    }
}
