//
//  Table++.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/4/17.
//

import Foundation
import Markdown

extension Markdown.Table.Cell {
    package var alignment: CellAlignment {
        guard parent is any TableCellContainer else { return .leading }
        
        let columnIdx = self.indexInParent
        var currentElement = parent
        while currentElement != nil {
            if currentElement is Markdown.Table {
                let alignment = (currentElement as! Markdown.Table).columnAlignments[columnIdx]
                switch alignment {
                case .center: return .center
                case .left: return .leading
                case .right: return .trailing
                case .none: return .leading
                }
            }
            
            currentElement = currentElement?.parent
        }
        
        return .leading
    }
    
    package enum CellAlignment {
        case leading
        case center
        case trailing
    }

}
