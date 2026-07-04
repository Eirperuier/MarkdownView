//
//  Markup.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Markdown

extension Markup {
    var hasSuccessor: Bool {
        guard let childCount = parent?.childCount else { return false }
        return indexInParent < childCount - 1
    }
    
    var isContainedInList: Bool {
        var currentElement = parent

        while currentElement != nil {
            if currentElement is ListItemContainer {
                return true
            }

            currentElement = currentElement?.parent
        }
        
        return false
    }
}

// MARK: - Content-Based Hashing for Stable View Identity

extension Markup {
    /// A stable hash based on the content and structure of this markup node.
    /// Remains consistent across re-parses when the content is unchanged,
    /// enabling efficient AST diff and view caching during streaming updates.
    var stableContentHash: Int {
        var hasher = Hasher()
        hasher.combine(String(describing: type(of: self)))
        _hashNodeContent(into: &hasher)
        hasher.combine(childCount)
        for child in children {
            hasher.combine(child.stableContentHash)
        }
        return hasher.finalize()
    }

    private func _hashNodeContent(into hasher: inout Hasher) {
        switch self {
        case let text as Markdown.Text:
            hasher.combine(text.string)
        case let code as InlineCode:
            hasher.combine(code.code)
        case let codeBlock as CodeBlock:
            hasher.combine(codeBlock.code)
            hasher.combine(codeBlock.language)
        case let heading as Heading:
            hasher.combine(heading.level)
        case let link as Markdown.Link:
            hasher.combine(link.destination)
        case let image as Markdown.Image:
            hasher.combine(image.source)
            hasher.combine(image.title)
        case let html as HTMLBlock:
            hasher.combine(html.rawHTML)
        case let inlineHTML as InlineHTML:
            hasher.combine(inlineHTML.rawHTML)
        case let ordered as OrderedList:
            hasher.combine(ordered.startIndex)
        case let listItem as ListItem:
            hasher.combine(listItem.checkbox)
        case let directive as BlockDirective:
            // 指令名+参数必须入哈希:@math(uuid:A) 与 @math(uuid:B) 曾同 hash,
            // _resolveChild 的按-hash 兜底永远命中第一条 → 多条公式全渲染成同一条。
            hasher.combine(directive.name)
            for segment in directive.argumentText.segments {
                hasher.combine(segment.trimmedText)
            }
        default:
            break
        }
    }
}
