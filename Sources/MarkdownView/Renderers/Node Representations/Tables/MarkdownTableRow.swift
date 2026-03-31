//
//  MarkdownTableHeader.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/21.
//

import SwiftUI
import Markdown

struct MarkdownTableRow: View {
    private var rowIndex: Int
    private var cells: [Markdown.Table.Cell]
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownTableCellPadding) private var padding
    
    private var tableConfiguration: MarkdownRendererConfiguration.Table {
        configuration.table
    }
    
    init(rowIndex: Int, cells: [Markdown.Table.Cell]) {
        self.rowIndex = rowIndex
        self.cells = cells
    }
    
    var body: some View {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            GridRow {
                ForEach(Array(cells.enumerated()), id: \.offset) { (index, cell) in
                    cellContent(for: cell, at: index)
                }
            }
        }
    }
    
    @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
    @ViewBuilder
    private func cellContent(for cell: Markdown.Table.Cell, at index: Int) -> some View {
        let baseContent = CmarkNodeVisitor(configuration: configuration)
            .makeBody(for: cell)
            .multilineTextAlignment(cell.textAlignment)
            .gridColumnAlignment(cell.horizontalAlignment)
            .gridCellColumns(Int(cell.colspan))
            ._markdownCellPadding(padding)
//            .modifier(
//                MarkdownTableStylePreferenceSynchronizer(
//                    row: rowIndex,
//                    column: index
//                )
//            )
        
        if tableConfiguration.scrollable {
            baseContent
                .frame(
                    maxWidth: tableConfiguration.cellMaxWidth,
                    alignment: cell.horizontalAlignment.toAlignment
                )
        }
        else {
            switch cell.horizontalAlignment {
            case .trailing:
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    baseContent
                }
            case .center:
                baseContent
            default:
                HStack(spacing: 0) {
                    baseContent
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - HorizontalAlignment to Alignment

fileprivate extension HorizontalAlignment {
    var toAlignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        default:
            return .center
        }
    }
}
