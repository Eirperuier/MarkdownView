import SwiftUI
import Markdown

struct MarkdownTable: View {
    var table: Markdown.Table
    
    @Environment(\.markdownTableStyle) private var tableStyle
    @Environment(\.markdownRendererConfiguration.table) private var tableConfiguration
    @State private var containerWidth: CGFloat = MarkdownTable.estimatedContainerWidth
    
    private static var estimatedContainerWidth: CGFloat {
        #if os(iOS) || os(tvOS)
        UIScreen.main.bounds.width
        #elseif os(macOS)
        NSScreen.main?.frame.width ?? 800
        #else
        400
        #endif
    }
    
    var body: some View {
        if tableConfiguration.scrollable {
            scrollableTable
        } else {
            let configuration = MarkdownTableStyleConfiguration(
                table: MarkdownTableStyleConfiguration.Table(table: table)
            )
            tableStyle
                .makeBody(configuration: configuration)
                .erasedToAnyView()
                .markdownTableCellStyleApplied()
                .coordinateSpace(name: MarkdownTable.CoordinateSpaceName)
        }
    }
    
    @ViewBuilder
    private var scrollableTable: some View {
        let headerCells = Array(table.head.cells)
        let columnCount = headerCells.count
        let spacing: CGFloat = 20
        
        ScrollView(.horizontal, showsIndicators: true) {
            AdaptiveTableLayout(
                columnCount: columnCount,
                containerWidth: containerWidth,
                cellMaxWidth: tableConfiguration.cellMaxWidth,
                columnSpacing: spacing
            ) {
                ForEach(Array(headerCells.enumerated()), id: \.offset) { (col, cell) in
                    AdaptiveTableCell(cell: cell, isHeader: true, showTopSeparator: false)
                }
                ForEach(Array(table.body.children.enumerated()), id: \.offset) { (_, row) in
                    let cells = Array(row.children) as! [Markdown.Table.Cell]
                    ForEach(Array(cells.enumerated()), id: \.offset) { (col, cell) in
                        AdaptiveTableCell(
                            cell: cell,
                            isHeader: false,
                            showTopSeparator: true,
                            columnSpacing: spacing,
                            isLastColumn: col == columnCount - 1
                        )
                    }
                }
            }
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
        .background {
            GeometryReader { proxy in
                Color.clear
                    ._task(id: proxy.size.width) {
                        containerWidth = proxy.size.width
                    }
            }
        }
    }
}

// MARK: - Adaptive Table Layout

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
struct AdaptiveTableLayout: Layout {
    var columnCount: Int
    var containerWidth: CGFloat
    var cellMaxWidth: CGFloat
    var columnSpacing: CGFloat = 12
    
    struct CacheData {
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }
    
    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) -> CGSize {
        guard !subviews.isEmpty, columnCount > 0 else { return .zero }
        let rowCount = subviews.count / columnCount
        guard rowCount > 0 else { return .zero }
        
        var colIdeals = [CGFloat](repeating: 0, count: columnCount)
        for (i, sub) in subviews.enumerated() {
            let col = i % columnCount
            let ideal = sub.sizeThatFits(.unspecified)
            colIdeals[col] = max(colIdeals[col], min(ideal.width, cellMaxWidth))
        }
        
        let totalSpacing = columnSpacing * CGFloat(max(columnCount - 1, 0))
        let totalIdeal = colIdeals.reduce(0, +) + totalSpacing
        var colWidths: [CGFloat]
        
        if totalIdeal < containerWidth, containerWidth > 0, colIdeals.reduce(0, +) > 0 {
            let excess = containerWidth - totalIdeal
            let idealSum = colIdeals.reduce(0, +)
            colWidths = colIdeals.map { ideal in
                ideal + excess * (ideal / idealSum)
            }
        } else {
            colWidths = colIdeals
        }
        
        var rowHeights = [CGFloat](repeating: 0, count: rowCount)
        for (i, sub) in subviews.enumerated() {
            let col = i % columnCount
            let row = i / columnCount
            guard row < rowCount else { continue }
            let size = sub.sizeThatFits(ProposedViewSize(width: colWidths[col], height: nil))
            rowHeights[row] = max(rowHeights[row], size.height)
        }
        
        cache.columnWidths = colWidths
        cache.rowHeights = rowHeights
        
        let totalWidth = colWidths.reduce(0, +) + totalSpacing
        let totalHeight = rowHeights.reduce(0, +)
        return CGSize(width: max(totalWidth, containerWidth), height: totalHeight)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CacheData) {
        guard !cache.columnWidths.isEmpty, !cache.rowHeights.isEmpty else { return }
        let columnCount = cache.columnWidths.count
        
        for (i, sub) in subviews.enumerated() {
            let col = i % columnCount
            let row = i / columnCount
            guard row < cache.rowHeights.count, col < columnCount else { continue }
            
            let x = bounds.minX + cache.columnWidths.prefix(col).reduce(0, +) + columnSpacing * CGFloat(col)
            let y = bounds.minY + cache.rowHeights.prefix(row).reduce(0, +)
            sub.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(
                    width: cache.columnWidths[col],
                    height: cache.rowHeights[row]
                )
            )
        }
    }
}

// MARK: - Adaptive Table Cell

fileprivate struct AdaptiveTableCell: View {
    var cell: Markdown.Table.Cell
    var isHeader: Bool
    var showTopSeparator: Bool
    var columnSpacing: CGFloat = 0
    var isLastColumn: Bool = false
    
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownTableCellPadding) private var padding
    @Environment(\.markdownFontGroup.tableHeader) private var headerFont
    @Environment(\.markdownFontGroup.tableBody) private var bodyFont
    
    var body: some View {
        CmarkNodeVisitor(configuration: configuration)
            .makeBody(for: cell)
            .multilineTextAlignment(cell.textAlignment)
            ._markdownCellPadding(padding)
            .font(isHeader ? headerFont : bodyFont)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cellAlignment)
            .overlay(alignment: .topLeading) {
                if showTopSeparator {
                    Divider()
                        .padding(.trailing, isLastColumn ? 0 : -columnSpacing)
                }
            }
    }
    
    private var cellAlignment: Alignment {
        switch cell.horizontalAlignment {
        case .leading: return .topLeading
        case .trailing: return .topTrailing
        default: return .top
        }
    }
}

extension MarkdownTable {
    static let CoordinateSpaceName: String = "markdownview-table"
}

struct MarkdownTableBody: View {
    var tableBody: Markdown.Table.Body
    
    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownFontGroup.tableBody) private var font
    
    var body: some View {
        ForEach(Array(tableBody.children.enumerated()), id: \.offset) { (_, row) in
            CmarkNodeVisitor(configuration: configuration)
                .makeBody(for: row)
                .font(font)
        }
    }
}


// MARK: - Auxiliary

fileprivate extension View {
    nonisolated func markdownTableCellStyleApplied() -> some View {
        modifier(MarkdownTableCellStylingViewModifier())
    }
}

fileprivate struct MarkdownTableCellStylingViewModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .backgroundPreferenceValue(
                MarkdownTableRowStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.values.contains(where: { $0.backgroundStyle != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.rows) { row in
                            if let backgroundStyle = row.backgroundStyle {
                                resolveShape(row.backgroundShape, style: backgroundStyle)
                                    .offset(styleCollection.offset(for: row.position))
                                    .frame(height: styleCollection.heights[row.position.row])
                                    .frame(maxWidth: .infinity)
                                    
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .backgroundPreferenceValue(
                MarkdownTableCellStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.cells.contains(where: { $0.backgroundStyle != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.cells) { cell in
                            if let backgroundStyle = cell.backgroundStyle {
                                resolveShape(cell.backgroundShape, style: backgroundStyle)
                                    .offset(styleCollection.offset(for: cell.position))
                                    .frame(
                                        width: styleCollection.widths[cell.position.column],
                                        height: styleCollection.heights[cell.position.row]
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlayPreferenceValue(
                MarkdownTableCellStyleCollectionPreference.self
            ) { styleCollection in
                if styleCollection.cells.contains(where: { $0.overlayContent != nil }) {
                    ZStack(alignment: .topLeading) {
                        ForEach(styleCollection.cells) { cell in
                            if let overlayContent = cell.overlayContent {
                                overlayContent
                                    .offset(styleCollection.offset(for: cell.position))
                                    .frame(
                                        width: styleCollection.widths[cell.position.column],
                                        height: styleCollection.heights[cell.position.row]
                                    )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
    }
    
    func resolveShape(_ shape: any Shape, style: some ShapeStyle) -> AnyView {
        func cast(_ shape: some Shape) -> AnyView {
            AnyView(shape.fill(style))
        }
        return _openExistential(shape, do: cast(_:))
    }
}

extension View {
    nonisolated package func _markdownTableStylesIgnored(_ ignored: Bool = true) -> some View {
        transformEnvironment(\.self) { environmentValues in
            if ignored {
                environmentValues.markdownTableCellPadding = .zero
                environmentValues.markdownTableCellBackgroundStyle = nil
                environmentValues.markdownTableCellOverlayContent = nil
                environmentValues.markdownTableRowBackgroundStyle = nil
            }
        }
    }
}
