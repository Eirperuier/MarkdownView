//
//  Table++.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import Markdown
import SwiftUI

extension Markdown.Table.Cell {
    var horizontalAlignment: HorizontalAlignment {
        alignment.horizontalAlignment
    }

    var textAlignment: TextAlignment {
        alignment.textAlignment
    }
}

extension Markdown.Table.Cell.CellAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
