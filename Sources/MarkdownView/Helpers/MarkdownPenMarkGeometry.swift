//
//  MarkdownPenMarkGeometry.swift
//  MarkdownView
//
//  笔迹注记的几何:一个 span 在一行上的排版框(+ 基线)→ 若干笔(路径 + 填充/描边)。
//  两条管线共用这一份 —— SwiftUI Text 的 PenMarkPainter 与可选中管线的
//  SelectablePenMarkOverlay 只负责取行框、解析颜色、按透明度落笔,同一段文字画出同一笔迹。
//
//  下划线 / 删除线也在这里画:SwiftUI Text 只认单线与虚线样式(粗线、双线被忽略),
//  自己画两条管线才一致。
//

import CoreGraphics
import Foundation
import SwiftUI

/// 一笔:路径 + 画法。
struct PenMarkStroke {
    enum Mode {
        case fill
        case stroke(width: CGFloat, dash: [CGFloat], roundCap: Bool)
    }

    let path: CGPath
    let mode: Mode
}

/// `u` / `s` 的线型(`{style=…}`),不认识的值按单线画。
enum PenMarkLineStyle: String {
    case single, thick, double, dot, dash, dashdot, wavy

    init(token: String?) {
        switch token {
        case "dotted": self = .dot
        case "dashed": self = .dash
        case "dash-dot", "dashdotted": self = .dashdot
        case "bold", "heavy": self = .thick
        case let token?: self = PenMarkLineStyle(rawValue: token) ?? .single
        case nil: self = .single
        }
    }
}

enum PenMarkGeometry {
    /// 手绘笔(圈 / 波浪 / 方框)的线宽。
    static let penWidth: CGFloat = 1.8

    /// 笔迹越出文字排版框的绘制余量(圈画外扩 5 + 收尾渐松 + 波浪下探 + 线宽)。
    static let overhang: CGFloat = 10

    /// 该 kind 的默认颜色 token 与透明度(笔 0.72 保持"笔"感,荧光笔半透,排版线实色)。
    static func defaultInk(for kind: MarkdownPenMarkSyntax.Kind) -> (token: String, opacity: Double) {
        switch kind {
        case .circle, .wavy, .box: ("red", 0.72)
        case .marker: ("yellow", 0.4)
        case .u, .s, .color: ("foreground", 1)
        }
    }

    /// 一个 span 在一行上的笔迹。rect = 该行上 span 的排版框(行内字形的 ascent…descent),
    /// baseline = 该行基线 y。
    static func strokes(for mark: MarkdownPenMarkSyntax.Mark, in rect: CGRect, baseline: CGFloat) -> [PenMarkStroke] {
        let seed = mark.seed
        switch mark.kind {
        case .circle:
            return [pen(handDrawnEllipse(around: rect, seed: seed))]
        case .wavy:
            return [pen(handDrawnWave(under: rect, seed: seed))]
        case .box:
            return [pen(handDrawnBox(around: rect, seed: seed))]
        case .marker:
            return [PenMarkStroke(path: markerBand(over: rect, seed: seed), mode: .fill)]
        case .u:
            let y = baseline + max(1.5, (rect.maxY - baseline) * 0.45)
            return typographicLine(at: y, from: rect.minX, to: rect.maxX, ascent: baseline - rect.minY,
                                   style: PenMarkLineStyle(token: mark.style))
        case .s:
            let y = baseline - (baseline - rect.minY) * 0.29
            return typographicLine(at: y, from: rect.minX, to: rect.maxX, ascent: baseline - rect.minY,
                                   style: PenMarkLineStyle(token: mark.style))
        case .color:
            return []
        }
    }

    private static func pen(_ path: CGPath) -> PenMarkStroke {
        PenMarkStroke(path: path, mode: .stroke(width: penWidth, dash: [], roundCap: true))
    }

    /// 与 app 侧 HandDrawnAccents.handDrawnNoise 同款三层正弦伪噪声(参数一致,同 seed 同笔迹)。
    static func penNoise(_ t: Double, seed: Double) -> Double {
        sin(t * 3.1 + seed * 12.9) * 0.55
            + sin(t * 7.3 + seed * 4.7) * 0.3
            + sin(t * 13.7 + seed * 7.1) * 0.15
    }

    // MARK: - 手绘笔

    /// 手绘椭圆(参数对齐 app 侧 HandDrawnEllipseShape):左上起笔、一圈多 ~40° 重叠、
    /// 半径抖动且越画越松。外扩把字包进去。
    private static func handDrawnEllipse(around rect: CGRect, seed: Double) -> CGPath {
        let box = rect.insetBy(dx: -5, dy: -2.5)
        let center = CGPoint(x: box.midX, y: box.midY)
        let a = box.width / 2
        let b = box.height / 2
        let start = -Double.pi * 0.75
        let end = start + 2 * .pi + .pi * 0.22
        let samples = 84
        let path = CGMutablePath()
        for i in 0...samples {
            let progress = Double(i) / Double(samples)
            let t = start + (end - start) * progress
            let radiusScale = 1 + 0.045 * penNoise(t * 1.9, seed: seed) + 0.06 * progress
            let point = CGPoint(
                x: center.x + a * radiusScale * CGFloat(cos(t)),
                y: center.y + b * radiusScale * CGFloat(sin(t))
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// 贴排版框下沿的波浪线(参数对齐 app 侧 handDrawnUnderline)。
    private static func handDrawnWave(under rect: CGRect, seed: Double) -> CGPath {
        let path = CGMutablePath()
        let y0 = rect.maxY + 1.5
        var x = rect.minX
        var first = true
        while x <= rect.maxX {
            let y = y0 + 1.4 * sin(x / 9 * 2 * .pi + seed) + 0.7 * penNoise(Double(x) / 6, seed: seed)
            if first { path.move(to: CGPoint(x: x, y: y)); first = false }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
            x += 2.5
        }
        return path
    }

    /// 手绘方框:一笔四边,每边微抖,转角各出头一点、收笔压过起笔。
    private static func handDrawnBox(around rect: CGRect, seed: Double) -> CGPath {
        let box = rect.insetBy(dx: -3.5, dy: -1.5)
        let corners = [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ]
        let path = CGMutablePath()
        for side in 0..<4 {
            let from = corners[side]
            let to = corners[(side + 1) % 4]
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(hypot(dx, dy), 1)
            let ux = dx / length
            let uy = dy / length
            // 起笔略早、收笔出头;最后一边压过起点。
            let lead: CGFloat = side == 0 ? -1 : 0.5
            let tail: CGFloat = side == 3 ? 4 : 1.8
            let steps = max(4, Int(length / 6))
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let along = -lead + (length + lead + tail) * t
                let wobble = 0.7 * CGFloat(penNoise(Double(side) * 2.3 + Double(t) * 2.4, seed: seed))
                let point = CGPoint(
                    x: from.x + ux * along - uy * wobble,
                    y: from.y + uy * along + ux * wobble
                )
                if side == 0, i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        return path
    }

    /// 荧光笔一抹:比字高略矮的色带,上下沿微抖、两头斜切(笔头是斜的)。
    private static func markerBand(over rect: CGRect, seed: Double) -> CGPath {
        let height = rect.height
        let top = rect.minY + height * 0.1
        let bottom = rect.maxY - height * 0.02
        let left = rect.minX - 2
        let right = rect.maxX + 2
        let slant = min(3, height * 0.15)
        let path = CGMutablePath()
        let steps = max(2, Int((right - left) / 8))
        func edge(_ y: CGFloat, _ x: CGFloat, phase: Double) -> CGFloat {
            y + 0.6 * CGFloat(penNoise(Double(x) / 14 + phase, seed: seed))
        }
        path.move(to: CGPoint(x: left + slant, y: edge(top, left, phase: 0)))
        for i in 1...steps {
            let x = left + slant + (right - left) * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: min(x, right), y: edge(top, x, phase: 0)))
        }
        path.addLine(to: CGPoint(x: right - slant, y: edge(bottom, right, phase: 1.7)))
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let x = left + (right - left - slant) * CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x, y: edge(bottom, x, phase: 1.7)))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - 排版线(下划线 / 删除线)

    private static func typographicLine(
        at y: CGFloat,
        from minX: CGFloat,
        to maxX: CGFloat,
        ascent: CGFloat,
        style: PenMarkLineStyle
    ) -> [PenMarkStroke] {
        let thin = max(1, ascent * 0.07)
        func line(_ y: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: minX, y: y))
            path.addLine(to: CGPoint(x: maxX, y: y))
            return path
        }
        switch style {
        case .single:
            return [PenMarkStroke(path: line(y), mode: .stroke(width: thin, dash: [], roundCap: false))]
        case .thick:
            return [PenMarkStroke(path: line(y + thin / 2), mode: .stroke(width: thin * 2, dash: [], roundCap: false))]
        case .double:
            return [
                PenMarkStroke(path: line(y), mode: .stroke(width: thin, dash: [], roundCap: false)),
                PenMarkStroke(path: line(y + thin * 2.2), mode: .stroke(width: thin, dash: [], roundCap: false)),
            ]
        case .dot:
            return [PenMarkStroke(path: line(y), mode: .stroke(width: thin * 1.4, dash: [0, thin * 3.2], roundCap: true))]
        case .dash:
            return [PenMarkStroke(path: line(y), mode: .stroke(width: thin, dash: [thin * 4, thin * 2.5], roundCap: false))]
        case .dashdot:
            return [PenMarkStroke(path: line(y), mode: .stroke(
                width: thin * 1.2, dash: [thin * 4.5, thin * 2.5, 0, thin * 2.5], roundCap: true))]
        case .wavy:
            let path = CGMutablePath()
            let amplitude = thin * 1.1
            let wavelength = max(4, thin * 4.5)
            var x = minX
            path.move(to: CGPoint(x: x, y: y + amplitude))
            while x < maxX {
                x = min(maxX, x + 1)
                let yy = y + amplitude + amplitude * CGFloat(sin(Double((x - minX) / wavelength) * 2 * .pi))
                path.addLine(to: CGPoint(x: x, y: yy))
            }
            return [PenMarkStroke(path: path, mode: .stroke(width: thin, dash: [], roundCap: true))]
        }
    }
}

/// 颜色 token(`{color=…}` / `{c=…}`)→ 颜色。两条管线与 `:color[…]` 共用;
/// 系统色是动态色,深浅色切换时绘制层自然换色(不烤死在缓存里)。
enum MarkdownPenInk {
    /// named / 语义 / #hex。`accent` 与 `foreground` 由调用方按自己的上下文解析(返回 nil)。
    static func color(_ token: String) -> Color? {
        switch token {
        case "red", "negative", "error", "danger": .red
        case "orange", "warning": .orange
        case "yellow": .yellow
        case "green", "positive", "success": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue", "info": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray", "grey": .gray
        case "secondary": .secondary
        case "primary": .primary
        case let hex where hex.hasPrefix("#"): hexColor(hex)
        default: nil
        }
    }

    /// `:color[…]` 的文字色:认得的 token 才上色,不认得的照常文字(不报错、不吞字)。
    static func textColor(_ token: String?) -> Color? {
        guard let token else { return nil }
        if token == "accent" { return .accentColor }
        return color(token)
    }

    static func hexColor(_ token: String) -> Color? {
        var hex = String(token.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
