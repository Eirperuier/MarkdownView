//
//  StreamRevealPerfPoC.swift
//  MarkdownTextKit
//
//  技术验证(PoC #2):证明长文 fade reveal 的【性能】可行。
//  关键:每帧只对"渐变窗口"内的十几个字符做 textStorage 局部属性更新
//  (复杂度 O(窗口)/帧),而不是 PoC #1 那种整串重建(O(全文)/帧)。
//  TextKit 只对被改属性的字形局部重绘,UITextView 始终可连续选中。
//
//  这是把"难点 2(长文不卡)"用能跑的代码证明:长文 + 逐字淡入应保持流畅。
//

#if canImport(UIKit) && DEBUG
import SwiftUI
import UIKit

@available(iOS 17.0, *)
public struct StreamRevealPerfPoC: View {
    private let text: String

    public init(text: String = Self.longSample) {
        self.text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PoC #2 · 长文(~\(text.count) 字)·每帧仅更新渐变窗口·可选中")
                .font(.caption)
                .foregroundStyle(.secondary)

            // TimelineView(.animation) 每帧驱动 → updateUIView 做增量更新
            TimelineView(.animation) { ctx in
                IncrementalRevealTextView(text: text, now: ctx.date)
            }
        }
        .padding()
    }

    public static let longSample = String(
        repeating: "这是用于压测长文逐字淡入性能的句子,验证每帧只更新渐变窗口而非整串重排,同时保持文本可连续选中。",
        count: 60
    )
}

/// 用 UITextView 直接承载,增量更新 textStorage 的字符 alpha。
@available(iOS 17.0, *)
private struct IncrementalRevealTextView: UIViewRepresentable {
    let text: String
    let now: Date
    var fadeWidth: Int = 12
    var charsPerSecond: Double = 90

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero

        let font = UIFont.preferredFont(forTextStyle: .body)
        textView.textStorage.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label.withAlphaComponent(0),
                ]
            )
        )
        context.coordinator.start = now
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.start == nil { coordinator.start = now }
        guard let start = coordinator.start else { return }

        let progress = now.timeIntervalSince(start) * charsPerSecond
        let total = (text as NSString).length
        let front = min(Int(progress), total)
        guard front > coordinator.lastFront else { return }

        // 只更新 [lastFront-fadeWidth, front) 这个窗口 —— O(窗口)/帧,不动已 settle 的前缀。
        let lower = max(0, coordinator.lastFront - fadeWidth)
        let storage = textView.textStorage
        storage.beginEditing()
        for index in lower..<front {
            let alpha = max(0, min(1, (progress - Double(index)) / Double(fadeWidth)))
            storage.addAttribute(
                .foregroundColor,
                value: UIColor.label.withAlphaComponent(alpha),
                range: NSRange(location: index, length: 1)
            )
        }
        storage.endEditing()
        coordinator.lastFront = front
    }

    final class Coordinator {
        var start: Date?
        var lastFront: Int = 0
    }
}

#Preview("FadeReveal PoC #2 · 长文性能") {
    StreamRevealPerfPoC()
}
#endif
