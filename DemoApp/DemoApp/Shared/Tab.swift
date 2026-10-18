//
//  Tab.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import Foundation
import SwiftUI

enum Tab: String, CaseIterable {
    case overview, image, table, text, list, customization, tint, interact, blockDirective, math, streaming, chat, floo, contacts, doc
    
    var name: String {
        switch self {
        case .overview: "Overview"
        case .image: "Images"
        case .table: "Table"
        case .text: "Text"
        case .list: "List"
        case .customization: "Customization"
        case .tint: "Text Tint"
        case .interact: "Interact"
        case .blockDirective: "Block Directive"
        case .math: "Math Rendering"
        case .streaming: "Streaming"
        case .chat: "Chat"
        case .floo: String(localized: "floo Chat")
        case .contacts: String(localized: "floo Services")
        case .doc: String(localized: "floo Docs")
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
            // These own their scroll views: block selection needs to reach them.
            if tab == .streaming {
                StreamingDestination()
            } else if tab == .chat {
                ChatDestination()
            } else if tab == .floo {
                FlooDestination()
            } else if tab == .contacts {
                FlooContactsDestination()
            } else if tab == .doc {
                DocDestination()
            } else {
                scrolling
            }
        }

        private var scrolling: some View {
            ScrollView {
                Group {
                    switch tab {
                    case .overview: OverviewDestination()
                    case .image: ImageDestination()
                    case .table: TableDestination()
                    case .text: TextDestination()
                    case .list: ListDestination()
                    case .customization: CustomizationDestination()
                    case .tint: TintDestination()
                    case .interact: InteractDestination()
                    case .blockDirective: BlockDirectiveDestination()
                    case .math: MathDestination()
                    case .streaming, .chat, .floo, .contacts, .doc: EmptyView()
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
