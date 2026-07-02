//
//  MathParser.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/2/24.
//

import SwiftUI
#if canImport(LaTeXSwiftUI)
import LaTeXSwiftUI
import MathJaxSwift
#endif

/*
 Credits to colinc86/LaTeXSwiftUI
 */
@_spi(MarkdownMath)
public struct MathParser {
    public var text: any StringProtocol
    
    public init(text: some StringProtocol) {
        self.text = text
    }
    
    public var mathRepresentations: [MathRepresentation] {
        var stack = [MathRepresentation.Kind]()
        var index = text.startIndex
        var startIndex = index
        var endIndex = index
        var representations: [MathRepresentation] = []
        
        inputLoop: while index < text.endIndex {
            let remaining = text[index...]
            
            if !stack.isEmpty {
                for type in MathRepresentation.Kind.allCases {
                    let end = type.rightTerminator
                    if remaining.hasPrefix(end) {
                        if index > text.startIndex && text[text.index(before: index)] == "\\" {
                            index = text.index(index, offsetBy: end.count)
                            continue inputLoop
                        }
                        
                        endIndex = text.index(index, offsetBy: end.count)
                        
                        if stack.last == type {
                            stack.removeLast()
                            
                            if stack.isEmpty {
                                let range = startIndex..<endIndex
                                if type.hasRenderableContent(in: text, range: range) {
                                    representations.append(
                                        MathRepresentation(
                                            kind: type,
                                            range: range
                                        )
                                    )
                                }
                            }
                        }
                        index = endIndex
                        continue inputLoop
                    }
                }
            }
            
            for type in MathRepresentation.Kind.allCases {
                let start = type.leftTerminator
                if remaining.hasPrefix(start) {
                    if index > text.startIndex && text[text.index(before: index)] == "\\" {
                        index = text.index(index, offsetBy: start.count)
                        continue inputLoop
                    }
                    
                    if stack.isEmpty {
                        startIndex = index
                    }
                    
                    stack.append(type)
                    index = text.index(index, offsetBy: start.count)
                    continue inputLoop
                }
            }
            
            index = text.index(after: index)
        }
        
        return representations
    }
}

extension MathParser {
    public struct MathRepresentation: Sendable, Hashable {
        public var kind: Kind
        public var range: Range<String.Index>
    }

    static func standaloneDisplayMath(
        in text: String,
        unescapingCommonMarkEscapes: Bool = false
    ) -> String? {
        let source = unescapingCommonMarkEscapes
            ? commonMarkUnescapedMathSource(text)
            : text
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let mathRepresentations = MathParser(text: trimmed).mathRepresentations
        guard mathRepresentations.count == 1,
              let math = mathRepresentations.first,
              !math.kind.inline,
              math.range.lowerBound == trimmed.startIndex,
              math.range.upperBound == trimmed.endIndex
        else {
            return nil
        }

        return String(trimmed[math.range])
    }

    static func containsExplicitColorCommand(in latex: String) -> Bool {
        [
            #"\color"#,
            #"\textcolor"#,
            #"\definecolor"#,
            #"\colorbox"#,
            #"\fcolorbox"#,
        ].contains { latex.contains($0) }
    }

    private static func commonMarkUnescapedMathSource(_ text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\\" {
                let nextIndex = text.index(after: index)

                if nextIndex < text.endIndex {
                    let nextCharacter = text[nextIndex]

                    if nextCharacter == "\\" {
                        let afterNextIndex = text.index(after: nextIndex)
                        if afterNextIndex < text.endIndex,
                           isASCIIControlWordLetter(text[afterNextIndex]) {
                            result.append("\\")
                            index = afterNextIndex
                            continue
                        }
                    } else if nextCharacter == "_" {
                        result.append("_")
                        index = text.index(after: nextIndex)
                        continue
                    }
                }
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func isASCIIControlWordLetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else {
            return false
        }

        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

extension MathParser.MathRepresentation {
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// An inline equation component.
        ///
        /// - Example: `$x^2$`
        case inlineEquation
        
        /// An inline equation component.
        ///
        /// - Example: `\(x^2\)`
        case inlineParenthesesEquation
        
        /// A TeX-style block equation.
        ///
        /// - Example: `$$x^2$$`.
        case texEquation
        
        /// A block equation.
        ///
        /// - Example: `\[x^2\]`
        case blockEquation
        
        /// A named equation component.
        ///
        /// - Example: `\begin{equation}x^2\end{equation}`
        case namedEquation
        
        /// A named equation component.
        ///
        /// - Example: `\begin{equation*}x^2\end{equation*}`
        case namedNoNumberEquation
        
        /// The component's left terminator.
        var leftTerminator: String {
            switch self {
            case .inlineEquation: return "$"
            case .inlineParenthesesEquation: return "\\("
            case .texEquation: return "$$"
            case .blockEquation: return "\\["
            case .namedEquation: return "\\begin{equation}"
            case .namedNoNumberEquation: return "\\begin{equation*}"
            }
        }
        
        /// The component's right terminator.
        var rightTerminator: String {
            switch self {
            case .inlineEquation: return "$"
            case .inlineParenthesesEquation: return "\\)"
            case .texEquation: return "$$"
            case .blockEquation: return "\\]"
            case .namedEquation: return "\\end{equation}"
            case .namedNoNumberEquation: return "\\end{equation*}"
            }
        }
        
        /// Whether or not this component is inline.
        @_spi(MarkdownMath)
        public var inline: Bool {
            switch self {
            case .inlineEquation, .inlineParenthesesEquation: return true
            default: return false
            }
        }

        func hasRenderableContent(
            in text: any StringProtocol,
            range: Range<String.Index>
        ) -> Bool {
            let contentStart = text.index(
                range.lowerBound,
                offsetBy: leftTerminator.count
            )
            let contentEnd = text.index(
                range.upperBound,
                offsetBy: -rightTerminator.count
            )
            guard contentStart < contentEnd else { return false }

            // 单 `$…$` 行内公式:紧邻定界符不得是空白(标准 KaTeX/markdown-it 规则),
            // 用来把货币「$5 and $10」这类误配挡掉(闭合 `$` 前是空格 → 不算公式),同时不会误伤合法公式
            //(合法公式内容边缘不会是空格)。`$$`/`\(\)`/`\[\]` 无此歧义,不加此约束。
            if self == .inlineEquation {
                let first = text[contentStart]
                let last = text[text.index(before: contentEnd)]
                if first.isWhitespace || last.isWhitespace { return false }
            }

            let content = text[contentStart..<contentEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !content.isEmpty
        }

        // 顺序即匹配优先级:`.texEquation`($$)必须排在 `.inlineEquation`($)之前,
        // 否则 `$$…$$` 会被单 `$` 先匹配成空行内公式。`.inlineEquation` 放最后。
        public static let allCases: [Kind] = [
            .namedNoNumberEquation,
            .namedEquation,
            .blockEquation,
            .texEquation,
            .inlineParenthesesEquation,
            .inlineEquation,
        ]
    }
}
