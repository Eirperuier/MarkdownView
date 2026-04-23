import SwiftUI

struct MarkdownNodeView: View {
    private var storage: Either<AttributedString, AnyView>

    /// Byte offset of this text segment within the block's concatenated plain text.
    /// Used by `RevealAnimatedMarkdownText` to compute per-segment reveal progress.
    private(set) var blockTextOffset: Int = 0
    
    enum ContentType: String {
        case text, view
    }
    var contentType: ContentType {
        switch storage {
        case .left(_): .text
        case .right(_): .view
        }
    }
    
    init(_ text: AttributedString) {
        self.storage = .left(text)
    }
    
    init(_ text: AttributedSubstring) {
        self.storage = .left(AttributedString(text))
    }
    
    init(_ text: String) {
        self.storage = .left(AttributedString(text))
    }

    private init(_ text: AttributedString, blockTextOffset: Int) {
        self.storage = .left(text)
        self.blockTextOffset = blockTextOffset
    }
    
    init<Content: View>(@ViewBuilder _ content: () -> Content) {
        let content = content()
        if let markdownNode = content as? MarkdownNodeView {
            storage = markdownNode.storage
            blockTextOffset = markdownNode.blockTextOffset
        } else {
            storage = .right(AnyView(content))
        }
    }
    
    var body: some View {
        Group {
            if case .left(let attributedString) = storage {
                _MarkdownText(attributedString, blockTextOffset: blockTextOffset)
            } else if case .right(let view) = storage {
                view
                    
            }
        }
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    var asAttributedString: AttributedString? {
        if case .left(let attributedString) = storage {
            return attributedString
        }
        return nil
    }
}

extension MarkdownNodeView {
    enum LayoutPolicy {
        case adaptive
        case linebreak
    }
    
    /// Combine adjacent views of the same type.
    /// - Parameter contents: A set of contents to combine together.
    /// - Parameter alignment: The alignment in relation to these contents.
    init(
        _ contents: [MarkdownNodeView],
        alignment: HorizontalAlignment = .leading,
        layoutPolicy: LayoutPolicy = .adaptive
    ) {
        var composedContents = [MarkdownNodeView]()
        var attributedString = AttributedString()
        var runningOffset = 0
        var segmentStartOffset = 0

        for content in contents {
            if case .left(let text) = content.storage {
                if layoutPolicy == .linebreak && !attributedString.characters.isEmpty {
                    attributedString += "\n\n"
                    runningOffset += 2
                }
                attributedString += text
                runningOffset += text.characters.count
            } else {
                if !attributedString.characters.isEmpty {
                    composedContents.append(MarkdownNodeView(attributedString, blockTextOffset: segmentStartOffset))
                    attributedString = AttributedString()
                }
                composedContents.append(content)
                segmentStartOffset = runningOffset
            }
        }
        if !attributedString.characters.isEmpty {
            composedContents.append(MarkdownNodeView(attributedString, blockTextOffset: segmentStartOffset))
        }
        
        if composedContents.count == 1 {
            if let attributedString = composedContents[0].asAttributedString {
                storage = .left(attributedString)
                blockTextOffset = composedContents[0].blockTextOffset
            } else {
                storage = .right(AnyView(composedContents[0].body))
            }
        } else {
            if layoutPolicy == .adaptive,
               #available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
            {
                let composedView = FlowLayout(verticleSpacing: 8) {
                    ForEach(composedContents.indices, id: \.self) {
                        composedContents[$0].body
                    }
                }
                storage = .right(AnyView(composedView))
            } else {
                let composedView = VStack(alignment: alignment, spacing: 8) {
                    ForEach(composedContents.indices, id: \.self) {
                        composedContents[$0].body
                    }
                }
                storage = .right(AnyView(composedView))
            }
        }
    }
}
