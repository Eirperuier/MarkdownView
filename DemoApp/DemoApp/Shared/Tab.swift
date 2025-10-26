//
//  Tab.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case overview, image, table, text, list, customization, interact, blockDirective, math
    
    var name: String {
        switch self {
        case .overview: "Overview"
        case .image: "Images"
        case .table: "Table"
        case .text: "Text"
        case .list: "List"
        case .customization: "Customization"
        case .interact: "Interact"
        case .blockDirective: "Block Directive"
        case .math: "Math Rendering"
        }
    }
}

// MARK: - Link

extension Tab {
    struct TabLink: View {
        let tab: Tab
        var body: some View {
            NavigationLink(tab.name, value: tab)
        }
    }
    
    /// A navigation link view to the destination view.
    var link: TabLink { .init(tab: self) }
}

// MARK: - Destination

extension Tab {
    struct TabDestination: View {
        let tab: Tab
        var body: some View {
            ScrollView {
                Group {
                    switch tab {
                    case .overview: OverviewDestination()
                    case .image: ImageDestination()
                    case .table: TableDestination()
                    case .text: TextDestination()
                    case .list: ListDestination()
                    case .customization: CustomizationDestination()
                    case .interact: InteractDestination()
                    case .blockDirective: BlockDirectiveDestination()
                    case .math: MathDestination()
                    }
                }
                .frame(maxWidth: .infinity)
                .scenePadding()
            }
        }
    }
    
    /// A navigation detail view of this tab.
    var destination: TabDestination { .init(tab: self) }
}

// MARK: - Conformance: Identifiable

extension Tab: Identifiable {
    var id: String { name }
}
