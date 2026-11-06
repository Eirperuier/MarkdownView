//
//  CatalogThemeProbe.swift
//  DemoApp
//
//  Does a text view's picture follow the theme with nothing laid out again?
//      -openTab catalog -catalogThemeProbe YES
//

import FlooUIKit
import MarkdownUIKit
import RichTextCore
import UIKit

@MainActor
enum CatalogThemeProbe {
    static func runIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "catalogThemeProbe") else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 400)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.rootViewController = root
        window.isHidden = false

        let textView = InlineAttachmentTextView(usingTextLayoutManager: true)
        textView.configureForDisplay()
        textView.defaultForegroundColor = .floo(.markdownText)
        textView.redrawsOnChange(of: MarkdownColorTraits.all)
        textView.frame = CGRect(x: 20, y: 200, width: 380, height: 120)
        root.view.addSubview(textView)
        let font = UIFont.systemFont(ofSize: 22, weight: .bold)
        let text = NSMutableAttributedString(string: "Text with no colour ", attributes: [.font: font])
        text.append(NSAttributedString(string: "named role ", attributes: [.font: font, .foregroundColor: UIColor.floo(.markdownSecondaryText)]))
        text.append(NSAttributedString(string: "a link ", attributes: [.font: font, .foregroundColor: UIColor.floo(.markdownLink), .link: URL(string: "https://example.com")!]))
        text.append(NSAttributedString(string: "marked", attributes: [.font: font, .underlineColor: UIColor.floo(.markdownLink)]))
        textView.applyContent(text)
        try? await Task.sleep(for: .milliseconds(400))

        let manager = textView.textLayoutManager!
        let fragment = manager.textLayoutFragment(for: manager.documentRange.location)
        let before = shot(window)
        print("THEMEPROBE fg before", textView.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as Any)

        let theme = FlooTheme.system.setting([.label: UIColor.systemPink, .secondaryLabel: UIColor.systemGreen, .accent: UIColor.systemOrange])
        for (name, set) in [
            ("window", { window.traitOverrides.flooTheme = theme }),
            ("back", { window.traitOverrides.flooTheme = .system }),
            ("view", { textView.traitOverrides.flooTheme = theme }),
        ] as [(String, () -> Void)] {
            set()
            try? await Task.sleep(for: .milliseconds(400))
            let after = shot(window)
            let same = manager.textLayoutFragment(for: manager.documentRange.location) === fragment
            print("THEMEPROBE", name, "changed px", diff(before, after), "same fragment", same, "sample", dominant(after))
        }
        window.isHidden = true
        exit(0)
    }

    private static func shot(_ window: UIWindow) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cg = image.cgImage!
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixels
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        stride(from: 0, to: min(a.count, b.count), by: 4).reduce(0) { $0 + (a[$1] != b[$1] || a[$1 + 1] != b[$1 + 1] || a[$1 + 2] != b[$1 + 2] ? 1 : 0) }
    }

    /// The most saturated pixels' colours, to see which colours are on screen.
    private static func dominant(_ a: [UInt8]) -> String {
        var counts: [String: Int] = [:]
        for i in stride(from: 0, to: a.count, by: 4) {
            let (r, g, b) = (Int(a[i]), Int(a[i + 1]), Int(a[i + 2]))
            guard max(r, g, b) - min(r, g, b) > 100 else { continue }
            counts["\(r),\(g),\(b)", default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}
