//
//  CatalogThemeProbe.swift
//  DemoApp
//
//  Does everything Markdown draws follow the theme with nothing laid out again? One document on
//  the real renderer, an element a block, in a window. It flips the window's theme, says for each
//  element how many pixels changed, whether its layout fragments stayed, and how its ink reads on
//  its ground; going back to the system's theme has to change nothing.
//      -openTab catalog -catalogThemeProbe YES [-catalogThemeOut <dir>] [-catalogDark YES]
//

import FlooUIKit
import MarkdownUIKit
import MarkdownView
import UIKit

/// A host's directive: its colours are the role's it asks for.
@MainActor
private final class CatalogProbeDirective: UIView {
    init() {
        super.init(frame: .zero)
        backgroundColor = .floo(.accent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 120, height: 30) }
}

@MainActor
enum CatalogThemeProbe {
    private static let elements: [(name: String, markdown: String)] = [
        // First: the document is taller than the window's picture.
        ("table", tableSource),
        ("table.scrolls", tableSource),
        ("table.github", tableSource),
        ("table.grid", tableSource),
        ("table.touched", tableSource),
        ("text", "Plain body text."),
        ("link", "[A link](https://example.com) in text."),
        ("strong", "Some **bold** text."),
        ("code", "Some `inline code` here."),
        ("quote", "> A quote with **bold** and [a link](https://example.com)."),
        ("chip", "[Apple](https://\(CatalogImages.host)/a \"cite\") [Swift](https://\(CatalogImages.host)/b \"cite\")"),
        ("chip.noicon", "[Plain](https://noicon.test/a \"cite\")"),
        ("site.icon", "Read [the docs](https://\(CatalogImages.host)/docs) today."),
        ("site.globe", "Read [the blog](https://noicon.test/blog) today."),
        ("math.inline", "Area \\(\\pi r^2\\) and $x^2 + y^2 = z^2$ here."),
        ("math.inline.color", "Baked \\(\\textcolor{red}{a} + b\\) here."),
        ("math.display", "$$\n\\int_0^\\infty e^{-x^2} dx\n$$"),
        ("math.display.color", "$$\n\\textcolor{red}{x} + y\n$$"),
        ("mark.underline", ":u[An underline] in text."),
        ("mark.marker", ":marker[A marker] in text."),
        ("bullet", "- A bullet\n- {star.fill} A symbol"),
        ("task", "- [x] Done\n- [ ] To do"),
        ("callout", "> [!note]\n> A note."),
        ("code.block", "```swift\n// A comment\nlet name = \"text\"\nfunc f(_ x: Int) -> Int { x + 1 }\n```"),
        ("code.more", "```python\n" + (1...17).map { "print(\"line \($0)\")" }.joined(separator: "\n") + "\n```"),
        ("code.badge", "```kotlin\nval a = 1\n```"),
        ("code.quote", "> Quoted\n>\n> ```swift\n> let x = 1\n> ```"),
        ("code.item", "- An item\n  ```swift\n  let x = 1\n  ```"),
        ("rule", "---"),
        ("html", "<div>\nSome html\n</div>"),
        ("directive", "@note {\nA note.\n}"),
        ("image.caption", "![A caption](https://\(CatalogImages.host)/square.png)"),
        ("image.failed", "![Missing](https://\(CatalogImages.host)/missing.png)"),
        ("image.fallback", "![A description](square.png)"),
    ]

    private static let tableSource = "| Name | **Bold** |\n| --- | --- |\n| [A link](https://example.com) | `code` |\n| Plain | Words |\n| More | Words |"

    /// A table's look under its name; anything else the probe's own.
    private static func style(for element: String, base: MarkdownStyle) -> MarkdownStyle {
        var style = base
        switch element {
        case "table.scrolls": style.table.scrollsSideways = true
        case "table.github": style.table.look = .github
        case "table.grid": style.table.look = .grid
        default: break
        }
        return style
    }

    private struct Block {
        let name: String
        let view: MarkdownUIKit.MarkdownBlockView
        var crop: CGRect
    }

    static func runIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "catalogThemeProbe") else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let folder = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "catalogThemeOut") ?? NSTemporaryDirectory() + "catalog-theme")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dark = UserDefaults.standard.bool(forKey: "catalogDark")
        let width: CGFloat = 420
        let top: CGFloat = 160
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.frame = CGRect(x: 0, y: 0, width: width, height: 2400)
        let root = UIViewController()
        // What text is worked out to read on: rows, over a page. On the Mac the rows are a veil.
        root.view.backgroundColor = .systemBackground
        let rows = UIView(frame: window.bounds)
        rows.backgroundColor = .floo(.rowFill)
        root.view.addSubview(rows)
        window.rootViewController = root
        window.isHidden = false

        var style = MarkdownStyle()
        style.rendersDisplayMathSynchronously = true
        style.linkSiteIcons = true
        style.codeBlock.highlighter = MarkdownHighlightrHighlighter()
        style.icons = MarkdownIcons(image: { host in
            host == "noicon.test" ? nil : UIImage(systemName: "seal.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 64))
        })
        style.blockDirectives["note"] = { _ in CatalogProbeDirective() }
        // Images known first: each block's height, and so its crop, is its last.
        let loading = elements.flatMap { element -> [MarkdownUIKit.MarkdownBlockView] in
            var splitter = MarkdownBlockSplitter()
            return splitter.split(element.markdown).map { block in
                let view = MarkdownUIKit.MarkdownBlockView()
                view.configure(block, style: style)
                return view
            }
        }
        try? await Task.sleep(for: .milliseconds(800))
        withExtendedLifetime(loading) {}
        var blocks: [Block] = []
        var y = top
        for element in elements {
            var splitter = MarkdownBlockSplitter()
            for block in splitter.split(element.markdown) {
                let view = MarkdownUIKit.MarkdownBlockView()
                view.configure(block, style: Self.style(for: element.name, base: style))
                root.view.addSubview(view)
                let height = view.height(forWidth: width - 40)
                view.frame = CGRect(x: 20, y: y, width: width - 40, height: height)
                if element.name == "table.touched" {
                    // Its cells' colours in text views too: their fragments must stay.
                    view.layoutIfNeeded()
                    view.tableView?.showAllCellsInTextViews()
                }
                blocks.append(Block(name: element.name, view: view, crop: CGRect(x: 0, y: y, width: width, height: height)))
                y += height + 6
            }
        }
        let height = y + 20 - top
        let area = CGRect(x: 0, y: top, width: width, height: height)
        // Laid out, not yet highlighted: a highlight coming in must keep the fragments.
        root.view.layoutIfNeeded()
        let beforeHighlight = blocks.map { fragmentIDs(in: $0.view) }
        try? await Task.sleep(for: .milliseconds(3000))

        var report = "== highlight\n"
        for (index, block) in blocks.enumerated() where block.name.hasPrefix("code.") {
            report += "\(block.name): same fragments \(fragmentIDs(in: block.view) == beforeHighlight[index]), \(beforeHighlight[index].count) fragments\n"
        }
        let first = shot(window, area)
        save(first, "system", in: folder)
        let fragments = blocks.map { fragmentIDs(in: $0.view) }

        let flips: [(String, FlooTheme)] = [
            ("label+secondary+accent", FlooTheme.system.setting([.label: UIColor.systemPink, .secondaryLabel: UIColor.systemGreen, .accent: UIColor.systemOrange])),
            ("surface-orange", FlooTheme.surface(.systemOrange)),
            ("surface-blue", FlooTheme.surface(.systemBlue)),
            ("surface-yellow", FlooTheme.surface(.systemYellow)),
            ("tinted-indigo", FlooTheme.tinted(.systemIndigo)),
            ("tinted-green", FlooTheme.tinted(.systemGreen)),
        ]
        for (name, theme) in flips {
            window.traitOverrides.flooTheme = theme
            try? await Task.sleep(for: .milliseconds(500))
            let flipped = shot(window, area)
            save(flipped, name, in: folder)
            report += "== \(name)\n"
            for (index, block) in blocks.enumerated() {
                let box = block.crop.offsetBy(dx: 0, dy: -top)
                let changed = difference(first, flipped, in: box)
                let same = fragmentIDs(in: block.view) == fragments[index]
                report += "\(block.name): changed \(changed) px, same fragments \(same), contrast \(String(format: "%.1f", contrast(flipped, in: box)))\n"
            }
            window.traitOverrides.flooTheme = .system
            try? await Task.sleep(for: .milliseconds(500))
            let back = shot(window, area)
            report += "back to system: \(difference(first, back, in: CGRect(origin: .zero, size: area.size))) px differ\n"
        }
        report += "== system contrast\n"
        for block in blocks {
            report += "\(block.name): \(String(format: "%.1f", contrast(first, in: block.crop.offsetBy(dx: 0, dy: -top))))\n"
        }
        print(report)
        try? report.write(to: folder.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        window.isHidden = true
        exit(0)
    }

    private static func fragmentIDs(in view: MarkdownUIKit.MarkdownBlockView) -> [ObjectIdentifier] {
        view.textViews.flatMap { textView -> [ObjectIdentifier] in
            guard let manager = textView.textLayoutManager else { return [] }
            var ids: [ObjectIdentifier] = []
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
                ids.append(ObjectIdentifier(fragment))
                return true
            }
            return ids
        }
    }

    private struct Picture {
        let width: Int
        let height: Int
        let scale: CGFloat
        let pixels: [UInt8]
        let image: UIImage
    }

    private static func shot(_ window: UIWindow, _ area: CGRect) -> Picture {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(size: area.size, format: format).image { _ in
            window.drawHierarchy(in: bounds.offsetBy(dx: -area.minX, dy: -area.minY), afterScreenUpdates: true)
        }
        let cg = image.cgImage!
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Picture(width: cg.width, height: cg.height, scale: format.scale, pixels: pixels, image: image)
    }

    private static func save(_ picture: Picture, _ name: String, in folder: URL) {
        try? picture.image.pngData()?.write(to: folder.appending(path: "\(name).png"))
    }

    private static func pixelRange(_ box: CGRect, in picture: Picture) -> (x: Range<Int>, y: Range<Int>) {
        let x0 = max(0, Int(box.minX * picture.scale)), x1 = min(picture.width, Int(box.maxX * picture.scale))
        let y0 = max(0, Int(box.minY * picture.scale)), y1 = min(picture.height, Int(box.maxY * picture.scale))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    private static func difference(_ a: Picture, _ b: Picture, in box: CGRect) -> Int {
        let range = pixelRange(box, in: a)
        var count = 0
        for y in range.y {
            for x in range.x {
                let i = (y * a.width + x) * 4
                if a.pixels[i] != b.pixels[i] || a.pixels[i + 1] != b.pixels[i + 1] || a.pixels[i + 2] != b.pixels[i + 2] { count += 1 }
            }
        }
        return count
    }

    /// WCAG contrast of the box's ground (its commonest colour) and the ink farthest from it.
    private static func contrast(_ picture: Picture, in box: CGRect) -> Double {
        let range = pixelRange(box, in: picture)
        var counts: [UInt32: Int] = [:]
        func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
            func linear(_ value: UInt8) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        for y in range.y {
            for x in range.x {
                let i = (y * picture.width + x) * 4
                let key = UInt32(picture.pixels[i]) << 16 | UInt32(picture.pixels[i + 1]) << 8 | UInt32(picture.pixels[i + 2])
                counts[key, default: 0] += 1
            }
        }
        guard let ground = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let groundL = luminance(UInt8(ground >> 16 & 255), UInt8(ground >> 8 & 255), UInt8(ground & 255))
        var best = 1.0
        // A few pixels aren't ink, they're noise: colours that show a little.
        for (key, count) in counts where count >= 6 {
            let l = luminance(UInt8(key >> 16 & 255), UInt8(key >> 8 & 255), UInt8(key & 255))
            best = max(best, (max(l, groundL) + 0.05) / (min(l, groundL) + 0.05))
        }
        return best
    }
}
