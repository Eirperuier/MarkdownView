//
//  TextComposer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/22.
//

import SwiftUI

struct TextComposer {
    private var _string: String = ""
    private var _combinedText: Text? = nil
    
    var text: Text {
        if let combinedText = _combinedText {
            return combinedText
        } else {
            return Text(verbatim: _string)
        }
    }
    private(set) var hasText: Bool = false
    
    init(@TextBuilder text: @escaping () -> Text) {
        self._combinedText = text()
        self.hasText = true
    }
    
    init() {
        
    }
    
    mutating func append(_ text: Text) {
        hasText = true
        
        if let existingText = _combinedText {
            // 如果已经有组合文本，使用 + 操作符保持样式
            _combinedText = existingText + text
        } else if !_string.isEmpty {
            // 如果有字符串缓存，先转换为 Text 再组合
            _combinedText = Text(verbatim: _string) + text
            _string = "" // 清空字符串缓存
        } else {
            // 第一次添加文本
            _combinedText = text
        }
    }
    
    // 保留原有的方法用于向后兼容
    mutating func appendPlainText(_ string: String) {
        hasText = true
        if let existingText = _combinedText {
            _combinedText = existingText + Text(verbatim: string)
        } else {
            _string += string
        }
    }
    
    static private func resolveText(_ text: Text) -> String {
        text._resolveText(in: EnvironmentValues())
    }
}
