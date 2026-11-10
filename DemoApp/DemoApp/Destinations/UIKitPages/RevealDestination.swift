//
//  RevealDestination.swift
//  DemoApp
//
//  Watches a reply stream in, as the chat streams one, with MarkdownUIKit's reveal: the same
//  parser, coordinator and reveal style. Replay it, at another speed or rate.
//

import MarkdownUIKit
import MarkdownView
import SwiftUI
import UIKit

struct RevealDestination: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> RevealViewController { RevealViewController() }
    func updateUIViewController(_ controller: RevealViewController, context: Context) {}
}

@MainActor
final class RevealViewController: UIViewController {
    private let stack = MarkdownBlockStackView()
    private let play = UIButton(configuration: .borderedProminent())
    /// How often a chunk comes: the chat's Send is the middle one.
    private let speed = UISegmentedControl(items: ["Slow", "Normal", "Fast"])
    /// How fast the reveal catches up: a reply's, or reasoning text's.
    private let rate = UISegmentedControl(items: ["Reply", "Thinking"])
    private let status = UILabel()
    private var coordinator = StreamingRevealCoordinator<UUID>()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var blockCount = 0

    private static let intervals: [Duration] = [.milliseconds(120), .milliseconds(30), .milliseconds(8)]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        ChatUIKitBlock.applyTheme()
        stack.followsEnd = true

        play.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .primaryActionTriggered)
        speed.selectedSegmentIndex = 1
        rate.selectedSegmentIndex = 0
        rate.addAction(UIAction { [weak self] _ in self?.applyRate() }, for: .valueChanged)
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.adjustsFontForContentSizeCategory = true

        let bar = UIStackView(arrangedSubviews: [play, speed, rate, status])
        bar.axis = .horizontal
        bar.spacing = 12
        bar.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let barScroll = addControlBar(bar)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: barScroll.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if task == nil, blockCount == 0 { start() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stop()
    }

    private func toggle() {
        task == nil ? start() : stop()
    }

    private func start() {
        task?.cancel()
        coordinator.reset()
        applyRate()
        generation = 0
        blockCount = 0
        stack.show([])
        let interval = Self.intervals[max(0, speed.selectedSegmentIndex)]
        task = Task { [weak self] in
            await self?.stream(ChatCorpus.longReply, every: interval)
            self?.task = nil
            self?.updateControls()
        }
        updateControls()
    }

    private func stop() {
        task?.cancel()
        task = nil
        coordinator.finishQuickly()
        updateControls()
    }

    private func applyRate() {
        coordinator.setRate(rate.selectedSegmentIndex == 1 ? .thinkingBlock : .standard)
    }

    /// As the chat streams a reply: parsed off the main actor, each committed parse shown.
    private func stream(_ reply: String, every interval: Duration) async {
        let parser = MarkdownStreamParser()
        parser.onBlocks = { [weak self] blocks in self?.commit(blocks) }
        var text = ""
        for chunk in ChatCorpus.chunks(of: reply) {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            text += chunk
            parser.submit(text, isStreaming: true)
        }
        await parser.update(text, isStreaming: false)
        coordinator.finishQuickly()
    }

    private func commit(_ blocks: [MarkdownStreamBlock]) {
        generation += 1
        blockCount = blocks.count
        coordinator.syncBlocks(blocks.map { ($0.id, $0.revealPlainTextCount) }, generation: generation)
        stack.show(blocks) { [coordinator] block in
            MarkdownReveal(manager: coordinator.ensureManager(for: block.id), style: ChatUIKitBlock.revealStyle)
        }
        updateControls()
    }

    private func updateControls() {
        var configuration = play.configuration
        configuration?.title = task == nil ? (blockCount == 0 ? "Stream" : "Replay") : "Stop"
        play.configuration = configuration
        speed.isEnabled = task == nil
        status.text = blockCount == 0 ? nil : "\(blockCount) blocks"
    }
}
