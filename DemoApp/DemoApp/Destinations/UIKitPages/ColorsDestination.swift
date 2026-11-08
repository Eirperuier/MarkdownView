//
//  ColorsDestination.swift
//  DemoApp
//
//  Markdown's colour system: every role (MarkdownColorCatalog), each as it resolves under a
//  theme and an appearance, beside Markdown drawn in the same theme. Changing either recolours
//  both with nothing laid out again, as a theme does in the app.
//

import FlooUIKit
import MarkdownUIKit
import MarkdownView
import SwiftUI
import UIKit

struct ColorsDestination: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ColorsViewController { ColorsViewController() }
    func updateUIViewController(_ controller: ColorsViewController, context: Context) {}
}

@MainActor
final class ColorsViewController: UIViewController {
    private static let themes: [(name: String, theme: FlooTheme)] = [
        ("System", ChatUIKitBlock.theme),
        ("Accent", .accent(.systemOrange)),
        ("Tinted", .tinted(.systemPurple)),
        ("Surface", .surface(.systemTeal)),
    ]

    private let themePicker = UISegmentedControl(items: themes.map(\.name))
    private let appearancePicker = UISegmentedControl(items: ["Auto", "Light", "Dark"])
    private let page = UIView()
    private let scroll = UIScrollView()
    private let sample = MarkdownBlockStackView()
    private var headers: [UILabel] = []
    private var rows: [ColorRoleRow] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page's own colour too, so the whole page is in the theme, its bar as well.
        view.backgroundColor = .floo(.background)

        themePicker.selectedSegmentIndex = 0
        appearancePicker.selectedSegmentIndex = 0
        themePicker.addAction(UIAction { [weak self] _ in self?.applyTheme() }, for: .valueChanged)
        appearancePicker.addAction(UIAction { [weak self] _ in self?.applyTheme() }, for: .valueChanged)
        let bar = UIStackView(arrangedSubviews: [themePicker, appearancePicker])
        bar.spacing = 12
        bar.alignment = .center
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        let barScroll = addControlBar(bar)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: barScroll.bottomAnchor, constant: 8),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        page.addSubview(scroll)
        page.addSubview(sample)
        scroll.alwaysBounceVertical = true
        for group in MarkdownColorCatalog.groups {
            let header = UILabel()
            header.text = group.title.uppercased()
            header.font = .preferredFont(forTextStyle: .footnote)
            header.textColor = .floo(.sectionHeader)
            header.adjustsFontForContentSizeCategory = true
            scroll.addSubview(header)
            headers.append(header)
            for role in group.roles {
                let row = ColorRoleRow(role: role)
                scroll.addSubview(row)
                rows.append(row)
            }
        }
        var splitter = MarkdownBlockSplitter()
        sample.show(splitter.split(Self.sampleMarkdown))

        // Hex values are read under the page's traits: again whenever a colour could change.
        page.registerForTraitChanges(MarkdownColorTraits.all) { [weak self] (_: UIView, _: UITraitCollection) in
            self?.rows.forEach { $0.refresh() }
        }
        applyTheme()
    }

    private func applyTheme() {
        view.traitOverrides.flooTheme = Self.themes[max(0, themePicker.selectedSegmentIndex)].theme
        view.overrideUserInterfaceStyle = [.unspecified, .light, .dark][max(0, appearancePicker.selectedSegmentIndex)]
        rows.forEach { $0.refresh() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = page.bounds
        // Side by side when there's room for both; the sample above the roles when not.
        let wide = bounds.width >= 820
        let listWidth = wide ? min(420, bounds.width * 0.45) : bounds.width
        scroll.frame = wide ? CGRect(x: 0, y: 0, width: listWidth, height: bounds.height)
            : CGRect(x: 0, y: bounds.height * 0.45, width: bounds.width, height: bounds.height * 0.55)
        sample.frame = wide ? CGRect(x: listWidth, y: 0, width: bounds.width - listWidth, height: bounds.height)
            : CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.45)

        var y: CGFloat = 12
        var rowIndex = 0
        for (index, group) in MarkdownColorCatalog.groups.enumerated() {
            let header = headers[index]
            let headerHeight = ceil(header.sizeThatFits(CGSize(width: listWidth - 32, height: .greatestFiniteMagnitude)).height)
            header.frame = CGRect(x: 16, y: y + 8, width: listWidth - 32, height: headerHeight)
            y = header.frame.maxY + 6
            for _ in group.roles {
                let row = rows[rowIndex]
                row.frame = CGRect(x: 16, y: y, width: listWidth - 32, height: ColorRoleRow.height)
                y = row.frame.maxY
                rowIndex += 1
            }
        }
        scroll.contentSize = CGSize(width: listWidth, height: y + 16)
    }

    /// What uses the roles: text, code, lists, quotes, tables, formulas, marks.
    private static let sampleMarkdown = """
    ## A heading with **strong** words
    A paragraph with a [link](https://example.com), `inline code`, ==a highlight==, a formula $e^{i\\pi} + 1 = 0$ and a footnote[^1].

    Some :u[underlined] and :circle[circled] words.

    - A bullet
    - [x] A done task
    - [ ] A task to do
    1. A number

    > A quote with *emphasis* in it.

    > [!tip] A callout
    > Its body.

    | Name | Value |
    | --- | --- |
    | One | 1 |
    | Two | 2 |
    | Three | 3 |

    ```swift
    let answer = 42 // a comment
    print("The answer is \\(answer)")
    ```

    ---

    [^1]: A footnote's text.
    """
}

/// A role: its colour as it resolves here, its name, and its value.
@MainActor
private final class ColorRoleRow: UIView {
    static let height: CGFloat = 40
    private let role: FlooColorRole
    private let swatch = UIView()
    private let name = UILabel()
    private let value = UILabel()

    init(role: FlooColorRole) {
        self.role = role
        super.init(frame: .zero)
        swatch.backgroundColor = .floo(role)
        swatch.layer.cornerRadius = 7
        swatch.layer.cornerCurve = .continuous
        swatch.layer.borderWidth = 1
        name.text = role.name
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.textColor = .floo(.label)
        value.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        value.textColor = .floo(.secondaryLabel)
        value.textAlignment = .right
        [swatch, name, value].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        let color = UIColor.floo(role).resolvedColor(with: traitCollection)
        value.text = Self.hex(color)
        swatch.layer.borderColor = UIColor.floo(.separator).resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 26
        swatch.frame = CGRect(x: 0, y: (bounds.height - side) / 2, width: side, height: side)
        let valueWidth: CGFloat = 96
        value.frame = CGRect(x: bounds.width - valueWidth, y: 0, width: valueWidth, height: bounds.height)
        name.frame = CGRect(x: side + 12, y: 0, width: max(0, bounds.width - side - 12 - valueWidth - 8), height: bounds.height)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refresh()
    }

    private static func hex(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "—" }
        let channel = { (value: CGFloat) in Int((min(1, max(0, value)) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
        return alpha < 0.995 ? rgb + String(format: " %d%%", Int((alpha * 100).rounded())) : rgb
    }
}
