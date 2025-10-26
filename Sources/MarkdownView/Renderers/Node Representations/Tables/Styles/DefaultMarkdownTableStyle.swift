//
//  DefaultTableStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import SwiftUI

/// Default markdown table style that applies to a MarkdownView.
public struct DefaultMarkdownTableStyle: MarkdownTableStyle {
    /// A boolean value that indicates whether to display separators between rows.
    public var showsRowSeparators: Bool = true
    
    public func makeBody(configuration: Configuration) -> some View {
        DefaultMarkdownTable(
            configuration: configuration,
            showsRowSeparators: showsRowSeparators
        )
    }
}

extension MarkdownTableStyle where Self == DefaultMarkdownTableStyle {
    /// Default markdown table style.
    static public var `default`: DefaultMarkdownTableStyle { .init() }
    
    /// Default markdown table style with control over row separator visibility.
    static public func `default`(showsRowSeparators: Bool) -> DefaultMarkdownTableStyle {
        .init(showsRowSeparators: showsRowSeparators)
    }
}

fileprivate struct DefaultMarkdownTable: View {
    var configuration: MarkdownTableStyleConfiguration
    @Environment(\.colorScheme) var colorScheme
    
    var showsRowSeparators: Bool
    private var spacing: CGFloat {
        showsRowSeparators ? 8 : 16
    }
    
    var body: some View {
        Group {
            if #available(macOS 13.0, iOS 17.0, tvOS 16.0, watchOS 9.0, *) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    configuration.table.header
                    ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { (_, row) in
                        if showsRowSeparators {
                            Divider()
                        }
                        row
                    }
                }
                
                .geometryGroup()
            } else {
                configuration.table.fallback
                    .showsRowSeparators(showsRowSeparators)
            }
        }
        .markdownTableCellPadding(spacing)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .foregroundStyle(colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
        }
    }
}
