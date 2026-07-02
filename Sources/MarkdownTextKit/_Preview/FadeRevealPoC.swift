//
//  FadeRevealPoC.swift
//  MarkdownTextKit
//
//  技术验证(PoC #1):证明魔改 fade reveal 的【完整视觉】——
//  逐字 alpha 淡入 + 颜色叠加过渡(tint hue trail → settle 回正文色)——
//  与【连续文本选择】能在 RichText 的单一 UITextView 容器里共存。
//
//  魔改原版用 SwiftUI 的 `TextRenderer`(RevealFadeRenderer)逐 glyph 画 alpha+颜色;
//  那是 SwiftUI Text 专属、UITextView 用不了。但它的算法是纯计算(age → 最终颜色),
//  这里把同一套算法的结果写进 AttributedString 的 foregroundColor,由单一 UITextView
//  渲染 —— 视觉等价,且文本始终在一个容器里,连续选择不受影响。
//
//  注:本 PoC 每帧整串重建(中等文本流畅),仅验证「机制 + 视觉成立」。
//  长文性能(尾部增量 / 直接操作 textStorage)由 PoC #2 单独验证。
//

#if canImport(RichText) && DEBUG
import SwiftUI
import RichText

@available(iOS 17.0, macOS 14.0, *)
@available(watchOS, unavailable)
@available(tvOS, unavailable)
@available(visionOS, unavailable)
public struct FadeRevealPoC: View {
    private let fullText: String
    /// alpha 淡入跨度(单位:字符),对应魔改的 duration。
    private let fadeWidth: Double
    /// 推进速度(字符/秒)。
    private let charsPerSecond: Double

    // 颜色过渡参数(对齐魔改 MarkdownFadeRevealConfig 默认值)
    private let startHue: Double = 30.0 / 360.0     // 橙
    private let endHue: Double = 270.0 / 360.0      // 紫
    private let hueSaturation: Double = 0.9
    private let hueBrightness: Double = 0.95
    private let overlayOpacity: Double = 0.5         // light 模式
    private let colorDurationMultiplier: Double = 1.8

    @State private var progress: Double = 0
    @State private var attributed = AttributedString()

    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    public init(
        text: String = Self.sample,
        fadeWidth: Double = 10,
        charsPerSecond: Double = 22
    ) {
        self.fullText = text
        self.fadeWidth = fadeWidth
        self.charsPerSecond = charsPerSecond
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PoC #1 · 逐字淡入 + 颜色过渡 + 全程可连续选中(单一 UITextView)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // RichText:底层是单一 InlineAttachmentTextView(UITextView),天然可连续选择。
            TextView(attributed)

            Button("重播") { progress = 0 }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding()
        .onAppear { rebuild() }
        .onReceive(timer) { _ in
            let total = Double(fullText.count)
            guard progress < total + fadeWidth * colorDurationMultiplier else { return }
            progress += charsPerSecond / 60.0
            rebuild()
        }
    }

    /// 按当前 progress 给每个字符算 alpha + 颜色过渡,写进 foregroundColor。
    ///  - age          = progress - 字符位置(单位:字符,模拟魔改的 firstSeen age)
    ///  - alpha        = clamp(age / fadeWidth, 0, 1)          —— 快速淡入
    ///  - colorSettle  = clamp(age / (fadeWidth×1.8), 0, 1)    —— 颜色衰减更慢
    ///  - 最终色       = blend(正文色, tint, overlayOpacity×(1-colorSettle)) 再乘 alpha
    private func rebuild() {
        let chars = Array(fullText)
        let colorSettleWidth = fadeWidth * colorDurationMultiplier
        var result = AttributedString()

        for (index, character) in chars.enumerated() {
            var piece = AttributedString(String(character))

            let age = progress - Double(index)
            let alpha = clamp(age / fadeWidth)
            let colorSettle = clamp(age / colorSettleWidth)

            // tint:沿 startHue→endHue 的 hue trail(short hue wheel,按位置走)
            let wave = (1 - cos(Double(index) / 5.0)) * 0.5
            let tintHue = normalizedHue(startHue + wave * (endHue - startHue))

            // overlay 量:刚出生时最强,settle 后归零(回到正文色)
            let overlay = overlayOpacity * (1 - colorSettle)
            piece.foregroundColor = composedColor(tintHue: tintHue, overlay: overlay, alpha: alpha)

            result.append(piece)
        }
        attributed = result
    }

    // MARK: - 颜色合成

    /// 把 tint(hue) 以 overlay 比例叠加在正文色上,再应用 alpha。
    private func composedColor(tintHue: Double, overlay: Double, alpha: Double) -> Color {
        #if canImport(UIKit)
        let ink = UIColor.label
        let tint = UIColor(hue: tintHue, saturation: hueSaturation, brightness: hueBrightness, alpha: 1)
        let blended = blend(ink, tint, amount: overlay)
        return Color(blended.withAlphaComponent(alpha))
        #else
        // macOS 退化:仅用 tint 透明度近似(PoC 主要在 iOS 模拟器验证)
        return Color(hue: tintHue, saturation: hueSaturation, brightness: hueBrightness).opacity(alpha)
        #endif
    }

    #if canImport(UIKit)
    /// result = ink×(1-amount) + tint×amount(线性 RGB 近似混合)
    private func blend(_ ink: UIColor, _ tint: UIColor, amount: Double) -> UIColor {
        var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        ink.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        tint.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let a = CGFloat(amount)
        return UIColor(
            red: ir * (1 - a) + tr * a,
            green: ig * (1 - a) + tg * a,
            blue: ib * (1 - a) + tb * a,
            alpha: 1
        )
    }
    #endif

    private func clamp(_ value: Double) -> Double { max(0, min(1, value)) }

    private func normalizedHue(_ hue: Double) -> Double {
        let n = hue.truncatingRemainder(dividingBy: 1)
        return n >= 0 ? n : n + 1
    }

    public static let sample = """
    这是一段用于验证「逐字淡入 + 颜色叠加过渡」与「连续选择」共存的示例文本。当文字像打字机一样逐渐浮现时,每个字诞生瞬间会带上一抹橙紫色调,随后在更长的时间里慢慢褪回正文颜色 —— 这就是颜色过渡。与此同时,你应当能够从这里一直拖动选中到段落末尾,中途不被打断,因为底层是同一个 UITextView 文本容器。
    """
}

#Preview("FadeReveal PoC #1 · 淡入+颜色") {
    FadeRevealPoC()
}
#endif
