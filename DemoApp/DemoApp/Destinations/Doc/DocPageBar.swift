//
//  DocPageBar.swift
//  DemoApp
//
//  What a page puts in the system's navigation bar, as UIKit has it: its items on the page's
//  navigationItem, under floo's theme (`setFlooTheme`). The page itself is SwiftUI's still,
//  so a controller in it reaches the item.
//

import FlooUIKit
import SwiftUI
import UIKit

struct DocPageBar: UIViewControllerRepresentable {
    enum Mode: Equatable {
        /// A page shown, not edited: only what closes it.
        case shown
        /// Selecting blocks: only the way out, as Craft has it.
        case selecting
        /// The agent is writing: only what stops it.
        case agent
        case editing
    }

    var mode: Mode
    var canUndo: Bool
    var canRedo: Bool
    var isFormatOn: Bool
    /// What the agent is doing, under the title.
    var agentStatus: String?
    /// The pages it's in, under the title, each a way back to it.
    var path: [String]
    /// The demo's own controls.
    var demoSections: [FlooMenuSection]
    var actions: Actions

    struct Actions {
        var undo: @MainActor () -> Void
        var redo: @MainActor () -> Void
        var format: @MainActor () -> Void
        var done: @MainActor () -> Void
        var stop: @MainActor () -> Void
        var close: @MainActor () -> Void
        var back: @MainActor (Int) -> Void
    }

    func makeUIViewController(context: Context) -> DocPageBarController { DocPageBarController() }

    func updateUIViewController(_ controller: DocPageBarController, context: Context) {
        controller.bar = self
        controller.theme = context.environment.flooTheme
        controller.apply()
    }
}

final class DocPageBarController: UIViewController {
    var bar: DocPageBar?
    var theme: FlooTheme?
    private var appliedTheme: FlooTheme?
    private var shownMode: DocPageBar.Mode?
    private var shownPath: [String]?
    private var shownHasDemo: Bool?

    private lazy var undoItem = UIBarButtonItem(title: String(localized: "Undo"), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
        self?.bar?.actions.undo()
    })
    private lazy var redoItem = UIBarButtonItem(title: String(localized: "Redo"), image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in
        self?.bar?.actions.redo()
    })
    private lazy var formatItem = UIBarButtonItem(title: String(localized: "Format"), image: UIImage(systemName: "textformat"), primaryAction: UIAction { [weak self] _ in
        self?.bar?.actions.format()
    })

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        forget()
        apply()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        forget()
        apply()
    }

    private func forget() {
        shownMode = nil
        appliedTheme = nil
    }

    /// The controller whose item the bar shows for this page.
    private var navigationPage: UIViewController? {
        var controller: UIViewController? = self
        while let current = controller {
            if current.parent is UINavigationController { return current }
            controller = current.parent
        }
        return nil
    }

    func apply() {
        guard let bar, let item = navigationPage?.navigationItem else { return }
        if let theme, theme != appliedTheme {
            appliedTheme = theme
            setFlooTheme(theme, animated: false)
        }
        // Only what changed: on the Mac each set goes through the window's toolbar again.
        if undoItem.isEnabled != bar.canUndo { undoItem.isEnabled = bar.canUndo }
        if redoItem.isEnabled != bar.canRedo { redoItem.isEnabled = bar.canRedo }
        if formatItem.isSelected != bar.isFormatOn { formatItem.isSelected = bar.isFormatOn }
        let hasDemo = !bar.demoSections.isEmpty
        if shownMode != bar.mode || shownHasDemo != hasDemo {
            shownMode = bar.mode
            shownHasDemo = hasDemo
            item.trailingItemGroups = groups(for: bar)
        }
        if #available(iOS 26, macCatalyst 26, *) {
            let subtitle = bar.agentStatus.map { String(localized: "Agent · \($0)") }
            if item.subtitle != subtitle { item.subtitle = subtitle }
            if shownPath != bar.path {
                shownPath = bar.path
                item.subtitleView = bar.path.isEmpty ? nil : pathView(bar.path)
            }
        }
    }

    private func groups(for bar: DocPageBar) -> [UIBarButtonItemGroup] {
        func one(_ item: UIBarButtonItem) -> [UIBarButtonItemGroup] {
            [UIBarButtonItemGroup(barButtonItems: [item], representativeItem: nil)]
        }
        switch bar.mode {
        case .shown:
            return one(UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.bar?.actions.close() }))
        case .selecting:
            return one(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.bar?.actions.done() }))
        case .agent:
            return one(UIBarButtonItem(title: String(localized: "Stop"), primaryAction: UIAction { [weak self] _ in self?.bar?.actions.stop() }))
        case .editing:
            var editing = [undoItem, redoItem]
            #if targetEnvironment(macCatalyst)
            editing.append(formatItem)
            #endif
            var groups = [UIBarButtonItemGroup(barButtonItems: editing, representativeItem: nil)]
            if !bar.demoSections.isEmpty {
                let more = UIBarButtonItem(title: String(localized: "More"), image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: bar.demoSections.systemElements()))
                groups.append(UIBarButtonItemGroup(barButtonItems: [more], representativeItem: nil))
            }
            return groups
        }
    }

    /// The pages it's in, each a step back out to it.
    private func pathView(_ path: [String]) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        for (index, title) in path.enumerated() {
            if index > 0 {
                let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2)))
                chevron.tintColor = .floo(.secondaryLabel)
                stack.addArrangedSubview(chevron)
            }
            stack.addArrangedSubview(FlooButton(FlooButtonStyle.plain.size(.small), title: title) { [weak self] in
                self?.bar?.actions.back(index)
            })
        }
        return stack
    }
}
