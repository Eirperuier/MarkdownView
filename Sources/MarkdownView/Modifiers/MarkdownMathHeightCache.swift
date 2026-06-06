//
//  MarkdownMathHeightCache.swift
//  MarkdownView
//

import SwiftUI

/// External cache that maps a LaTeX source string to its previously
/// measured rendered height. `MarkdownDisplayMath` consults the cache to
/// reserve the right amount of vertical space on the very first frame and
/// avoid the empty-placeholder → rendered-SVG height jump that is
/// otherwise unavoidable with an async LaTeX renderer.
///
/// The cache contract is intentionally minimal: a single key (the LaTeX
/// string as it would be passed to the rendering engine, delimiters
/// included) maps to a single height value. Callers are responsible for
/// thread safety and for any persistence semantics (in-memory only,
/// disk-backed, scoped to font size, etc.).
public protocol MarkdownMathHeightCache: AnyObject, Sendable {
    func height(forLatex latex: String) -> CGFloat?
    func setHeight(_ height: CGFloat, forLatex latex: String)
}

private struct MarkdownMathHeightCacheKey: EnvironmentKey {
    static let defaultValue: (any MarkdownMathHeightCache)? = nil
}

extension EnvironmentValues {
    var markdownMathHeightCache: (any MarkdownMathHeightCache)? {
        get { self[MarkdownMathHeightCacheKey.self] }
        set { self[MarkdownMathHeightCacheKey.self] = newValue }
    }
}

extension View {
    /// Inject a cache that maps LaTeX strings to their previously-measured
    /// rendered heights. `MarkdownDisplayMath` uses the cached value as the
    /// frame's reserved minimum, so any formula that has been laid out
    /// before (across launches if the cache is persistent) renders at its
    /// final height from the very first frame.
    nonisolated public func markdownMathHeightCache(
        _ cache: (any MarkdownMathHeightCache)?
    ) -> some View {
        environment(\.markdownMathHeightCache, cache)
    }
}
