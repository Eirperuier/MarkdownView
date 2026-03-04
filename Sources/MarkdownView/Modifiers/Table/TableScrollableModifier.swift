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
    /// When scrolling is enabled, each cell will have a minimum and maximum width constraint.
    ///
    /// - Parameters:
    ///   - scrollable: A Boolean value that indicates whether the table should be horizontally scrollable.
    ///   - cellMinWidth: The minimum width for each table cell. Default is 100.
    ///   - cellMaxWidth: The maximum width for each table cell. Default is 300.
    nonisolated public func markdownTableScrollable(
        _ scrollable: Bool = true,
        cellMinWidth: CGFloat = 100,
        cellMaxWidth: CGFloat = 300
    ) -> some View {
        transformEnvironment(\.markdownRendererConfiguration) { configuration in
            configuration.table.scrollable = scrollable
            configuration.table.cellMinWidth = cellMinWidth
            configuration.table.cellMaxWidth = cellMaxWidth
        }
    }
}

