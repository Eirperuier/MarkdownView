//
//  ChatControlRow.swift
//  DemoApp
//
//  What the list costs with no Markdown in it, to tell Markdown's share of a frame:
//  `-chatRowControl empty` rows are a filled view, `label` rows a UILabel of the block's source.
//  Heights come from the text's length or the label, so rows are about as tall as real ones.
//

import FlooUIKit
import MarkdownView
import MessagingUI
import UIKit

enum ChatRowControl: String {
    case empty, label

    static let current = UserDefaults.standard.string(forKey: "chatRowControl").flatMap(ChatRowControl.init(rawValue:))
}

@MainActor
struct ChatControlRow: TiledUIKitCellContent {
    let source: String
    let control: ChatRowControl

    static func makeRowView() -> ChatControlRowView {
        ChatControlRowView()
    }

    func configure(_ view: ChatControlRowView, context: TiledUIKitCellContext) {
        view.show(source: control == .label ? source : nil)
    }

    func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        switch control {
        case .empty:
            let room = max(1, ChatUIKitRowLayout.textWidth(in: width))
            let lines = (CGFloat(source.count) * 8 / room).rounded(.up)
            return max(1, lines) * 25 + ChatUIKitRowLayout.verticalPadding * 2
        case .label:
            return ChatControlHeights.height(of: source, width: width, traits: traits)
        }
    }
}

@MainActor
enum ChatControlHeights {
    private struct Key: Hashable {
        let source: String
        let width: CGFloat
    }

    private static var heights: [Key: CGFloat] = [:]
    private static let label = {
        let label = UILabel()
        label.numberOfLines = 0
        return label
    }()

    static func height(of source: String, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let key = Key(source: source, width: width)
        if let height = heights[key] { return height }
        label.font = .preferredFont(forTextStyle: .body, compatibleWith: traits)
        label.text = source
        let room = ChatUIKitRowLayout.textWidth(in: width)
        let height = label.sizeThatFits(CGSize(width: room, height: .greatestFiniteMagnitude)).height.rounded(.up)
            + ChatUIKitRowLayout.verticalPadding * 2
        heights[key] = height
        return height
    }
}

@MainActor
final class ChatControlRowView: UIView {
    private let fill = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.backgroundColor = .floo(.controlFill)
        label.numberOfLines = 0
        label.textColor = .floo(.label)
        addSubview(fill)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(source: String?) {
        label.isHidden = source == nil
        fill.isHidden = source != nil
        label.text = source
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        if label.font != font { label.font = font }
        let room = ChatUIKitRowLayout.textWidth(in: bounds.width)
        let frame = CGRect(x: (bounds.width - room) / 2, y: ChatUIKitRowLayout.verticalPadding, width: room, height: max(0, bounds.height - ChatUIKitRowLayout.verticalPadding * 2))
        fill.frame = frame
        label.frame = frame
    }
}
