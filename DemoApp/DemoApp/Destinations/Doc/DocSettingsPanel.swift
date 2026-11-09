//
//  DocSettingsPanel.swift
//  DemoApp
//
//  Settings (DocSettings) on a phone or iPad: floo's self-drawn floating panel at the foot of
//  the window, its pages pushed as a setting's keys open them, following what the settings
//  read. What holds it (the selected blocks, a collection's view) only says what to show and
//  hears when it's been dragged closed.
//

import FlooUIKit
import UIKit

extension DocPageID {
    var title: String {
        switch self {
        case .main: ""
        case .styles: String(localized: "Text Style")
        case .colors: String(localized: "Color")
        case .more, .viewMore: String(localized: "More")
        case .layout: String(localized: "Layout")
        case .view: String(localized: "View Options")
        case .cellFont: String(localized: "Font")
        case .cellNumber: String(localized: "Cell Format")
        case .fill: String(localized: "Cell Fill Color")
        case .stripe: String(localized: "Alternating Row Color")
        case .fields: String(localized: "Fields")
        case .chartData: String(localized: "Data")
        case .chartStyle: String(localized: "Style")
        case .groups: String(localized: "Show/Hide groups")
        case .tableMenu: String(localized: "Table")
        case .editTable: String(localized: "Edit Table")
        case .cellMain: String(localized: "Format")
        }
    }
}

@MainActor
final class DocSettingsPanel {
    private let pages: @MainActor () -> [DocPanelPage]
    private weak var firstPage: DocFormatPage?
    private weak var navigation: UINavigationController?
    /// Closed from here, it says nothing as it goes; and what follows stops at its next change.
    private var run = 0
    /// The pages still drawn as menus, and which each is, so they can follow.
    private var menuPages: [ObjectIdentifier: DocPageID] = [:]
    /// The panel's height changed, a page in being taller: told its view, as it starts to move.
    var whenResized: (@MainActor (UIView) -> Void)?

    init(pages: @escaping @MainActor () -> [DocPanelPage]) {
        self.pages = pages
    }

    /// `page`: what it opens with; whether a touch outside closes it is that page's.
    func open(from presenter: UIViewController, at placement: FlooPanelPlacement, page id: DocPageID, theme: FlooTheme?, onClosed: @escaping () -> Void) {
        guard let opening = pages().first(where: { $0.id == id }), let navigation = pagesController(opening: id) else { return }
        let run = run
        if let theme { navigation.setFlooTheme(theme, animated: false) }
        var style = FlooSheetStyle.floating(at: placement).selfDrawn().closingForKeyboardElsewhere().whenClosed { [weak self] in
            guard let self, run == self.run else { return }
            onClosed()
        }
        if opening.closesOutside { style = style.keepingOpen { _ in false }.modal() }
        if let whenResized {
            let watcher = DocResizeWatcher { [weak navigation] in
                if let navigation { whenResized(navigation.view) }
            }
            watcher.frame = navigation.view.bounds
            watcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            navigation.view.addSubview(watcher)
        }
        presenter.flooPresentSheet(navigation, style: style)
    }

    /// The pages from `id`, following what they read: what a panel shows, at the window's foot
    /// (`open`) or beside what opened it on a large screen (`docPanel(page:)`, which then closes it).
    func pagesController(opening id: DocPageID) -> UINavigationController? {
        guard let opening = pages().first(where: { $0.id == id }) else { return nil }
        run += 1
        let page = DocFormatPage(page: opening, isFirst: true) { [weak self] next in self?.openInner(next) }
        let navigation = UINavigationController(rootViewController: page)
        navigation.preferredContentSize = page.preferredContentSize
        firstPage = page
        self.navigation = navigation
        follow(run)
        return navigation
    }

    func close() {
        run += 1
        firstPage?.flooDismissSheet()
        firstPage = nil
    }

    private func follow(_ run: Int) {
        guard run == self.run, navigation != nil else { return }
        withObservationTracking {
            let pages = pages()
            for shown in navigation?.viewControllers ?? [] {
                switch shown {
                case let shown as DocFormatPage:
                    if let page = pages.first(where: { $0.id == shown.id }) { shown.update(page: page) }
                case let shown as FlooMenuPanel:
                    if case .menu(let sections)? = pages.first(where: { $0.id == menuPages[ObjectIdentifier(shown)] })?.content { shown.update(sections: sections) }
                default: break
                }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow(run) } }
        }
    }

    /// A level in.
    func openInner(_ id: DocPageID) {
        guard let page = pages().first(where: { $0.id == id }) else { return }
        let shown: UIViewController
        switch page.content {
        case .sections:
            shown = DocFormatPage(page: page) { [weak self] next in self?.openInner(next) }
        case .menu(let sections):
            shown = FlooMenuPanel(title: id.title, sections: sections)
            menuPages[ObjectIdentifier(shown)] = id
        }
        navigation?.pushViewController(shown, animated: true)
    }

    func closeInner() {
        navigation?.popToRootViewController(animated: true)
    }

    /// Tests: its bar's place in the panel, and its height, as drawn now.
    var testBar: (top: CGFloat, height: CGFloat)? {
        guard let navigation, !navigation.isNavigationBarHidden else { return nil }
        let frame = navigation.navigationBar.layer.presentation()?.frame ?? navigation.navigationBar.frame
        return (frame.minY, frame.height)
    }
    /// Tests: the page on top, and how deep.
    var testTopView: UIView? { navigation?.topViewController?.viewIfLoaded }
    var testDepth: Int { navigation?.viewControllers.count ?? 0 }
    /// The key on top named `title`.
    func testKey(_ title: String) -> UIControl? {
        func find(_ view: UIView) -> UIControl? {
            if let control = view as? UIControl, control.accessibilityLabel == title { return control }
            return view.subviews.lazy.compactMap(find).first
        }
        return testTopView.flatMap(find)
    }
}

/// Fills a view to hear when its height changes, which its controller isn't told in time.
private final class DocResizeWatcher: UIView {
    private let didResize: @MainActor () -> Void
    private var height: CGFloat = 0

    init(didResize: @escaping @MainActor () -> Void) {
        self.didResize = didResize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.height != height else { return }
        height = bounds.height
        // Not in the panel's own animation: the page scrolls in its own motion.
        DispatchQueue.main.async { [didResize] in MainActor.assumeIsolated(didResize) }
    }
}
