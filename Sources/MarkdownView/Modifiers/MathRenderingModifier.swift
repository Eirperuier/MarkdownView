//
//  MathRenderingModifier.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/2/24.
//

import SwiftUI

extension View {
    /// On macOS and iOS, parse and render math expression.
    ///
    /// - parameter enabled: A Boolean value that indicates whether to parse & render math expressions. The default value is true.
    nonisolated public func markdownMathRenderingEnabled(_ enabled: Bool = true) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.math.shouldRender = enabled
            if enabled {
                configuration.allowedBlockDirectiveRenderers.insert("math")
                BlockDirectiveRenderers.shared.addRenderer(
                    MathBlockDirectiveRenderer(),
                    for: "math"
                )
            }
        }
    }
    
    /// Provide pre-extracted inline math storage so that inline math
    /// placeholders inserted before cmark parsing can be resolved at render time.
    nonisolated public func markdownInlineMathStorage(_ storage: [String: String]?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.math.inlineMathStorage = storage
        }
    }

    /// Provide pre-extracted display (block) math storage so that
    /// `@math(uuid:…)` directives substituted before cmark parsing can be
    /// resolved at render time. Mirrors `markdownInlineMathStorage(_:)` for
    /// consumers that pre-process the source themselves instead of going
    /// through `MathFirstMarkdownViewRenderer`.
    nonisolated public func markdownDisplayMathStorage(_ storage: [UUID: String]?) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            if let storage {
                configuration.math.displayMathStorage = storage
            } else {
                configuration.math.displayMathStorage = nil
            }
        }
    }
}
