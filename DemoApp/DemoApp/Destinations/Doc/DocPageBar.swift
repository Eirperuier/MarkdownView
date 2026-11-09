//
//  DocPageBar.swift
//  DemoApp
//
//  What a page puts in the system's navigation bar, as UIKit has it: its items on the page's
//  navigationItem (the controller of it in the navigation stack), under floo's theme.
//

import FlooUIKit
import UIKit

@MainActor
final class DocPageBarItems {
    enum Mode: Equatable {
        /// A page shown, not edited: only what closes it.
        case shown
        /// Selecting blocks: only the way out, as Craft has it.
        case selecting
        /// The agent is writing: only what stops it.
        case agent
        case editing
    }

    struct State: Equatable {
        var mode: Mode
        var canUndo: Bool
        var canRedo: Bool
        var isFormatOn: Bool
        /// What the agent is doing, under the title.
        var agentStatus: String?
        /// The pages it's in, under the title, each a way back to it.
        var path: [String]
        /// The demo's own controls.
        var hasDemo: Bool
    }

    private weak var controller: DocPageController?
    private var shown: State?

    private lazy var undoItem = UIBarButtonItem(title: String(localized: "Undo"), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
        self?.controller?.undo()
    })
    private lazy var redoItem = UIBarButtonItem(title: String(localized: "Redo"), image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak self] _ in
        self?.controller?.redo()
    })
    private lazy var formatItem = UIBarButtonItem(title: String(localized: "Format"), image: UIImage(systemName: "textformat"), primaryAction: UIAction { [weak self] _ in
        self?.controller?.toggleFormat()
    })

    init(controller: DocPageController) {
        self.controller = controller
    }

    func apply(_ state: State) {
        guard let controller, let item = controller.navigationPage?.navigationItem else { return }
        let old = shown
        shown = state
        // Only what changed: on the Mac each set goes through the window's toolbar again.
        if undoItem.isEnabled != state.canUndo { undoItem.isEnabled = state.canUndo }
        if redoItem.isEnabled != state.canRedo { redoItem.isEnabled = state.canRedo }
        if formatItem.isSelected != state.isFormatOn { formatItem.isSelected = state.isFormatOn }
        if old?.mode != state.mode || old?.hasDemo != state.hasDemo {
            item.trailingItemGroups = groups(for: state)
        }
        if #available(iOS 26, macCatalyst 26, *) {
            let subtitle = state.agentStatus.map { String(localized: "Agent · \($0)") }
            if item.subtitle != subtitle { item.subtitle = subtitle }
            if old?.path != state.path {
                item.subtitleView = state.path.isEmpty ? nil : pathView(state.path)
            }
        }
    }

    private func groups(for state: State) -> [UIBarButtonItemGroup] {
        func one(_ item: UIBarButtonItem) -> [UIBarButtonItemGroup] {
            [UIBarButtonItemGroup(barButtonItems: [item], representativeItem: nil)]
        }
        switch state.mode {
        case .shown:
            return one(UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.controller?.close() }))
        case .selecting:
            return one(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.controller?.endSelecting() }))
        case .agent:
            return one(UIBarButtonItem(title: String(localized: "Stop"), primaryAction: UIAction { [weak self] _ in self?.controller?.stopAgent() }))
        case .editing:
            var editing = [undoItem, redoItem]
            #if targetEnvironment(macCatalyst)
            editing.append(formatItem)
            #endif
            var groups = [UIBarButtonItemGroup(barButtonItems: editing, representativeItem: nil)]
            if state.hasDemo, let sections = controller?.demoSections {
                let more = UIBarButtonItem(title: String(localized: "More"), image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: sections.systemElements()))
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
                self?.controller?.back(to: index)
            })
        }
        return stack
    }
}
