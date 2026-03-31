//
//  TableScrollableModifier.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/1/4.
//

import SwiftUI

extension View {
    /// Enables horizontal scrolling for markdown tables.
    ///
    /// When scrolling is enabled, the table adapts its width: filling the available space
    /// when content fits, or enabling horizontal scrolling when content overflows.
    /// Each cell will have a maximum width constraint.
    ///
    /// - Parameters:
    ///   - scrollable: A Boolean value that indicates whether the table should be horizontally scrollable.
    ///   - cellMaxWidth: The maximum width for each table cell. Default is 300.
    nonisolated public func markdownTableScrollable(
        _ scrollable: Bool = true,
        cellMaxWidth: CGFloat = 300
    ) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.table.scrollable = scrollable
            configuration.table.cellMaxWidth = cellMaxWidth
        }
    }
}

