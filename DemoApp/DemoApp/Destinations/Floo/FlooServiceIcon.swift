//
//  FlooServiceIcon.swift
//  DemoApp
//
//  A service's icon drawn as iOS draws an app's (floo docs/app.md 3.1). The definition names
//  a remote image; a whole icon (opaque to its corners, like Apple's apps') is only masked,
//  a logo (transparent around, like Composio's) is set on a plate first. In dark mode the
//  plate turns dark and a dark, colourless logo (GitHub's) turns white.
//

import CardUI
import SwiftUI
import UIKit

/// iOS's icon shape: a continuous rounded square, its radius 22.37% of the side.
struct FlooIconShape: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: rect.width * 0.2237, style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> FlooIconShape { FlooIconShape(inset: inset + amount) }
}

struct FlooServiceIcon: View {
    let url: URL?
    /// Drawn while it loads, or when there is none: the name's first letter on its colour.
    let name: String
    let tint: Color
    var size: CGFloat = 40

    @Environment(\.colorScheme) private var scheme
    @State private var icon: FlooIconImage?

    var body: some View {
        ZStack {
            switch icon?.kind {
            case .whole?:
                Image(uiImage: icon!.image).resizable().scaledToFill()
            case .logo(let darkAndPlain)?:
                (scheme == .dark ? Color(white: 0.17) : Color.white)
                if scheme == .dark && darkAndPlain {
                    Image(uiImage: icon!.image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(.white)
                        .padding(size * 0.18)
                } else {
                    Image(uiImage: icon!.image).resizable().scaledToFit().padding(size * 0.18)
                }
            case nil:
                Rectangle().fill(tint.gradient)
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(FlooIconShape())
        // A white plate on a white list needs its edge, as iOS gives white icons one.
        .overlay(FlooIconShape().stroke(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1), lineWidth: 0.5))
        .task(id: url) {
            guard let url else { return }
            icon = await FlooIconLoader.shared.icon(at: url)
        }
    }
}

/// iOS Settings' glyph icons, for rows that aren't a service (添加服务, 新的服务, 管家).
struct FlooGlyphIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: FlooIconShape())
    }
}

/// A loaded icon and what kind it is.
struct FlooIconImage: @unchecked Sendable {
    // SAFETY: UIImage is immutable once made; it is only read after loading.
    enum Kind: Equatable {
        case whole
        /// `darkAndPlain`: its ink is dark and nearly colourless, so it vanishes on a dark plate.
        case logo(darkAndPlain: Bool)
    }

    let image: UIImage
    let kind: Kind
    /// Its most common vivid colour, for a page's backdrop when the definition gives none;
    /// nil for a colourless logo.
    var tint: UIColor? = nil

    /// Looks at the image once, at 32 × 32: its four corners' opacity, and its ink's
    /// brightness and colour.
    init?(data: Data) {
        guard let image = UIImage(data: data), let cg = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * side + x) * 4 + 3] }
        let corners = [alpha(0, 0), alpha(side - 1, 0), alpha(0, side - 1), alpha(side - 1, side - 1)]
        self.image = image
        tint = Self.dominant(pixels)
        if corners.allSatisfy({ $0 > 240 }) {
            kind = .whole
            return
        }
        var ink = 0.0, brightness = 0.0, colour = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 128 {
            let a = Double(pixels[index + 3])
            let (r, g, b) = (Double(pixels[index]) / a, Double(pixels[index + 1]) / a, Double(pixels[index + 2]) / a)
            ink += 1
            brightness += 0.2126 * r + 0.7152 * g + 0.0722 * b
            colour += max(r, g, b) - min(r, g, b)
        }
        let plain = ink > 0 && brightness / ink < 0.3 && colour / ink < 0.12
        kind = .logo(darkAndPlain: plain)
    }

    /// The vivid pixels' hues in twelve bins; the fullest bin's average colour.
    private static func dominant(_ pixels: [UInt8]) -> UIColor? {
        var bins = [(count: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 12)
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let a = Double(pixels[index + 3])
            let (r, g, b) = (Double(pixels[index]) / a, Double(pixels[index + 1]) / a, Double(pixels[index + 2]) / a)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.35, brightness > 0.3 else { continue }
            let bin = min(Int(hue * 12), 11)
            bins[bin].count += 1
            bins[bin].r += r
            bins[bin].g += g
            bins[bin].b += b
        }
        guard let best = bins.max(by: { $0.count < $1.count }), best.count >= 8 else { return nil }
        return UIColor(red: best.r / best.count, green: best.g / best.count, blue: best.b / best.count, alpha: 1)
    }
}

/// Each icon as drawn, from its bytes as ``Assets`` has them (the app's own copy of a device
/// service's, else the server's), read once.
actor FlooIconLoader {
    static let shared = FlooIconLoader()
    private var loaded: [URL: FlooIconImage] = [:]

    func icon(at url: URL) async -> FlooIconImage? {
        if let icon = loaded[url] { return icon }
        // Nil: none, or not reached now; the letter stands in. A picture the person chose
        // (FlooAgentLooks) comes as its bytes, `data:<type>;base64,…`.
        let inline = url.scheme == "data" ? url.absoluteString.split(separator: ",", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) } : nil
        let fetched = inline == nil ? await Assets.data(url.absoluteString) : inline
        guard let data = fetched, let icon = FlooIconImage(data: data) else { return nil }
        loaded[url] = icon
        return icon
    }
}
