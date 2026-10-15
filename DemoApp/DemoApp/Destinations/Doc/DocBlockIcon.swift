//
//  DocBlockIcon.swift
//  DemoApp
//
//  A block's kind drawn small (Craft's insert menu draws each its own, not a symbol): a
//  text style as its letters, a list as its rows, a quote as its bar, a block as its box,
//  a table as its cells, code as a dark slip with a green band, a formula as a formula,
//  a divider as its line, a page as a sheet. The command menu shows them in the icons'
//  column; what isn't a block (indenting, copying, a colour, deleting) keeps its symbol.
//
//  Drawn on a canvas of the Mac's menu (22 × 18 points) and scaled to the menu's icon
//  size, in the content's colours, so they read in light and dark alike.
//

import SwiftUI
import FlooDesign

private typealias Tokens = FlooDesignTokens

struct DocBlockIcon: View {
    enum Glyph: Equatable {
        /// A text style's letters, at their size and weight.
        case letters(String, size: CGFloat, weight: Font.Weight)
        case bullets, numbers, tasks, toggles
        case quote, box
        case table
        case code
        case formula
        case divider
        case page
    }

    let glyph: Glyph

    /// The canvas, and the menu's icon size it's drawn for.
    private static let canvas = CGSize(width: 22, height: 18)
    private static let drawnFor: CGFloat = 14

    var body: some View {
        let scale = Tokens.Component.Menu.iconSize / Self.drawnFor
        drawing
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .scaleEffect(scale)
            .frame(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
            .accessibilityHidden(true)
    }

    private var ink: Color { Tokens.ColorRole.Content.secondary }
    private var faint: Color { Tokens.ColorRole.Content.tertiary }

    @ViewBuilder
    private var drawing: some View {
        switch glyph {
        case .letters(let letters, let size, let weight):
            Text(letters)
                .font(.system(size: size, weight: weight, design: .rounded))
                .foregroundStyle(ink)
                .fixedSize()
        case .bullets:
            rows { _ in Circle().fill(ink).frame(width: 3, height: 3) }
        case .numbers:
            rows { index in
                Text("\(index + 1)")
                    .font(.system(size: 5.5, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .frame(width: 4)
            }
        case .tasks:
            rows { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .strokeBorder(ink, lineWidth: 0.9)
                    .background(index == 0 ? RoundedRectangle(cornerRadius: 1, style: .continuous).fill(ink) : nil)
                    .frame(width: 4, height: 4)
            }
        case .toggles:
            VStack(alignment: .leading, spacing: 2.5) {
                line(marker: Image(systemName: "arrowtriangle.right.fill").font(.system(size: 5)).foregroundStyle(ink).frame(width: 4), width: 11)
                line(marker: Color.clear.frame(width: 4), width: 9).padding(.leading, 4)
                line(marker: Image(systemName: "arrowtriangle.right.fill").font(.system(size: 5)).foregroundStyle(ink).frame(width: 4), width: 11)
            }
        case .quote:
            HStack(spacing: 2.5) {
                Capsule().fill(ink).frame(width: 1.8, height: 13)
                VStack(alignment: .leading, spacing: 2.5) {
                    bar(13); bar(10); bar(12)
                }
            }
        case .box:
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Tokens.ColorRole.Surface.control)
                .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(faint, lineWidth: 0.6))
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 2.5) { bar(10); bar(7) }.padding(.leading, 3.5)
                }
                .frame(width: 19, height: 14)
        case .table:
            VStack(spacing: 1) {
                ForEach(0..<3) { row in
                    HStack(spacing: 1) {
                        ForEach(0..<3) { _ in
                            RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                                .fill(row == 0 ? ink : faint)
                                .frame(width: 5.5, height: 3.8)
                        }
                    }
                }
            }
            .padding(1)
            .background(RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Tokens.ColorRole.Surface.control))
        case .code:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(white: 0.16))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color(white: 0.32), lineWidth: 0.6))
                .overlay {
                    HStack(spacing: 2) {
                        Capsule().fill(.white.opacity(0.85)).frame(width: 2.5, height: 0.9)
                        Text("</>")
                            .font(.system(size: 4.6, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 5.5)
                    .background(Color(red: 0.16, green: 0.66, blue: 0.36))
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(width: 19, height: 13)
        case .formula:
            Text("√14·9")
                .font(.system(size: 6.5, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .fixedSize()
        case .divider:
            Capsule().fill(ink).frame(width: 17, height: 1.4)
        case .page:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Tokens.ColorRole.Surface.control)
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(faint, lineWidth: 0.6))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 1.6) { bar(5, thickness: 1.1); bar(3.5, thickness: 1.1) }
                        .padding(.top, 3).padding(.leading, 2.5)
                }
                .frame(width: 12.5, height: 16)
        }
    }

    /// Three rows of a list: a marker and a line each.
    private func rows<Marker: View>(@ViewBuilder marker: @escaping (Int) -> Marker) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            ForEach(0..<3) { index in line(marker: marker(index), width: index == 1 ? 9 : 11) }
        }
    }

    private func line<Marker: View>(marker: Marker, width: CGFloat) -> some View {
        HStack(spacing: 2.5) {
            marker
            bar(width)
        }
    }

    private func bar(_ width: CGFloat, thickness: CGFloat = 1.5) -> some View {
        Capsule().fill(ink).frame(width: width, height: thickness)
    }
}

extension DocBlockIcon.Glyph {
    /// A command's drawing, if it makes a block or opens a group of them.
    static func of(_ command: DocCommand) -> Self? {
        switch command.id {
        case "list", "bullet": .bullets
        case "numbered": .numbers
        case "task": .tasks
        case "toggle": .toggles
        case "style", "h1": .letters("H1", size: 10.5, weight: .bold)
        case "h2": .letters("H2", size: 9.5, weight: .bold)
        case "h3": .letters("H3", size: 8.5, weight: .bold)
        case "h4": .letters("B", size: 11, weight: .heavy)
        case "paragraph": .letters("Aa", size: 10.5, weight: .regular)
        case "caption": .letters("Aa", size: 8, weight: .regular)
        case "decorations", "quote": .quote
        case "box": .box
        case "table": .table
        case "code": .code
        case "math": .formula
        case "divider": .divider
        case "page": .page
        default: command.id.hasPrefix("table-") ? .table : nil
        }
    }
}
