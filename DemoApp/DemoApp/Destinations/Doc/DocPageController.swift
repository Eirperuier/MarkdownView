//
//  DocPageController.swift
//  DemoApp
//
//  One page of the window, in UIKit: its blocks in a `TiledListView` (UIKit rows, a card a
//  row hosting it), its items in the system's navigation bar, and over the rows what works on
//  them: a phone's block selection, the keyboard's bar, the math panel, the command menu, the
//  Mac's format panel; a phone's formula on a page of its own. The pages go in and out on
//  SwiftUI's navigation stack (DocDestination), which the window's split view folds into.
//

import CardUI
import DocKit
import FlooUIKit
import MarkdownView
import MessagingUI
import Observation
import SwiftUI
import UIKit

/// The page in SwiftUI's navigation stack.
struct DocPageHost: UIViewControllerRepresentable {
    let page: DocOpenPage
    let pages: DocPages
    var shown = false
    let openURL: OpenURLAction
    let close: () -> Void

    func makeUIViewController(context: Context) -> DocPageController {
        DocPageController(page: page, pages: pages, shown: shown)
    }

    func updateUIViewController(_ controller: DocPageController, context: Context) {
        controller.openURL = openURL
        controller.close = close
        controller.theme = context.environment.flooTheme
    }
}

@MainActor
final class DocPageController: UIViewController {
    let page: DocOpenPage
    let pages: DocPages
    /// Shown, not edited, with a close in its bar (DocDestination(doc:)).
    let shown: Bool
    /// The app's: links, files and images open with it (DocBlockController.openURL).
    var openURL: OpenURLAction? {
        didSet { editor.blocks.openURL = openURL }
    }
    var close: () -> Void = {}
    var theme: FlooTheme? {
        didSet {
            guard let theme, theme != oldValue else { return }
            setFlooTheme(theme, animated: false)
            editor.blocks.selectionPanel.theme = theme
        }
    }

    private var demo: DocDemo { page.demo }
    private var editor: DocEditor { page.editor }

    private let reader = TiledViewReader<String>()
    private lazy var list = TiledListView<DocRow> { [editor] row in
        DocRowTimes.wrap(row.uikitContent(editor: editor) ?? DocHostedRowContent(row: row, editor: editor), row: row)
    }
    private lazy var selectionOverlay = MarkdownBlockSelectionOverlayView(
        controller: editor.blocks.selection,
        topInset: { [demo] item in (demo.rows.first { $0.id == item.id }?.spacingAbove ?? 0) - DocBlockController.highlightOutset },
        bottomInset: { [demo] item in (demo.rows.first { $0.id == item.id }?.spacingBelow ?? 0) - DocBlockController.highlightOutset },
        highlights: { [demo] item in demo.rows.first { $0.id == item.id }?.media == nil }
    )
    private lazy var mathPanel = DocMathKeyboardPanel(controller: editor.sources, demo: demo)
    private lazy var slashMenu = DocSlashMenuView(menu: editor.slash)
    /// Where the Mac's format panel stands: under the bar at the window's right (Craft's).
    private lazy var formatSpot: FlooPanelAnchorView = {
        let spot = FlooPanelAnchorView(title: String(localized: "Format")) { [editor] _ in DocFormatMenu(editor: editor).sections }
        spot.options.alignment = .trailing
        spot.options.staysBeside = true
        spot.options.selfDrawn = true
        spot.options.keepsOpen = { _ in true }
        spot.onDismiss = { [editor] in editor.panels.showsFormat = false }
        return spot
    }()
    private var bar: DocPageBarItems?
    private var shownAgentWriting: Bool?
    private var shownFocus: Int?
    private var shownFormula: DocFormulaEditing?

    init(page: DocOpenPage, pages: DocPages, shown: Bool) {
        self.page = page
        self.pages = pages
        self.shown = shown
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        DocTiming.mark("page view body \(page.title)", once: true)
        list.reader = reader
        // A swipe across a block selects it (DocBlockController), not the chat's swipe to
        // show the times.
        list.revealConfiguration = .disabled
        list.heightEstimate = { row, width in row.estimatedHeight(width: width) }
        // Rows coming (cards, views, collections) are made ahead in the window, out of sight
        // (AheadWork), and wait while the page moves.
        let aheadStage = UIView(frame: CGRect(x: -20_000, y: 0, width: 1, height: 1))
        aheadStage.isUserInteractionEnabled = false
        aheadStage.accessibilityElementsHidden = true
        view.addSubview(aheadStage)
        AheadWork.stage = aheadStage
        var lastOffset: CGFloat?
        AheadWork.isBusy = { [weak reader] in
            guard let offset = reader?.contentOffsetY() else { return false }
            defer { lastOffset = offset }
            return lastOffset.map { abs($0 - offset) > 0.5 } ?? false
        }
        // Links, files and images across the page at the width it's laid out at, as text
        // wraps (DocMediaLayout.place).
        list.itemPlacement = { row, width in
            row.run.map { run in
                // An indented run is laid out in what the indent leaves of the page.
                let indent = DocBlockController.indentWidth(row.indent)
                let place = DocMediaLayout.place(run, inPage: max(0, DocBlockController.pageWidth(inWidth: width) - indent))
                return TiledItemPlacement(x: DocBlockController.pageLeft(inWidth: width) + indent + place.frame.minX, width: place.frame.width,
                                          sharesLine: place.sharesLine)
            }
        }
        // A document is anchored at its top: the keyboard adds room under the page and leaves
        // where it is scrolled alone. Showing the caret above the keyboard is the editor's.
        var avoidance = TiledUIKitKeyboardAvoidance()
        avoidance.preservesContentOffset = true
        avoidance.preservesOffsetOnDismissal = true
        avoidance.followsBottomOnPresentation = false
        list.keyboardAvoidance = avoidance
        list.onScrollPhaseChange = { [weak self] _, phase in
            if phase != .idle { self?.pinsTop = false }
        }
        list.frame = view.bounds
        list.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list)

        // A phone's block selection, the chat's: a tint on the blocks (links, files and images
        // outline themselves), a dot over each one's right edge, laid over the list as it scrolls.
        if !DocBlockController.usesHandles {
            selectionOverlay.motion = DocTokens.Motion.markdown
            selectionOverlay.frame = view.bounds
            selectionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(selectionOverlay)
        }
        #if !targetEnvironment(macCatalyst)
        let stage = editor.keyboardBarStage
        stage.frame = view.bounds
        stage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(stage)
        // A math block's LaTeX and keys, on the keyboard bar (DocSourceEditing).
        view.addSubview(mathPanel)
        #endif
        slashMenu.frame = view.bounds
        slashMenu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(slashMenu)
        view.addSubview(formatSpot)

        followRows()
        followList()
        followPage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        formatSpot.frame = CGRect(x: 0, y: view.safeAreaInsets.top, width: view.bounds.width, height: 0)
        pinTop()
    }

    /// Until it's scrolled (a finger, the agent's change, a launch option), the page opens at
    /// its top, under the bars over it as they settle (the Mac's toolbar comes into the safe area
    /// once the window's up).
    private var pinsTop = true

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        pinTop()
    }

    private func pinTop() {
        guard pinsTop, view.window != nil, let first = demo.rows.first, let frame = reader.frame(forItem: first.id) else { return }
        let top = frame.minY - view.safeAreaInsets.top
        if abs(reader.contentOffsetY() - top) > 0.5 { reader.scrollToContentOffsetY(top, animated: false) }
    }

    override func loadView() {
        let view = DocPageView()
        view.inWindow = { [weak self] in self?.inWindow($0) }
        self.view = view
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bar = DocPageBarItems(controller: self)
        followBar()
    }

    /// The phone's actions on the selected blocks follow the selection while the page is on
    /// screen: from when it's in the window to when it's left it (another page over it, or
    /// gone). Not by its appearing: in SwiftUI's stack that's said of it as it moves about.
    private func inWindow(_ isIn: Bool) {
        let panel = editor.blocks.selectionPanel
        if isIn {
            panel.theme = theme ?? traitCollection.flooTheme
            panel.start()
        } else {
            panel.stop()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared()
    }

    // MARK: Following the page

    /// The rows as the document has them: on the next turn of the run loop, after the edit
    /// that changed them is done with its text view; a reshape's at once, with its motion, so
    /// the rows move together with what moves in them.
    private func followRows() {
        demo.onRows = { [weak self] in
            guard let self else { return }
            if self.editor.blocks.rowsAnimation != nil { return self.showRows() }
            guard !self.rowsPending else { return }
            self.rowsPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rowsPending else { return }
                self.showRows()
            }
        }
        showRows()
    }

    private var rowsPending = false

    private func showRows() {
        rowsPending = false
        list.show(demo.rows, animation: editor.blocks.rowsAnimation)
    }

    /// The list's layout and the selection: the handle and the selection follow the rows.
    private func followList() {
        withObservationTracking {
            _ = reader.version
            // The phone's block selection is drawn over the rows as they scroll.
            list.readerInvalidatesOnScroll = editor.blocks.isSelecting
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.editor.blocks.attach(self.reader)
                    self.editor.blocks.layoutOverlays()
                    self.followList()
                }
            }
        }
    }

    /// What the page does as its document does: the agent's next change brought into view,
    /// the page a preview while the agent writes (§6.3), a formula's page, the format panel.
    private func followPage() {
        withObservationTracking {
            let focus = demo.focus
            if let focus, focus.serial != shownFocus {
                shownFocus = focus.serial
                pinsTop = false
                reader.scrollTo(id: focus.id, anchor: focus.centered ? .center : nil)
            }
            let writing = demo.isAgentWriting
            if let shown = shownAgentWriting, shown != writing {
                editor.blocks.clear()
                editor.isEditable = !writing
            }
            shownAgentWriting = writing
            #if !targetEnvironment(macCatalyst)
            showFormula(editor.tables.formula)
            #endif
            formatSpot.setPresented(editor.panels.showsFormat)
            if editor.panels.showsFormat {
                // The panel follows what its sections read.
                _ = DocFormatMenu(editor: editor).sections
                formatSpot.refresh()
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.followPage() } }
        }
    }

    /// The bar's items as the page is: its mode, undo and redo, the agent at work.
    private func followBar() {
        guard let bar else { return }
        withObservationTracking {
            bar.apply(DocPageBarItems.State(
                mode: shown ? .shown : editor.blocks.isSelecting ? .selecting : demo.agentStatus != nil ? .agent : .editing,
                canUndo: demo.canUndo,
                canRedo: demo.canRedo,
                isFormatOn: editor.panels.showsFormat,
                agentStatus: demo.agentStatus,
                path: page.ancestors.map(\.title),
                hasDemo: page === pages.root && !shown
            ))
        } onChange: { [weak self, weak bar] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let bar, self.bar === bar else { return }
                    self.followBar()
                }
            }
        }
    }

    /// A phone's formula: the table on a page of its own over this one while it's written.
    private func showFormula(_ formula: DocFormulaEditing?) {
        guard formula !== shownFormula else { return }
        if let presented = presentedViewController as? DocFormulaController, presented.formula !== formula {
            presented.dismiss(animated: false)
        }
        shownFormula = formula
        guard let formula else { return }
        present(DocFormulaController(formula: formula, controller: editor.tables), animated: false)
    }

    // MARK: The bar's actions

    /// The controller whose item the bar shows for this page: the one in the navigation stack.
    var navigationPage: UIViewController? {
        var controller: UIViewController? = self
        while let current = controller {
            if current.parent is UINavigationController { return current }
            controller = current.parent
        }
        return nil
    }

    func undo() { editor.requestUndo() }
    func redo() { editor.requestRedo() }
    func toggleFormat() { editor.panels.showsFormat.toggle() }
    func endSelecting() { editor.blocks.endSelecting() }
    func stopAgent() { demo.stop() }
    func back(to index: Int) { pages.back(to: index) }

    /// The demo's own controls, on its first page.
    var demoSections: [FlooMenuSection] {
        [FlooMenuSection(nil, [
            .action(String(localized: "Reset")) { [pages, editor] in
                pages.reset()
                editor.resetDocument()
            },
            .action(String(localized: "Agent Demo")) { [demo] in demo.runScript() },
        ])]
    }

    // MARK: Keys

    /// The keys that were the bar's undo and redo.
    override var keyCommands: [UIKeyCommand]? {
        guard !shown else { return nil }
        let undo = UIKeyCommand(title: String(localized: "Undo"), action: #selector(undoKey), input: "z", modifierFlags: .command)
        let redo = UIKeyCommand(title: String(localized: "Redo"), action: #selector(redoKey), input: "z", modifierFlags: [.command, .shift])
        for command in [undo, redo] { command.wantsPriorityOverSystemBehavior = true }
        return [undo, redo]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(undoKey): demo.canUndo
        case #selector(redoKey): demo.canRedo
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    @objc private func undoKey() { editor.requestUndo() }
    @objc private func redoKey() { editor.requestRedo() }

    // MARK: Appearing

    private func appeared() {
        DocTiming.mark("page task \(page.title)", once: true)
        editor.blocks.openURL = openURL
        editor.blocks.cardHost = DocDemoHost { [demo] in demo.sentToAgent.append($0) }
        // The rest once a page: coming back to it (a page above it left) keeps its place.
        guard !page.appeared else { return }
        page.appeared = true
        demo.rowFrame = { [reader] id in reader.frame(forItem: id) }
        if shown { editor.isEditable = false }
        editor.blocks.attach(reader)
        editor.blocks.openPage = { [pages] block in pages.open(block) }
        editor.collections.openRecord = { [pages] row, block in pages.openRecord(row, in: block) }
        editor.collections.hasPage = { [pages] row in pages.recordHasPage(row) }
        editor.collections.copyPage = { [pages] row, copy in pages.copyRecordPage(row, to: copy) }
        // The launch options run once a process (DocPages.ranLaunchOptions).
        guard !DocPages.ranLaunchOptions else { return }
        DocPages.ranLaunchOptions = true
        Task { @MainActor in
            await runLaunchOptions()
        }
    }

    /// The app's launch options: what to open, show, select or run as the page first shows
    /// (screenshots, the edit tests, the agent's demo).
    private func runLaunchOptions() async {
        // What they open at is theirs.
        pinsTop = false
        // -docReset YES: the document started over, as the demo's Reset does.
        if UserDefaults.standard.bool(forKey: "docReset") {
            pages.reset()
            editor.resetDocument()
        }
        if UserDefaults.standard.object(forKey: "docScrollBench") != nil {
            let speed = CGFloat(UserDefaults.standard.double(forKey: "docScrollBench"))
            try? await Task.sleep(for: .seconds(2))
            await DocScrollBench(demo: demo, reader: reader, speed: speed > 0 ? speed : 3000).run()
            exit(0)
        }
        let (demo, editor, pages, reader) = (demo, editor, pages, reader)
        // -docOpenPage YES: the first page block's page open (-docShot draws it there).
        if UserDefaults.standard.bool(forKey: "docOpenPage"),
           let block = demo.doc.blocks.first(where: { if case .page = $0.kind { true } else { false } }) {
            Task { @MainActor [pages] in
                pages.open(block.id)
                try? await Task.sleep(for: .seconds(1.5))
                if let path = UserDefaults.standard.string(forKey: "docShot") { DocBlockController.drawWindow(to: path) }
            }
            return
        }
        // -docShow code|math|media|view|table: open at the first code, math,
        // link/file/image, view or table block (the top of the first media or view);
        // -docEdit YES edits code or math.
        if let kind = UserDefaults.standard.string(forKey: "docShow"),
           let row = demo.rows.first(where: { row in
               switch kind {
               case "code": if case .code = row.sourceKind { true } else { false }
               case "media": row.media != nil
               case "view": if case .view? = row.media { true } else { false }
               case "page": row.page != nil
               case "table": row.table != nil
               default: row.sourceKind == .math
               }
           }),
           let block = row.block {
            reader.scrollTo(id: row.id, anchor: kind == "media" || kind == "view" ? .top : .center, animated: false)
            if UserDefaults.standard.bool(forKey: "docEdit") {
                try? await Task.sleep(for: .milliseconds(400))
                editor.sources.focus(block)
            }
        }
        // -docCollectionPanel KIND: the first collection with a panel open (screenshots):
        // view, chart, createKanban, createChart, addField, editField, options, date, addOption;
        // -docCollectionView table|kanban|chart shows that view of it first; a chart where it has
        // none is its first view turned into one, -docChartKind bar|column|line|donut (column).
        if let name = UserDefaults.standard.string(forKey: "docCollectionPanel"),
           let block = demo.doc.blocks.first(where: { if case .collection = $0.kind { true } else { false } }),
           case .collection(var collection) = block.kind, let database = demo.doc.databases[collection.database] {
            let collections = editor.collections
            let chartKind: CollectionChart.Kind = switch UserDefaults.standard.string(forKey: "docChartKind") {
            case "bar": .bar
            case "line": .line
            case "donut": .donut
            default: .column
            }
            if let layout = UserDefaults.standard.string(forKey: "docCollectionView"),
               let view = collection.views.first(where: { ($0.layout.chart != nil ? "chart" : $0.layout.isKanban ? "kanban" : "table") == layout }) {
                collections.show(view.id, in: block.id)
                collection.current = view.id
                if view.layout.chart != nil, UserDefaults.standard.string(forKey: "docChartKind") != nil {
                    collections.changeChart(view.id, in: block.id) { $0.kind = chartKind }
                }
            } else if UserDefaults.standard.string(forKey: "docCollectionView") == "chart", let view = collection.currentView {
                collections.setChart(chartKind, in: view.id, of: block.id)
            }
            if case .collection(let now)? = demo.doc.blocks.first(where: { $0.id == block.id })?.kind { collection = now }
            let view = collection.currentView
            let select = database.columns.first { if case .select = $0.type { true } else { false } }
            let kind: DocCollectionPanel.Kind? = switch name {
            case "view", "fields": .view
            case "createKanban": .createKanban
            case "createChart": .createChart
            case "chart": .chart
            case "addField": .addField
            case "editField": database.columns.last.map { .editField($0.id) }
            case "options": database.rows.first.flatMap { row in select.map { .options(row: row.id, column: $0.id) } }
            case "date": database.rows.first.flatMap { row in database.columns.first { $0.type == .date }.map { .date(row: row.id, column: $0.id) } }
            case "addOption": view?.layout.groupBy.map { .addOption($0) }
            default: nil
            }
            if let row = demo.rows.first(where: { $0.collection != nil }) { reader.scrollTo(id: row.id, anchor: .top, animated: false) }
            try? await Task.sleep(for: .milliseconds(800))
            if let kind { collections.show(kind, in: block.id) }
            if name == "fields" {
                try? await Task.sleep(for: .seconds(1))
                collections.viewPanel?.openInner(.fields)
            }
        }
        // -docPageShots NAME: the page a screen at a time, top to bottom, to NAME-<n>.png in
        // the app's (sandboxed) temporary folder; then the app quits.
        if let name = UserDefaults.standard.string(forKey: "docPageShots") {
            try? await Task.sleep(for: .seconds(2))
            for page in 0..<40 {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(page).png").path
                DocBlockController.drawWindow(to: path)
                // Rows are measured as they show, so the page's end is asked again each time.
                let offset = reader.contentOffsetY(), visible = reader.visibleContentHeight() ?? 600
                let end = demo.rows.last.flatMap { reader.frame(forItem: $0.id)?.maxY } ?? 0
                guard offset + visible < end - 1 else { break }
                reader.scrollToContentOffsetY(min(offset + visible - 48, end - visible), animated: false)
                try? await Task.sleep(for: .milliseconds(1500))
            }
            exit(0)
        }
        // -docShowTable YES: open at the first table (screenshots, trying tables out).
        if UserDefaults.standard.bool(forKey: "docShowTable"), let table = demo.rows.first(where: { $0.table != nil }) {
            reader.scrollTo(id: table.id, anchor: .center, animated: false)
            // -docEditCell YES: and edit a cell of it.
            if UserDefaults.standard.bool(forKey: "docEditCell"), let snapshot = table.table {
                try? await Task.sleep(for: .milliseconds(400))
                editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 2, column: 1))
                // -docCellMenu YES: and open its menu.
                if UserDefaults.standard.bool(forKey: "docCellMenu"),
                   let key = editor.tables.key(in: snapshot, at: MarkdownTableCellPosition(row: 2, column: 1)) {
                    try? await Task.sleep(for: .milliseconds(400))
                    editor.tables.showMenu(key)
                    // -docCellMenuInner YES: and go into Edit Table.
                    if UserDefaults.standard.bool(forKey: "docCellMenuInner") {
                        try? await Task.sleep(for: .milliseconds(800))
                        editor.tables.menuPanel?.openInner(.editTable)
                    }
                }
            }
            // -docFormula <text>: and write a formula in the cell under 21%, 16%, 17%, <text>
            // typed in it.
            if let text = UserDefaults.standard.string(forKey: "docFormula"), let snapshot = table.table,
               let key = editor.tables.key(in: snapshot, at: MarkdownTableCellPosition(row: 4, column: 2)) {
                try? await Task.sleep(for: .milliseconds(400))
                editor.tables.tapped(snapshot, at: MarkdownTableCellPosition(row: 4, column: 2))
                editor.tables.perform(.insertFormula, at: key)
                try? await Task.sleep(for: .milliseconds(900))
                if let formula = editor.tables.formula {
                    let caret = NSRange(location: text.utf16.count, length: 0)
                    formula.typed(text, selection: caret)
                    formula.field?.show(text, selection: caret)
                }
            }
        }
        // -docShowHandle YES: a list item's handle under the pointer and the item after
        // it selected (on a phone, selecting).
        if UserDefaults.standard.bool(forKey: "docShowHandle"),
           let index = demo.doc.blocks.firstIndex(where: { $0.text.string.hasPrefix("嵌套列表") }) {
            let blocks = demo.doc.blocks
            // A phone has no handle: its selection mode instead.
            if DocBlockController.usesHandles {
                editor.blocks.click(blocks[index + 3].id)
            } else {
                editor.blocks.beginSelecting(blocks[index + 3].id)
            }
            editor.blocks.testHover(blocks[index].id)
        }
        // -docColors YES: a colour, highlights and pen marks on the first paragraph
        // of section 1 (screenshots of them).
        if UserDefaults.standard.bool(forKey: "docColors"),
           let block = demo.doc.blocks.first(where: { $0.text.string.hasPrefix("Loading older") }) {
            func range(_ words: String) -> [(block: DocBlockID, range: Range<Int>)] {
                guard let found = block.text.string.range(of: words) else { return [] }
                let start = block.text.string.utf16.distance(from: block.text.string.startIndex, to: found.lowerBound)
                return [(block.id, start..<(start + words.utf16.count))]
            }
            editor.set(.color, to: .color("red"), over: range("Loading older messages"))
            editor.set(.highlight, to: .highlight(color: nil), over: range("everything"))
            editor.set(.highlight, to: .highlight(color: "blue"), over: range("below them"))
            editor.set(.pen, to: .pen(kind: "circle", color: nil), over: range("list"))
            editor.set(.pen, to: .pen(kind: "wavy", color: "blue"), over: range("across the update"))
        }
        // -docFocus <text>: the cursor at the end of the first block starting with it,
        // keyboard up; -docSelect N selects its first N characters, -docFocusNewLine YES
        // opens an empty line after it (the keyboard bar's states).
        if let prefix = UserDefaults.standard.string(forKey: "docFocus"),
           let block = demo.doc.blocks.first(where: { $0.text.string.hasPrefix(prefix) }) {
            demo.bringIntoView(block.id)
            try? await Task.sleep(for: .milliseconds(400))
            let selected = UserDefaults.standard.integer(forKey: "docSelect")
            let end = DocPosition(block: block.id, offset: block.text.length)
            editor.place(selected > 0 ? DocSelection(anchor: .init(block: block.id, offset: 0), head: .init(block: block.id, offset: selected))
                                      : DocSelection(anchor: end, head: end))
            if UserDefaults.standard.bool(forKey: "docFocusNewLine") {
                try? await Task.sleep(for: .milliseconds(300))
                editor.insert(.kind(.paragraph), at: block)
            }
        }
        // -docMediaLayouts YES: the links, files and images selected, their layouts shown.
        if UserDefaults.standard.bool(forKey: "docMediaLayouts"),
           let first = demo.doc.blocks.first(where: { DocMediaView.draws($0.kind) }) {
            editor.blocks.beginSelecting(first.id)
            editor.blocks.select(demo.doc.blocks.filter { DocMediaView.draws($0.kind) }.map(\.id))
            editor.blocks.isChoosingLayout = true
        }
        // -docSelectKind link|image: the first link or image selected, as a click selects it.
        if let kind = UserDefaults.standard.string(forKey: "docSelectKind"),
           let block = demo.doc.blocks.first(where: {
               switch $0.kind {
               case .link: kind == "link"
               case .image: kind == "image"
               default: false
               }
           }) {
            if DocBlockController.usesHandles { editor.blocks.click(block.id) } else { editor.blocks.beginSelecting(block.id) }
        }
        // -docSheet YES: the phone's format panel, over the selected blocks
        // (-docShowHandle) or the caret's block, as Aa (-docFocus).
        if UserDefaults.standard.bool(forKey: "docSheet") {
            // A cell's: its keyboard up first, as when Aa is pressed.
            try? await Task.sleep(for: .milliseconds(UserDefaults.standard.bool(forKey: "docEditCell") ? 1500 : 500))
            if !editor.blocks.isSelecting { editor.blocks.formatCaretBlock() }
            editor.panels.showsSheet = true
            // -docSheetOpen styles|colors|more: a level in, and left there. -docSheetInner
            // YES: its More… and back, for watching the push.
            if let inner = UserDefaults.standard.string(forKey: "docSheetOpen") {
                try? await Task.sleep(for: .seconds(1))
                let pages: [String: DocPageID] = ["styles": .styles, "colors": .colors, "more": .more, "cellFont": .cellFont, "cellNumber": .cellNumber]
                editor.blocks.selectionPanel.openInner(pages[inner] ?? .more)
            }
            if UserDefaults.standard.bool(forKey: "docSheetInner") {
                try? await Task.sleep(for: .seconds(2))
                editor.blocks.selectionPanel.openInner(.more)
                try? await Task.sleep(for: .seconds(2))
                editor.blocks.selectionPanel.closeInner()
                try? await Task.sleep(for: .seconds(2))
                editor.blocks.closeSheet()
            }
        }
        // -docShot <path>: what the options above show, drawn to a PNG there
        // (screenshots without screen recording).
        if let path = UserDefaults.standard.string(forKey: "docShot") {
            try? await Task.sleep(for: .milliseconds(800))
            if let hovered = editor.blocks.hovered { editor.blocks.testHover(hovered) }
            DocBlockController.drawWindow(to: path)
        }
        if UserDefaults.standard.bool(forKey: "docEditTest") {
            // Not the page's task: going into a page takes this page's view (and its task) away.
            await Task { @MainActor [demo, editor, pages] in await DocEditTests(demo: demo, editor: editor, pages: pages).run() }.value
        }
        if DocDestination.autoruns {
            try? await Task.sleep(for: .seconds(1))
            demo.runScript()
        }
    }
}

/// The page's view: says when it comes into a window and leaves it.
private final class DocPageView: UIView {
    var inWindow: ((Bool) -> Void)?
    private var wasIn = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let isIn = window != nil
        guard isIn != wasIn else { return }
        wasIn = isIn
        inWindow?(isIn)
    }
}

/// A row whose content is SwiftUI (a floo card or view, a collection's chart): a UIKit row
/// hosting DocRowView (HostedRowView).
@MainActor
struct DocHostedRowContent: TiledUIKitCellContent {
    let row: DocRow
    let editor: DocEditor

    static func makeRowView() -> HostedRowView { HostedRowView() }

    func configure(_ view: HostedRowView, context: TiledUIKitCellContext) {
        view.show(content, key: key, context: context)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        HostedRowView.height(of: content, key: key, width: width)
    }

    func prepareAhead(forWidth width: CGFloat, traits: UITraitCollection) {
        HostedRowView.prepare(content, key: key, width: width)
    }

    static func prepareForReuse(_ view: HostedRowView) {
        view.reset()
    }

    /// The row as it is: another of it, another height.
    private var key: String {
        "\(row.id)|\(row.source.hashValue)|\(row.spacingAbove)|\(row.spacingBelow)|\(row.indent)|\(String(describing: row.box))"
    }

    private var content: some View {
        DocRowView(row: row, coordinator: editor.demo.coordinator, hooks: row.block.map { editor.hooks(for: $0) }, tables: editor.tables,
                   collections: editor.collections, sources: editor.sources, blocks: editor.blocks, demo: editor.demo)
            // Its cards' stacks drawn by floo's own engine, not a SwiftUI view each.
            .environment(\.cardEngine, true)
    }
}
