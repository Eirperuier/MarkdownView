//
//  MarkdownRendererConfiguration.Math.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/16.
//

import Foundation

extension MarkdownRendererConfiguration {
    struct Math: Sendable, Hashable {
        var shouldRender: Bool {
            get { displayMathStorage != nil }
            set(enabled) {
                if enabled {
                    // Only initialize if absent — preserves any pre-populated
                    // storage (e.g. `markdownDisplayMathStorage(_:)` from a
                    // caller that pre-extracts block math itself).
                    if displayMathStorage == nil {
                        displayMathStorage = [:]
                    }
                } else {
                    displayMathStorage = nil
                }
            }
        }
        var displayMathStorage: [UUID : String]? = nil
        var inlineMathStorage: [String : String]? = nil
        
        mutating func appendDisplayMath(_ displayMath: some StringProtocol) -> UUID {
            if displayMathStorage == nil {
                displayMathStorage = [:]
            }
            
            let id = UUID()
            displayMathStorage![id] = String(displayMath)
            return id
        }
        
        mutating func appendInlineMath(_ inlineMath: some StringProtocol) -> String {
            if inlineMathStorage == nil {
                inlineMathStorage = [:]
            }
            let id = UUID().uuidString
            inlineMathStorage![id] = String(inlineMath)
            return id
        }
        
        static let inlinePlaceholderPrefix = "\u{2E28}imath:"
        static let inlinePlaceholderSuffix = "\u{2E29}"
    }
}
