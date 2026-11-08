//
//  ColorsDestination.swift
//  DemoApp
//
//  Markdown's colour system: every role (MarkdownColorCatalog), each as it resolves under a
//  theme and an appearance, beside Markdown drawn in the same theme. Changing either recolours
//  both with nothing laid out again, as a theme does in the app. The sample shows the blocks,
//  or every highlight and pen mark in every named colour, with text on each.
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
    private let samplePicker = UISegmentedControl(items: ["Blocks", "Highlights", "Pens"])
    private let page = UIView()
    private let scroll = UIScrollView()
    private let sample = MarkdownBlockStackView()
    private var headers: [UILabel] = []
    private var rows: [ColorRoleRow] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        // The page's own colour too, so the whole page is in the theme, its bar as well.
        // On the Mac the role is clear and the window's own shows: a page in Light over a dark
        // window would draw dark text on dark. The system's page colour under it, in the
        // appearance chosen.
        view.backgroundColor = UIColor { traits in
            UIColor.floo(.background).resolvedColor(with: traits).composited(on: .systemBackground.resolvedColor(with: traits))
        }

        // `-colorsTheme 2 -colorsAppearance 2 -colorsSample 1` opens on those, to check by eye.
        let defaults = UserDefaults.standard
        themePicker.selectedSegmentIndex = min(defaults.integer(forKey: "colorsTheme"), Self.themes.count - 1)
        appearancePicker.selectedSegmentIndex = min(defaults.integer(forKey: "colorsAppearance"), 2)
        themePicker.addAction(UIAction { [weak self] _ in self?.applyTheme() }, for: .valueChanged)
        appearancePicker.addAction(UIAction { [weak self] _ in self?.applyTheme() }, for: .valueChanged)
        samplePicker.selectedSegmentIndex = min(defaults.integer(forKey: "colorsSample"), 2)
        samplePicker.addAction(UIAction { [weak self] _ in self?.showSample() }, for: .valueChanged)
        let bar = UIStackView(arrangedSubviews: [themePicker, appearancePicker, samplePicker])
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
        showSample()

        // Hex values are read under the page's traits: again whenever a colour could change.
        page.registerForTraitChanges(MarkdownColorTraits.all) { [weak self] (_: UIView, _: UITraitCollection) in
            self?.rows.forEach { $0.refresh() }
        }
        applyTheme()
    }

    private func showSample() {
        let markdown = [Self.sampleMarkdown, Self.highlightsMarkdown, Self.pensMarkdown][max(0, samplePicker.selectedSegmentIndex)]
        var splitter = MarkdownBlockSplitter()
        sample.show(splitter.split(markdown))
        sample.contentOffset = .zero
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

    /// Every highlight: the default, then each named colour as a ground, with the text in that
    /// colour on it, as a marker, and as text alone.
    private static let highlightsMarkdown = """
    ### Highlights
    ==The default highlight==, and ==**strong**, *emphasis*, [a link](https://example.com) and `code` on it==.

    ^[Text in the accent](color: accent) on ^[an accent highlight](highlight: accent, color: accent), and :marker[the default marker].

    - ^[gray highlight](highlight: gray), ^[in its colour](highlight: gray, color: gray), :marker[a gray marker]{color=gray} and ^[gray text](color: gray)
    - ^[slate highlight](highlight: slate), ^[in its colour](highlight: slate, color: slate), :marker[a slate marker]{color=slate} and ^[slate text](color: slate)
    - ^[purple highlight](highlight: purple), ^[in its colour](highlight: purple, color: purple), :marker[a purple marker]{color=purple} and ^[purple text](color: purple)
    - ^[blue highlight](highlight: blue), ^[in its colour](highlight: blue, color: blue), :marker[a blue marker]{color=blue} and ^[blue text](color: blue)
    - ^[cyan highlight](highlight: cyan), ^[in its colour](highlight: cyan, color: cyan), :marker[a cyan marker]{color=cyan} and ^[cyan text](color: cyan)
    - ^[mint highlight](highlight: mint), ^[in its colour](highlight: mint, color: mint), :marker[a mint marker]{color=mint} and ^[mint text](color: mint)
    - ^[green highlight](highlight: green), ^[in its colour](highlight: green, color: green), :marker[a green marker]{color=green} and ^[green text](color: green)
    - ^[lemon highlight](highlight: lemon), ^[in its colour](highlight: lemon, color: lemon), :marker[a lemon marker]{color=lemon} and ^[lemon text](color: lemon)
    - ^[yellow highlight](highlight: yellow), ^[in its colour](highlight: yellow, color: yellow), :marker[a yellow marker]{color=yellow} and ^[yellow text](color: yellow)
    - ^[red highlight](highlight: red), ^[in its colour](highlight: red, color: red), :marker[a red marker]{color=red} and ^[red text](color: red)
    - ^[orange highlight](highlight: orange), ^[in its colour](highlight: orange, color: orange), :marker[a orange marker]{color=orange} and ^[orange text](color: orange)
    - ^[brown highlight](highlight: brown), ^[in its colour](highlight: brown, color: brown), :marker[a brown marker]{color=brown} and ^[brown text](color: brown)
    - ^[teal highlight](highlight: teal), ^[in its colour](highlight: teal, color: teal), :marker[a teal marker]{color=teal} and ^[teal text](color: teal)
    - ^[indigo highlight](highlight: indigo), ^[in its colour](highlight: indigo, color: indigo), :marker[a indigo marker]{color=indigo} and ^[indigo text](color: indigo)
    - ^[pink highlight](highlight: pink), ^[in its colour](highlight: pink, color: pink), :marker[a pink marker]{color=pink} and ^[pink text](color: pink)

    > A quote with ==a highlight== and :marker[a marker] in it.
    """

    /// Every pen: each kind in its default ink, each in the named inks, line styles, the inks by
    /// meaning, and callouts.
    private static let pensMarkdown = """
    ### Pens
    :circle[circled] :wavy[wavy] :box[boxed] :marker[marker] :u[underlined] :s[struck] in their own inks.

    - :circle[red]{color=red} :wavy[wavy]{color=red} :box[boxed]{color=red} :u[underlined]{color=red} :s[struck]{color=red}
    - :circle[orange]{color=orange} :wavy[wavy]{color=orange} :box[boxed]{color=orange} :u[underlined]{color=orange} :s[struck]{color=orange}
    - :circle[yellow]{color=yellow} :wavy[wavy]{color=yellow} :box[boxed]{color=yellow} :u[underlined]{color=yellow} :s[struck]{color=yellow}
    - :circle[green]{color=green} :wavy[wavy]{color=green} :box[boxed]{color=green} :u[underlined]{color=green} :s[struck]{color=green}
    - :circle[blue]{color=blue} :wavy[wavy]{color=blue} :box[boxed]{color=blue} :u[underlined]{color=blue} :s[struck]{color=blue}
    - :circle[purple]{color=purple} :wavy[wavy]{color=purple} :box[boxed]{color=purple} :u[underlined]{color=purple} :s[struck]{color=purple}
    - :circle[gray]{color=gray} :wavy[wavy]{color=gray} :box[boxed]{color=gray} :u[underlined]{color=gray} :s[struck]{color=gray}
    - :circle[accent]{color=accent} :wavy[wavy]{color=accent} :box[boxed]{color=accent} :u[underlined]{color=accent} :s[struck]{color=accent}

    Lines: :u[single] :u[thick]{style=thick} :u[double]{style=double} :u[dotted]{style=dot} :u[dashed]{style=dash} :u[wavy]{style=wavy}.

    By meaning: :wavy[error]{color=error} :circle[warning]{color=warning} :box[success]{color=success} :u[info]{color=info}, and ^[error text](color: error), ^[success text](color: success).

    > [!note] Note
    > A callout in each kind.

    > [!tip] Tip
    > Its body.

    > [!important] Important
    > Its body.

    > [!warning] Warning
    > Its body.

    > [!caution] Caution
    > Its body.
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
