//
//  MarkdownTextScale.swift
//  MarkdownView
//
//  How much larger than the system's text styles MarkdownView draws its text. On the Mac
//  the text styles are a control's size (body 13 points) and a document reads small in
//  them; Craft's Mac text, measured against them, is body text 1.16 times, headings 1.24
//  times. Elsewhere the text styles are the text's size.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public enum MarkdownTextScale {
    #if targetEnvironment(macCatalyst) || os(macOS)
    /// Body text, and everything sized as body text is (code, tables, captions).
    public static let body: CGFloat = 1.16
    /// Headings set in the title styles.
    public static let headings: CGFloat = 1.24
    #else
    public static let body: CGFloat = 1
    public static let headings: CGFloat = 1
    #endif

    #if canImport(UIKit)
    public typealias TextStyle = UIFont.TextStyle
    #else
    public typealias TextStyle = NSFont.TextStyle
    #endif

    /// The scale of a text style's text: the title styles a heading's, the rest body text's.
    public static func factor(for style: TextStyle) -> CGFloat {
        switch style {
        case .largeTitle, .title1, .title2, .title3: headings
        default: body
        }
    }

    /// A text style's size at MarkdownView's scale.
    public static func size(of style: TextStyle) -> CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: style).pointSize * factor(for: style)
        #else
        NSFont.preferredFont(forTextStyle: style).pointSize * factor(for: style)
        #endif
    }
}

extension Font {
    /// `font`, a text style's, at MarkdownView's scale: itself where the scale is 1 (it keeps
    /// following Dynamic Type), else the system font at the scaled size.
    static func markdownScaled(_ font: Font, _ style: MarkdownTextScale.TextStyle,
                               weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard MarkdownTextScale.factor(for: style) != 1 else { return font }
        return .system(size: MarkdownTextScale.size(of: style), weight: weight, design: design)
    }
}
