import SwiftUI

/// A type that applies font group to all MarkdownViews within a view hierarchy.
///
/// To configure the current font group for a view hierarchy, use ``MarkdownView/MarkdownView/fontGroup(_:)`` modifier. Specify a font group that conforms to MarkdownFontGroup when creating a MarkdownView.
public protocol MarkdownFontGroup {
    // Headings
    var h1: Font { get }
    var h2: Font { get }
    var h3: Font { get }
    var h4: Font { get }
    var h5: Font { get }
    var h6: Font { get }
    
    // Normal text
    var body: Font { get }
    
    // Blocks
    var codeBlock: Font { get }
    var blockQuote: Font { get }
    
    // Tables
    var tableHeader: Font { get }
    var tableBody: Font { get }
    
    // Math
    var inlineMath: Font { get }
    var displayMath: Font { get }
}
func sfCompactFont(forTextStyle style: UIFont.TextStyle, weight: String = "Regular") -> UIFont {
    let baseSize = UIFont.preferredFont(forTextStyle: style).pointSize * MarkdownTextScale.factor(for: style)
    guard let baseFont = UIFont(name: "SFCompactText-\(weight)", size: baseSize) else {
        return UIFont.preferredFont(forTextStyle: style).withSize(baseSize)
    }
    return UIFontMetrics(forTextStyle: style).scaledFont(for: baseFont)
}

/// The text styles at MarkdownView's scale (MarkdownTextScale).
extension MarkdownFontGroup {
    public var h1: Font { .markdownScaled(.title, .title1) }
    public var h2: Font { .markdownScaled(.title2, .title2) }
    public var h3: Font { .markdownScaled(.title3, .title3) }
    public var h4: Font { .markdownScaled(.headline, .headline, weight: .semibold) }
    public var h5: Font { .markdownScaled(.headline, .headline, weight: .semibold) }
    public var h6: Font { .markdownScaled(Font.headline.weight(.regular), .headline) }
    
    // Normal text
    public var body: Font { .markdownScaled(.body, .body) }
    
    // Blocks
    public var codeBlock: Font { .markdownScaled(Font.system(.caption, design: .monospaced), .caption1, design: .monospaced) }
    public var blockQuote: Font { .markdownScaled(Font.system(.body, design: .serif), .body, design: .serif) }
    
    // Tables
    public var tableHeader: Font { Font(sfCompactFont(forTextStyle: .subheadline)).weight(.bold) }
    public var tableBody: Font { .markdownScaled(.body, .body) }
    
    // Math
    public var inlineMath: Font { .markdownScaled(.body, .body) }
    public var displayMath: Font { .markdownScaled(.body, .body) }
}

// MARK: - Environment Values

struct MarkdownFontGroupEnvironmentKey: EnvironmentKey {
    static let defaultValue: AnyMarkdownFontGroup = .init(.automatic)
}

extension EnvironmentValues {
    var markdownFontGroup: AnyMarkdownFontGroup {
        get { self[MarkdownFontGroupEnvironmentKey.self] }
        set { self[MarkdownFontGroupEnvironmentKey.self] = newValue }
    }
}
