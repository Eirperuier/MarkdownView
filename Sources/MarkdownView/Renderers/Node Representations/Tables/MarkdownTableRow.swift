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
    @Environment(\.markdownTableCellOffsetsByRow) private var cellOffsetsByRow
    @Environment(\.markdownTableCellPhasesByRow) private var cellPhasesByRow
    @Environment(\.markdownTableCellHooks) private var hooks

    private var tableConfiguration: MarkdownRendererConfiguration.Table {
        configuration.table
    }

    init(rowIndex: Int, cells: [Markdown.Table.Cell]) {
        self.rowIndex = rowIndex
        self.cells = cells
    }

    var body: some View {
        let _ = MarkdownRenderProbe.increment(\.markdownTableRowBodyCalls)
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            GridRow {
                ForEach(Array(cells.enumerated()), id: \.offset) { (index, cell) in
                    tappable(cellContent(for: cell, at: index), at: index)
                }
            }
        }
    }

    private func cellOffset(at column: Int) -> Int {
        guard let cellOffsetsByRow,
              rowIndex < cellOffsetsByRow.count,
              column < cellOffsetsByRow[rowIndex].count
        else { return 0 }
        return cellOffsetsByRow[rowIndex][column]
    }

    private func cellPhase(at column: Int) -> MarkdownTableCellPhase {
        guard let cellPhasesByRow,
              rowIndex < cellPhasesByRow.count,
              column < cellPhasesByRow[rowIndex].count
        else { return .past }
        return cellPhasesByRow[rowIndex][column]
    }

    @ViewBuilder
    private func tappable(_ content: some View, at column: Int) -> some View {
        if let onTap = hooks.onTap {
            let position = MarkdownTableCellPosition(row: rowIndex, column: column)
            content
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { onTap(position) })
        } else {
            content
        }
    }

    @ViewBuilder
    private func renderedCell(_ cell: Markdown.Table.Cell, at index: Int) -> some View {
        if let replacement = hooks.replacement?(MarkdownTableCellPosition(row: rowIndex, column: index)) {
            replacement
        } else {
            CmarkNodeVisitor(configuration: configuration)
                .makeBody(for: cell)
        }
    }

    @available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
    @ViewBuilder
    private func cellContent(for cell: Markdown.Table.Cell, at index: Int) -> some View {
        let baseContent = renderedCell(cell, at: index)
            .markdownTablePhase(cellPhase(at: index), offsetBase: cellOffset(at: index))
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
