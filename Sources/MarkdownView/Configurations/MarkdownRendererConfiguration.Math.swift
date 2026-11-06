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
        /// Display math renders on first layout instead of appearing empty and growing.
        var rendersDisplayMathSynchronously = false
        
        mutating func appendDisplayMath(_ displayMath: some StringProtocol) -> UUID {
            if displayMathStorage == nil {
                displayMathStorage = [:]
            }
            // 关键:id 必须由公式内容决定(而非随机 UUID)。流式每 append 都会对整篇重跑 preprocessMath,
            // 随机 UUID 会让占位符文本逐帧变化 → 含公式的 block 的 stableContentHash 每帧变 → 顶层 block 缓存永远 miss
            // → 每帧重 visit + 重拼 + 重建 attachment(严重卡顿 + 布局抽搐)。内容确定 id → 占位符逐帧稳定 → 缓存命中。
            let id = MarkdownMathPreprocessor.displayID(for: displayMath)
            displayMathStorage![id] = String(displayMath)
            return id
        }

        mutating func appendInlineMath(_ inlineMath: some StringProtocol) -> String {
            if inlineMathStorage == nil {
                inlineMathStorage = [:]
            }
            let id = MarkdownMathPreprocessor.inlineID(for: inlineMath)  // 同上:内容确定 id,占位符逐帧稳定 → block 缓存可命中
            inlineMathStorage![id] = String(inlineMath)
            return id
        }

        static let inlinePlaceholderPrefix = MarkdownInlineMathPlaceholder.prefix
        static let inlinePlaceholderSuffix = MarkdownInlineMathPlaceholder.suffix
    }
}
