//
//  ListItemContainer.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2024/12/11.
//

import Foundation
import Markdown

extension ListItemContainer {
    /// Depth of the list if nested within others. Index starts at 0.
    public var listDepth: Int {
        var index = 0

        var currentElement = parent

        while currentElement != nil {
            if currentElement is ListItemContainer {
                index += 1
            }

            currentElement = currentElement?.parent
        }
        
        return index
    }
}
