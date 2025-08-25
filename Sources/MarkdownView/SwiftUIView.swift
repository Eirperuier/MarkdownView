//
//  SharedHighlighter.swift
//  MarkdownView
//

import Foundation

#if canImport(Highlightr)
import Highlightr

final class SharedHighlighter: @unchecked Sendable {
    static let shared = SharedHighlighter()
    
    private let highlightr = Highlightr()!
    private var lastTheme: String?
    private let queue = DispatchQueue(label: "highlighter", qos: .userInitiated)
    
    private init() {}
    
    func highlight(_ code: String, language: String?, themeName: String) async -> NSAttributedString? {
        return await withCheckedContinuation { continuation in
            queue.async {
                // 只在主题变化时更新
                if self.lastTheme != themeName {
                    self.highlightr.setTheme(to: themeName)
                    self.lastTheme = themeName
                }
                
                let result = self.highlightr.highlight(code, as: language?.lowercased())
                continuation.resume(returning: result)
            }
        }
    }
    
    func supportedLanguages() -> [String] {
        return highlightr.supportedLanguages()
    }
}
#endif
