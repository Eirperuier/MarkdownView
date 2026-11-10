//
//  MarkdownMathRenderer.swift
//  MarkdownUIKit
//
//  Formulas laid out and drawn by SwaTex: KaTeX's rules and fonts in Swift, no JavaScript, on
//  any thread, in tens of microseconds. A glyph KaTeX's fonts don't have (CJK, emoji) comes
//  from the system's fonts, so `\text{速度}` and bare CJK both draw. What comes out is an
//  image and where it sits on a baseline; a formula with no colours of its own is a template
//  that takes the role's colour as a tint.
//

import SwaTex
import SwaTexRender
import UIKit

/// A formula drawn.
struct MarkdownMathPiece: @unchecked Sendable {
    enum Kind: Hashable, Sendable {
        case inlineEquation
        case displayEquation
    }

    /// How the image gets its colour.
    enum Color: Hashable, Sendable {
        /// An alpha mask: a view tints it, so a dynamic colour follows the traits.
        case template
        /// It has colours of its own (`\color`): the rest is drawn in this `#RRGGBB`.
        case baked(foreground: String)
    }

    struct Metrics: Hashable, Sendable {
        /// Whole pixels; the room past the formula is on the right and at the top.
        let imageSize: CGSize
        /// How far above the text's baseline the image's bottom is: below it (negative) by
        /// the formula's depth in a line, 0 for a formula on its own.
        let baselineOffset: CGFloat
    }

    let kind: Kind
    /// As written, with its delimiters.
    let originalText: String
    /// Nil where it didn't parse: its source shows instead.
    let image: UIImage?
    let color: Color?
    let metrics: Metrics?
}

enum MarkdownMathRenderer {
    /// KaTeX Main-Regular's x-height in em: a formula's x-height is the text's.
    private static let katexXHeight: CGFloat = 0.43056

    private final class Box: NSObject {
        let piece: MarkdownMathPiece
        init(_ piece: MarkdownMathPiece) { self.piece = piece }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2048
        return cache
    }()

    /// `latex` as written, with or without its delimiters, which say how it's set.
    static func piece(latex: String, kind: MarkdownMathPiece.Kind, xHeight: CGFloat, foreground: String, scale: CGFloat) -> MarkdownMathPiece {
        let key = "\(kind == .displayEquation ? "D" : "I")|\(xHeight)|\(scale)|\(foreground)|\(latex)" as NSString
        if let known = cache.object(forKey: key) { return known.piece }
        let piece = make(latex: latex, kind: kind, xHeight: xHeight, foreground: foreground, scale: scale)
        cache.setObject(Box(piece), forKey: key)
        return piece
    }

    private static func make(latex: String, kind: MarkdownMathPiece.Kind, xHeight: CGFloat, foreground: String, scale: CGFloat) -> MarkdownMathPiece {
        let (body, isDisplay) = stripped(latex, kind: kind)
        let style: MathStyle = isDisplay ? .display : .text
        let failed = MarkdownMathPiece(kind: kind, originalText: latex, image: nil, color: nil, metrics: nil)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              var list = try? SwaTexEngine.displayList(for: body, style: style, color: .black, cache: FormulaCache.shared) else {
            return failed
        }
        // Colours of its own: everything else in the foreground, baked in.
        let hasOwnColors = list.items.contains { $0.color != .black }
        if hasOwnColors {
            guard let colored = try? SwaTexEngine.displayList(for: body, style: style, color: SwaTex.Color(hex: foreground) ?? .black, cache: FormulaCache.shared) else {
                return failed
            }
            list = colored
        }
        let em = xHeight / katexXHeight
        let options = RenderOptions(fontSize: em, padding: 0, backgroundColor: nil)
        guard let cgImage = ImageRenderer.image(for: list, options: options, displayScale: scale) else { return failed }
        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        return MarkdownMathPiece(
            kind: kind,
            originalText: latex,
            image: hasOwnColors ? image.withRenderingMode(.alwaysOriginal) : image.withRenderingMode(.alwaysTemplate),
            color: hasOwnColors ? .baked(foreground: foreground) : .template,
            metrics: .init(
                imageSize: image.size,
                baselineOffset: kind == .inlineEquation ? -CGFloat(list.depth) * em : 0
            )
        )
    }

    /// The TeX inside its delimiters, and whether they set it on its own.
    static func stripped(_ latex: String, kind: MarkdownMathPiece.Kind) -> (body: String, isDisplay: Bool) {
        let text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close, display) in [("$$", "$$", true), ("\\[", "\\]", true), ("\\(", "\\)", false), ("$", "$", false)]
        where text.count >= open.count + close.count && text.hasPrefix(open) && text.hasSuffix(close) {
            return (String(text.dropFirst(open.count).dropLast(close.count)), display)
        }
        return (text, kind == .displayEquation)
    }
}

private extension DisplayItem {
    var color: SwaTex.Color {
        switch self {
        case .glyphPath(_, _, _, _, _, let color): color
        case .line(_, _, _, _, let color, _): color
        case .rect(_, _, _, _, let color): color
        case .path(_, _, _, _, let color): color
        }
    }
}
