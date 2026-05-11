//
//  MarkdownCellPaddingModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/4/20.
//

import SwiftUI

extension View {
    nonisolated func _markdownCellPadding(_ padding: MarkdownTableCellPadding) -> some View {
        modifier(MarkdownCellPaddingModifier(padding: padding))
    }
}

struct MarkdownCellPaddingModifier: ViewModifier {
    var padding: MarkdownTableCellPadding
    
    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(
                top: padding[.top],
                leading: padding[.leading],
                bottom: padding[.bottom],
                trailing: padding[.trailing]
            ))
    }
}
