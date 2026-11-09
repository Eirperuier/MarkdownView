//
//  ContentView.swift
//  DemoApp
//
//  Created by LiYanan2004 on 2024/10/23.
//

import SwiftUI
import MarkdownView
import FlooDesign

struct ContentView: View {
    @State private var selection: Tab? = UserDefaults.standard.string(forKey: "openTab").flatMap(Tab.init(rawValue:))
        ?? (UserDefaults.standard.bool(forKey: "docDemo") ? .doc : FlooContactsDestination.launches ? .contacts : FlooDestination.launchScenario != nil ? .floo : ChatBenchmark.autorunExchanges == nil && !UserDefaults.standard.bool(forKey: "chatOpen") ? .overview : .chat)
    
    @State private var inspector = WindowInspector()

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
            List(selection: $selection) {
                ForEach(TabGroup.allCases) { group in
                    Section {
                        ForEach(group.tabs) { tab in
                            tab.link
                        }
                    } header: {
                        Text(group.rawValue)
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(Self.sidebarTint)
        } detail: {
            if let selection {
                selection.destination
                    // A column of the window, with its own part of the toolbar: the window grows
                    // for it rather than the detail's content getting narrower.
                    .flooInspector(isPresented: $inspector.isPresented, width: inspector.width, spare: inspector.spare) {
                        inspector.content
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(inspector)
    }

    /// The sidebar's selection: the system writes its names white on the tint, so where the app's
    /// accent is light (white, in dark) it's grey instead, as the system's graphite.
    private static let sidebarTint = Color(uiColor: UIColor { traits in
        let accent = UIColor(named: "AccentColor")?.resolvedColor(with: traits) ?? .systemBlue
        var white: CGFloat = 0
        accent.getWhite(&white, alpha: nil)
        return white > 0.6 ? UIColor.systemGray.resolvedColor(with: traits) : accent
    })
}

/// What the window's inspector shows, as the destination that opened it asks.
@MainActor @Observable
final class WindowInspector {
    var isPresented = false
    private(set) var content: AnyView?
    private(set) var width: CGFloat = 400
    /// How much narrower the detail can get before its content does.
    var spare: CGFloat = 0
    /// Who put it there, so only they put it away.
    private var owner: String?

    func toggle(_ owner: String, width: CGFloat, content: () -> some View) {
        if isPresented, self.owner == owner {
            isPresented = false
            return
        }
        self.owner = owner
        self.width = width
        self.content = AnyView(content())
        isPresented = true
    }

    func close(_ owner: String) {
        guard self.owner == owner else { return }
        isPresented = false
    }
}

#Preview {
    ContentView()
}
