import CardRuntime
import MarkdownView
import SwiftUI

/// A bench for Markdown's colors on a background: pick one and the sample is drawn in the
/// text colors ReadableColor works out for it, as a card's are, tinted with its hue.
struct TintDestination: View {
    @AppStorage("tintBenchBase") private var hex = "#0B4A94"
    @AppStorage("tintBenchSelectable") private var selectable = true
    @State private var draft = ""

    private var base: SRGBColor { SRGBColor(hex: hex) ?? SRGBColor(red: 1, green: 1, blue: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            readout
            sample
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { draft = hex }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ColorPicker("Background", selection: picked, supportsOpacity: false)
                    .fixedSize()
                TextField("#RRGGBB", text: $draft)
                    .monospaced()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .onSubmit { if let color = SRGBColor(hex: draft) { hex = color.hex } else { draft = hex } }
                Spacer(minLength: 0)
                Picker("Renderer", selection: $selectable) {
                    Text("Selectable").tag(true)
                    Text("SwiftUI").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { preset in
                    Button { hex = preset } label: {
                        Circle()
                            .fill(Color(SRGBColor(hex: preset) ?? base))
                            .overlay(Circle().strokeBorder(.separator))
                            .padding(2)
                            .overlay(Circle().strokeBorder(preset == hex ? Color.primary : .clear, lineWidth: 1.5))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(preset)
                    .accessibilityLabel(preset)
                }
            }
        }
    }

    /// Each color worked out, with its APCA contrast on the background; red where the
    /// background can't carry the contrast asked for.
    private var readout: some View {
        let palette = ReadableColor.palette(on: base)
        return HStack(spacing: 20) {
            swatch("Primary", palette.primary)
            swatch("Secondary", palette.secondary)
            swatch("Tertiary", palette.tertiary)
            swatch("Accent", ReadableColor.accent(on: base), contrast: nil)
        }
        .font(.caption.monospacedDigit())
    }

    private func swatch(_ name: String, _ text: ReadableColor.Text) -> some View {
        swatch(name, text.color, contrast: (text.contrast, text.meetsTarget))
    }

    private func swatch(_ name: String, _ color: SRGBColor, contrast: (value: Double, meets: Bool)?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(color))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                .frame(width: 16, height: 16)
            Text(name)
            Text(color.hex).foregroundStyle(.secondary)
            if let contrast {
                Text("Lc \(Int(contrast.value.rounded()))")
                    .foregroundStyle(contrast.meets ? Color.secondary : Color.red)
            }
        }
    }

    @ViewBuilder
    private var rendered: some View {
        if selectable {
            // Blocks spaced as the Streaming page's, and as MarkdownView spaces its own.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.blocks) { block in
                    MarkdownStreamBlockView(block)
                        .markdownDisplayMathRendersSynchronously()
                        .markdownFootnotes(Self.footnotes.footnotes(
                            for: block.id,
                            referenceURL: { URL(string: "demo-footnote://ref/\($0)") },
                            definitionURL: { URL(string: "demo-footnote://def/\($0)") },
                            inlineURL: { URL(string: "demo-footnote://inline/\($0)") }
                        ))
                }
            }
        } else {
            MarkdownView(Self.text)
        }
    }

    private var sample: some View {
        rendered
            .markdownMathRenderingEnabled()
            .markdownTableScrollable()
            .codeBlockStyle(DocCodeBlockStyle())
            .markdownLinkSiteIcons()
            .markdownColors(MarkdownColors(readableOn: base))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(base), in: .rect(cornerRadius: 18))
    }

    private var picked: Binding<Color> {
        Binding(get: { Color(base) }, set: { hex = SRGBColor($0).hex })
    }

    /// Light and dark, gray and vivid, across the hues.
    private static let presets = [
        "#FFFFFF", "#F2EFE6", "#E5E5EA", "#FFD60A", "#FF8FB1", "#8EC5FF", "#34C759",
        "#FF6A00", "#C0392B", "#5E2CA5", "#0B4A94", "#1C1C1E", "#000000",
    ]

    private static let text = #"""
        # 一级标题
        ## 二级标题

        正文里有**粗体**、*斜体*、~~删除线~~、`行内代码`、[一个链接](https://example.com)，还有行内公式 $E = mc^2$。

        - 无序列表第一项
        - 第二项
          - 嵌套的一项
        1. 有序列表第一步
        2. 第二步

        - [x] 已完成的任务
        - [ ] 未完成的任务

        > 引用块里的文字，带一个[链接](https://example.com)和`代码`。

        | 名称 | 数量 | 时间 |
        |---|---:|---|
        | 苹果 | 3 | 09:30 |
        | 香蕉 | 12 | 14:05 |
        | 橙子 | 7 | 20:40 |

        ```swift
        // Counts what's in stock
        let items = [Item(name: "苹果", count: 3), Item(name: "香蕉", count: 12)]
        let total = items.reduce(0) { $0 + $1.count }
        print("Total: \(total)", 0.5 * Double(total))
        ```

        $$
        \int_0^1 x^2\,dx = \frac{1}{3}
        $$

        链接：[GitHub](https://github.com/apple/swift)、[维基百科](https://zh.wikipedia.org/wiki/Swift)、[一个没有图标的站](https://no-such-site.invalid/page)。

        裸链接 https://www.apple.com 和一个脚注[^1]。

        ---

        [^1]: 脚注的内容。
        """#

    private static let blocks: [MarkdownStreamBlock] = {
        var splitter = MarkdownBlockSplitter()
        return splitter.split(text)
    }()

    private static let footnotes = MarkdownFootnoteIndex.build(blocks: blocks)
}
