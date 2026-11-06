//
//  DocPanels.swift
//  DemoApp
//
//  The document's panels, on floo-uikit's floating panel: beside what opened them on a
//  large screen and the Mac, the system's sheet on a small one.
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
            content: content
        )
    }

    /// A panel's width: its own beside what opened it, the sheet's in a sheet.
    func docPanelWidth(_ width: CGFloat, alignment: Alignment = .center) -> some View {
        modifier(DocPanelWidth(width: width, alignment: alignment))
    }

    /// Sizes the sheet this content is in to the content, the page behind staying usable
    /// (a tool's sheet). `estimate`: its height until it's measured.
    func docSizedSheet(estimate: CGFloat) -> some View {
        modifier(DocSizedSheet(height: estimate))
    }
}

private struct DocPanelWidth: ViewModifier {
    let width: CGFloat
    let alignment: Alignment
    @Environment(\.flooPanelPresentation) private var presentation

    func body(content: Content) -> some View {
        if presentation == .sheet {
            content.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            content.frame(width: width, alignment: alignment)
        }
    }
}

/// A panel's content, its margins from the panel's edges; in a sheet the sheet has them.
struct DocPanelSurface<Content: View>: View {
    private let contentInset: EdgeInsets
    private let content: Content
    @Environment(\.flooPanelPresentation) private var presentation

    init(contentInset: EdgeInsets = EdgeInsets(top: DocTokens.Space.md, leading: DocTokens.Space.sm,
                                               bottom: DocTokens.Space.md, trailing: DocTokens.Space.sm),
         @ViewBuilder content: () -> Content) {
        self.contentInset = contentInset
        self.content = content()
    }

    var body: some View {
        if presentation == .sheet {
            content
        } else {
            content.padding(contentInset)
        }
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
