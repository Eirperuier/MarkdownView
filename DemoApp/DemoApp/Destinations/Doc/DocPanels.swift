//
//  DocPanels.swift
//  DemoApp
//
//  The document's panels, on floo-uikit's floating panel: beside what opened them on a
//  large screen and the Mac, self-drawn at the window's foot on a small one, what's behind
//  them staying usable.
//

import FlooUIKit
import SwiftUI

extension View {
    /// `content` in a panel beside this view while `isPresented`, which the document holds:
    /// `onDismiss` is how it's told a touch outside, Esc or the sheet closed it.
    func docPanel<Content: View>(
        isPresented: Bool,
        edge: FlooFloatingEdge = .below,
        alignment: FlooFloatingAlignment = .leading,
        keepsOpen: (@MainActor (CGPoint) -> Bool)? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        flooFloating(
            isPresented: Binding(get: { isPresented }, set: { if !$0 { onDismiss() } }),
            edge: edge,
            alignment: alignment,
            keepsOpen: keepsOpen,
            selfDrawn: true,
            content: content
        )
    }

    /// A page in UIKit (DocCollectionPages) in a panel beside this view while `isPresented`.
    /// `update`: as this view updates, for the page to follow what it reads. A touch outside
    /// closes it and goes no further.
    func docPanel(
        isPresented: Bool,
        edge: FlooFloatingEdge = .below,
        alignment: FlooFloatingAlignment = .leading,
        onDismiss: @escaping () -> Void,
        page: @escaping @MainActor () -> UIViewController,
        update: @escaping @MainActor (UIViewController) -> Void = { _ in }
    ) -> some View {
        flooFloating(
            isPresented: Binding(get: { isPresented }, set: { if !$0 { onDismiss() } }),
            edge: edge,
            alignment: alignment,
            isModal: true,
            selfDrawn: true,
            page: page,
            update: update
        )
    }

    /// A panel's width: its own beside what opened it, the sheet's in a sheet.
    func docPanelWidth(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        flooPanelWidth(width, alignment: alignment)
    }

    /// Sizes the sheet this content is in to the content, the page behind staying usable
    /// (a tool's sheet). `estimate`: its height until it's measured.
    func docSizedSheet(estimate: CGFloat) -> some View {
        modifier(DocSizedSheet(height: estimate))
    }
}

/// A panel's content, its margins from the panel's edges.
struct DocPanelSurface<Content: View>: View {
    private let contentInset: EdgeInsets
    private let content: Content

    init(contentInset: EdgeInsets = EdgeInsets(top: DocTokens.Space.md, leading: DocTokens.Space.sm,
                                               bottom: DocTokens.Space.md, trailing: DocTokens.Space.sm),
         @ViewBuilder content: () -> Content) {
        self.contentInset = contentInset
        self.content = content()
    }

    var body: some View {
        content.padding(contentInset)
    }
}

private struct DocSizedSheet: ViewModifier {
    @State var height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.top, DocTokens.Component.Sheet.inset)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                guard new != height else { return }
                withAnimation(FlooMotion.sheetResize.swiftUI) { height = new }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .presentationDetents([.height(height)])
            .presentationDragIndicator(.hidden)
            .presentationBackgroundInteraction(.enabled)
    }
}

extension View {
    /// `sections` in floo's panel while `isPresented`, following what they read; `onDismiss`
    /// when it's gone some way of its own.
    func docMenuPanel(isPresented: Bool, title: String? = nil, edge: FlooFloatingEdge = .below, alignment: FlooFloatingAlignment = .leading,
                      staysBeside: Bool = false, keepsOpen: (@MainActor (CGPoint) -> Bool)? = nil, onDismiss: @escaping () -> Void,
                      sections: @escaping @MainActor (FlooPanelPresentation) -> [FlooMenuSection]) -> some View {
        flooMenuPanel(isPresented: Binding(get: { isPresented }, set: { if !$0 { onDismiss() } }), title: title, edge: edge, alignment: alignment,
                      staysBeside: staysBeside, keepsOpen: keepsOpen, selfDrawn: true, sections: sections)
    }
}

/// A colour to choose, and what choosing it does.
struct DocSwatch {
    let id: String
    let title: String
    let color: Color
    let isOn: Bool
    let perform: () -> Void
}

@MainActor
extension FlooMenuItem {
    /// Colours to choose one of. `title` is only said.
    static func docSwatches(_ title: String, _ swatches: [DocSwatch], well: FlooSwatches.Well? = nil, isEnabled: Bool = true) -> FlooMenuItem {
        .swatches(swatches.map { FlooSwatch(id: $0.id, title: $0.title, color: UIColor($0.color), isOn: $0.isOn) }, title: title, well: well, isEnabled: isEnabled) { chosen in
            swatches.first { $0.id == chosen.id }?.perform()
        }
    }

    /// A colour setting: its title, the colour it has, its palette a level in.
    static func docColor(_ title: String, picked: Color?, isEnabled: Bool = true, _ sections: [FlooMenuSection]) -> FlooMenuItem {
        .submenu(title, image: picked.map(DocColorDot.image), isEnabled: isEnabled, sections)
    }

    /// An option in the system's menu: its name, its colour's dot.
    static func docOption(_ name: String, color: Color, isOn: Bool, keepsOpen: Bool, action: @escaping @MainActor () -> Void) -> FlooMenuItem {
        .action(name, image: DocColorDot.image(color), isOn: isOn, keepsOpen: keepsOpen, handler: action)
    }

    /// Keys side by side, symbols alone, each on or off by what it acts on. `title` is only said.
    static func docKeys(_ title: String, _ keys: [FlooMenuTile]) -> FlooMenuItem {
        .tiles(keys, title: title)
    }
}

/// The dot a row of a colour shows: one image for each, so that the row's seen unchanged.
@MainActor
private enum DocColorDot {
    static var drawn: [String: UIImage] = [:]

    static func image(_ color: Color) -> UIImage {
        let key = color.description
        if let image = drawn[key] { return image }
        let side = FlooFormMetrics.isMacIdiom ? 16.0 : 22.0
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor(color).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        drawn[key] = image
        return image
    }
}
