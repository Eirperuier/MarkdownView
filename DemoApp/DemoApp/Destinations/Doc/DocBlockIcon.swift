//
//  DocBlockIcon.swift
//  DemoApp
//
//  A block's kind drawn small (Craft's insert menu draws each its own, not a symbol): a
//  text style as its letters, a list as its rows, a quote as its bar, a block as its box,
//  a table as its cells, code as a dark slip with a green band, a formula as a formula,
//  a divider as its line, a page as a sheet; where an image or file comes from as its
//  place: a folder, a picture, the photos' flower, a camera, a scanner's corners (round
//  "abc" for Live Text). The command menu shows them in the icons' column, the + key's
//  system menu as images (`image`); what isn't a block (indenting, copying, a colour,
//  deleting) keeps its symbol.
//
//  Drawn on a canvas of the Mac's menu (22 × 18 points) and scaled to the menu's icon
//  size, in the content's colours, so they read in light and dark alike.
//

import SwiftUI

private typealias Tokens = DocTokens

struct DocBlockIcon: View {
    enum Glyph: Hashable {
        /// A text style's letters, at their size and weight.
        case letters(String, size: CGFloat, weight: Font.Weight)
        case bullets, numbers, tasks, toggles
        case quote, box
        case table
        case code
        case formula
        case divider
        case page
        case folder, image, photos, camera, scan, liveText
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
        case .folder:
            ZStack(alignment: .topLeading) {
                UnevenRoundedRectangle(cornerRadii: .init(topLeading: 1.5, topTrailing: 1.5), style: .continuous)
                    .fill(Self.folderBack)
                    .frame(width: 8, height: 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.folderBack)
                    .frame(width: 19, height: 12.5)
                    .offset(y: 1.8)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Self.folderFront)
                    .frame(width: 19, height: 11)
                    .offset(y: 4)
            }
            .frame(width: 19, height: 15, alignment: .topLeading)
        case .image:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Self.sky)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Self.sun).frame(width: 3.6, height: 3.6).padding(.top, 2.6).padding(.trailing, 3.2)
                }
                .overlay(alignment: .bottom) { Hills().fill(Self.hills) }
                .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .frame(width: 19, height: 14)
        case .photos:
            ZStack {
                ForEach(Self.petals.indices, id: \.self) { index in
                    Capsule()
                        .fill(Self.petals[index].opacity(0.85))
                        .frame(width: 4.6, height: 8)
                        .offset(y: -3.6)
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
            .frame(width: 16, height: 16)
        case .camera:
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(white: 0.22))
                .overlay(alignment: .topLeading) {
                    Capsule().fill(Color(white: 0.55)).frame(width: 3.5, height: 1.4).offset(x: 2.5, y: 1.8)
                }
                .overlay {
                    Circle().fill(Color(white: 0.08))
                        .overlay(Circle().strokeBorder(Color(white: 0.6), lineWidth: 1))
                        .overlay(Circle().fill(Color(red: 0.3, green: 0.45, blue: 0.9).opacity(0.8)).frame(width: 2.4, height: 2.4).offset(x: -0.8, y: -0.8))
                        .frame(width: 7.5, height: 7.5)
                }
                .frame(width: 19, height: 13)
        case .scan:
            ZStack {
                ScanCorners().stroke(Self.scanYellow, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 15)
                VStack(alignment: .leading, spacing: 2) { bar(9); bar(10); bar(6) }
            }
        case .liveText:
            ZStack {
                ScanCorners().stroke(Self.scanYellow, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 19, height: 13)
                Text("abc")
                    .font(.system(size: 6.5, weight: .semibold, design: .rounded).italic())
                    .foregroundStyle(ink)
                    .fixedSize()
            }
        }
    }

    private static let folderBack = Color(red: 0.16, green: 0.5, blue: 0.93)
    private static let folderFront = Color(red: 0.36, green: 0.67, blue: 1)
    private static let sky = Color(red: 0.42, green: 0.7, blue: 0.98)
    private static let sun = Color(red: 1, green: 0.85, blue: 0.3)
    private static let hills = Color(red: 0.25, green: 0.66, blue: 0.38)
    private static let scanYellow = Color(red: 0.98, green: 0.74, blue: 0.1)
    /// The photos' flower, clockwise from the top.
    private static let petals: [Color] = [
        Color(red: 0.98, green: 0.62, blue: 0.1), Color(red: 0.98, green: 0.82, blue: 0.15),
        Color(red: 0.55, green: 0.82, blue: 0.25), Color(red: 0.2, green: 0.72, blue: 0.55),
        Color(red: 0.25, green: 0.6, blue: 0.95), Color(red: 0.45, green: 0.4, blue: 0.9),
        Color(red: 0.75, green: 0.35, blue: 0.8), Color(red: 0.95, green: 0.3, blue: 0.4),
    ]

    /// A picture's hills: a low one, and a high one behind it.
    private struct Hills: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.3))
            path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.maxY - rect.height * 0.25),
                              control: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY - rect.height * 0.55))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.35),
                              control: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.maxY - rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    /// A scanner's four corners.
    private struct ScanCorners: Shape {
        func path(in rect: CGRect) -> Path {
            let arm: CGFloat = 4
            var path = Path()
            for (corner, x, y) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
                                   (CGPoint(x: rect.minX, y: rect.maxY), 1, -1), (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1)] {
                path.move(to: CGPoint(x: corner.x, y: corner.y + arm * y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x + arm * x, y: corner.y))
            }
            return path
        }
    }

    /// The drawing as an image for a system menu, at the screen's scale, in light and dark
    /// alike (an image asset of both), its colours its own.
    static func image(_ glyph: Glyph) -> UIImage {
        if let image = images[glyph] { return image }
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let renderer = ImageRenderer(content: DocBlockIcon(glyph: glyph).environment(\.colorScheme, style == .dark ? .dark : .light))
            renderer.scale = 3
            guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { continue }
            asset.register(image, with: UITraitCollection(userInterfaceStyle: style))
        }
        let image = asset.image(with: UITraitCollection.current)
        images[glyph] = image
        return image
    }

    private static var images: [Glyph: UIImage] = [:]

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
        if let glyph = command.glyph { return glyph }
        return switch command.id {
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
