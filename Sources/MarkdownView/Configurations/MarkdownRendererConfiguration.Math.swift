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
            // 关键:id 必须由公式内容决定(而非随机 UUID)。流式每 append 都会对整篇重跑 preprocessMath,
            // 随机 UUID 会让占位符文本逐帧变化 → 含公式的 block 的 stableContentHash 每帧变 → 顶层 block 缓存永远 miss
            // → 每帧重 visit + 重拼 + 重建 attachment(严重卡顿 + 布局抽搐)。内容确定 id → 占位符逐帧稳定 → 缓存命中。
            let id = Self.deterministicUUID(displayMath)
            displayMathStorage![id] = String(displayMath)
            return id
        }

        mutating func appendInlineMath(_ inlineMath: some StringProtocol) -> String {
            if inlineMathStorage == nil {
                inlineMathStorage = [:]
            }
            let id = Self.stableHashHex(inlineMath)  // 同上:内容确定 id,占位符逐帧稳定 → block 缓存可命中
            inlineMathStorage![id] = String(inlineMath)
            return id
        }

        static let inlinePlaceholderPrefix = "\u{2E28}imath:"
        static let inlinePlaceholderSuffix = "\u{2E29}"

        /// FNV-1a 64-bit → hex(仅 0-9a-f,cmark 安全;进程内确定)。同一公式恒得同 id → 占位符稳定。
        private static func stableHashHex(_ s: some StringProtocol) -> String {
            var h: UInt64 = 0xcbf29ce484222325
            for b in String(s).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return String(h, radix: 16)
        }

        /// 由公式内容确定地派生 128-bit UUID(两趟不同 seed 的 FNV-1a 拼成 16 字节)。
        private static func deterministicUUID(_ s: some StringProtocol) -> UUID {
            let bytes = Array(String(s).utf8)
            func fnv(_ seed: UInt64) -> UInt64 {
                var h = seed
                for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
                return h
            }
            let h1 = fnv(0xcbf29ce484222325), h2 = fnv(0x84222325cbf29ce4)
            func byte(_ v: UInt64, _ i: Int) -> UInt8 { UInt8((v >> (UInt64(i) * 8)) & 0xff) }
            let u: uuid_t = (
                byte(h1, 0), byte(h1, 1), byte(h1, 2), byte(h1, 3),
                byte(h1, 4), byte(h1, 5), byte(h1, 6), byte(h1, 7),
                byte(h2, 0), byte(h2, 1), byte(h2, 2), byte(h2, 3),
                byte(h2, 4), byte(h2, 5), byte(h2, 6), byte(h2, 7)
            )
            return UUID(uuid: u)
        }
    }
}
