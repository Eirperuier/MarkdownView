//
//  CatalogFixtures.swift
//  DemoApp
//
//  The fixtures, by what they show. Anything MarkdownView can draw gets one here; a style
//  without a fixture can't be held to its look.
//

import MarkdownView

@MainActor
enum CatalogFixtures {
    static let groups: [CatalogGroup] = [
        typography, headings, inline, links, extensions, penMarks, lists, quotes, code, tables,
        images, math, otherBlocks, footnotes, settings, whole,
    ]

    static var all: [CatalogFixture] { groups.flatMap(\.fixtures) }

    private static let sentence = "The quick brown fox jumps over the lazy dog, then naps in the warm afternoon sun until the evening comes."
    private static let chinese = "敏捷的棕色狐狸跳过了懒狗，然后在温暖的午后阳光下打盹，一直睡到傍晚。标点、数字 123 和 English 混排时间距要对。"
    private static let swiftCode = """
    ```swift
    struct Point: Hashable {
        var x = 0, y = 0
        func moved(by delta: Int) -> Point {
            // A comment, and a string below.
            print("moving \\(delta)")
            return Point(x: x + delta, y: y + delta)
        }
    }
    ```
    """
    private static let table = """
    | Name | Kind | Size |
    | --- | --- | --- |
    | Alpha | First | 10 |
    | Beta | Second | 200 |
    | Gamma | Third | 3000 |
    | Delta | Fourth | 40000 |
    """
    private static let longCode = "```python\n" + (1...24).map { "print(\"line \($0)\")" }.joined(separator: "\n") + "\n```"

    // MARK: Typography

    static let typography = CatalogGroup(id: "typography", title: "Text", fixtures: [
        .init("paragraph.latin", "Paragraph", sentence + " " + sentence),
        .init("paragraph.cjk", "Paragraph, Chinese", chinese + chinese),
        .init("paragraph.mixed", "Paragraphs in a row", "\(sentence)\n\n\(chinese)\n\n\(sentence)"),
        .init("break.soft", "Soft break", "First line\nsecond line of the same paragraph"),
        .init("break.hard", "Hard break", "First line  \nsecond line after a hard break"),
        .init("rtl.arabic", "Right to left", knobs: [.rtl], "هذا نص عربي **غامض** مع [رابط](https://example.com) وكلمة English داخله.\n\n- عنصر أول\n- عنصر ثان"),
        .init("type.xsmall", "Dynamic Type xSmall", knobs: [.dynamicType(.xSmall)], "# Heading\n\n\(sentence)\n\n- Item with `code`"),
        .init("type.xxxl", "Dynamic Type xxxLarge", knobs: [.dynamicType(.xxxLarge)], "# Heading\n\n\(sentence)\n\n- Item with `code`"),
        .init("type.ax3", "Dynamic Type accessibility 3", knobs: [.dynamicType(.accessibility3)], "# Heading\n\n\(sentence)\n\n- Item with `code`"),
    ])

    static let headings = CatalogGroup(id: "headings", title: "Headings", fixtures: [
        .init("heading.levels", "Six levels", "# Heading one\n\n## Heading two\n\n### Heading three\n\n#### Heading four\n\n##### Heading five\n\n###### Heading six"),
        .init("heading.cjk", "Chinese", "# 一级标题\n\n## 二级标题\n\n### 三级标题\n\n#### 四级标题"),
        .init("heading.inline", "With marks", "## A **bold** word, `code`, *italic* and a [link](https://example.com)"),
        .init("heading.wrapping", "Wrapping", "# \(sentence)"),
        .init("heading.body", "Body after each", "# One\n\n\(sentence)\n\n## Two\n\n\(sentence)\n\n### Three\n\n\(sentence)"),
        .init("heading.extended", "Extended: title and subtitle", "## A title\n## Its subtitle\n\n### Another title\n### 另一个副标题"),
    ])

    // MARK: Inline

    static let inline = CatalogGroup(id: "inline", title: "Inline", fixtures: [
        .init("inline.emphasis", "Bold, italic, strikethrough", "Plain **bold** *italic* ***both*** ~~struck~~ and **~~bold struck~~**."),
        .init("inline.cjk.emphasis", "Chinese emphasis", "这是**粗体**，这是*斜体*，这是***粗斜体***，这是~~删除线~~。"),
        .init("inline.code", "Inline code", "Call `moved(by:)` then `print`, and `代码` in **bold `code` here**."),
        .init("inline.html", "Inline HTML", "Line one<br>line two, and <kbd>raw</kbd> stays source."),
        .init("inline.highlight", "Highlight", "A ==highlighted phrase==, and ==across **bold** and `code` too==."),
        .init("inline.style.color", "Inline colour", "^[gray](color: gray) ^[slate](color: slate) ^[purple](color: purple) ^[blue](color: blue) ^[cyan](color: cyan) ^[mint](color: mint) ^[green](color: green) ^[lemon](color: lemon) ^[yellow](color: yellow) ^[red](color: red) ^[orange](color: orange) ^[brown](color: brown) ^[hex](color: \"#8e44ad\") ^[accent](color: accent)"),
        .init("inline.style.highlight", "Inline highlight", "^[default](highlight) ^[gray](highlight: gray) ^[blue](highlight: blue) ^[green](highlight: green) ^[yellow](highlight: yellow) ^[red](highlight: red) ^[**nested bold**](highlight: purple)"),
    ])

    static let links = CatalogGroup(id: "links", title: "Links", fixtures: [
        .init("link.plain", "Link", "A plain [link](https://example.com), **[bold link](https://example.com)**, [`code link`](https://example.com)."),
        .init("link.autolink", "Autolink", "Visit https://example.com/path and mail hello@example.com or call +1 415 555 0100."),
        .init("link.autolink.off", "Autolink off", knobs: [.autolinkOff], "Visit https://example.com/path and mail hello@example.com."),
        .init("link.site.icon", "Site icons", knobs: [.siteIcons], "Read [the docs](https://\(CatalogImages.host)/docs) and [the blog](https://\(CatalogImages.host)/blog) today."),
        .init("link.chip", "Chips", "Cited [Apple](https://\(CatalogImages.host)/a \"cite\") and folded [Swift](https://\(CatalogImages.host)/b \"cite\") [GitHub](https://\(CatalogImages.host)/c \"cite\"), and a very long title [Fourteen plus twenty seven characters long](https://\(CatalogImages.host)/d \"cite\")."),
        .init("link.chip.noicon", "Chip with no icon", "A site with no icon: [Plain](https://noicon.test/a \"cite\")."),
        .init("link.symbol", "Tool chip", "A tool result [Report](flowith-tool://file/report \"cite\") in a line."),
        .init("link.tint", "Link tint", knobs: [.tintLink], "A [tinted link](https://example.com) and https://example.org."),
    ])

    static let extensions = CatalogGroup(id: "extensions", title: "Extensions", fixtures: [
        .init("ext.page", "The Extensions page", knobs: [.tableDimsParentheticals], ExtensionsDestination.text),
        .init("ext.list.markers", "Custom bullets", "- {🚀} Emoji bullet\n- {star.fill} SF Symbol bullet\n- {✅}中文不加空格也行\n- Ordinary bullet"),
        .init("ext.callout.kinds", "Callouts", "> [!note]\n> A note.\n\n> [!tip]\n> A tip.\n\n> [!important]\n> Important.\n\n> [!warning]\n> A warning.\n\n> [!caution]\n> A caution."),
        .init("ext.callout.titled", "Callouts with titles", "> [!note] 自定义标题\n> 内容\n\n> [!tip] A longer custom title goes here\n> Body with **bold**, `code` and a [link](https://example.com)."),
    ])

    static let penMarks = CatalogGroup(id: "pen", title: "Pen marks", fixtures: [
        .init("pen.hand", "By hand", "A :circle[circled] word, :wavy[a wave], :box[a box] and :marker[a marker] in text. 中文 :circle[圈画] :wavy[波浪] :box[方框] :marker[荧光笔]。"),
        .init("pen.ink", "Inks", ":circle[blue]{color=blue} :wavy[green]{color=green} :box[orange]{color=orange} :marker[pink]{color=pink} :marker[mint]{c=mint} :circle[hex]{color=#8e44ad} :wavy[accent]{color=accent} :box[slate]{color=slate}"),
        .init("pen.underline", "Underline", ":u[single] :u[thick]{style=thick} :u[double]{style=double} :u[dot]{style=dot} :u[dash]{style=dash} :u[dashdot]{style=dashdot} :u[wavy]{style=wavy} :u[colored]{style=double color=red}"),
        .init("pen.strike", "Strikethrough", ":s[single] :s[thick]{style=thick} :s[double]{style=double} :s[dot]{style=dot} :s[dash]{style=dash} :s[wavy]{style=wavy} :s[colored]{style=double color=red}"),
        .init("pen.color", "Text colour", ":color[positive]{c=positive} :color[negative]{c=negative} :color[warning]{c=warning} :color[info]{c=info} :color[accent]{c=accent} :color[hex]{c=#8e44ad} :color[slate]{c=slate} :color[unknown]{c=nothing}"),
        .init("pen.wrapping", "Over lines", "Lorem ipsum dolor sit amet :marker[consectetur adipiscing elit sed] do eiusmod :u[tempor incididunt ut labore]{style=double} et :circle[dolore magna aliqua ut]."),
        .init("pen.node", "As nodes", "^[circle](pen: circle) ^[wave **bold**](pen: wavy, ink: blue) ^[box](pen: box, ink: red) ^[marker](pen: marker)"),
    ])

    // MARK: Lists

    static let lists = CatalogGroup(id: "lists", title: "Lists", fixtures: [
        .init("list.bullet", "Bullets, nested", "- First\n- Second\n  - Nested one\n  - Nested two\n    - Third level\n      - Fourth level\n- Third\n- \(sentence)"),
        .init("list.ordered", "Numbered, nested", "1. First\n2. Second\n   1. Nested one\n   2. Nested two\n      1. Third level\n3. Third\n4. \(sentence)"),
        .init("list.start", "Numbered from 7", "7. Seven\n8. Eight\n9. Nine\n10. Ten\n11. Eleven"),
        .init("list.mixed", "Mixed", "1. Numbered\n   - Bullet inside\n   - Another\n2. Numbered\n   1. Number inside"),
        .init("list.task", "Tasks", "- [ ] To do\n- [x] Done\n- [ ] With **bold** and `code`\n  - [x] Nested done\n  - [ ] \(sentence)"),
        .init("list.paragraphs", "Items with paragraphs", "- First paragraph\n\n  Second paragraph of the item\n- Next item"),
        .init("list.code", "Item with code", "- Some text\n  ```swift\n  let x = 1\n  ```\n- Next item\n- ```swift\n  let onFirstLine = true\n  ```"),
        .init("list.quote", "Item with a quote", "- Some text\n\n  > A quote inside an item\n- Next item"),
        .init("list.cjk", "Chinese", "- 第一项\n- 第二项\n  - 嵌套项\n1. 编号一\n2. \(chinese)"),
        .init("list.dash", "Dash marker", path: .document, knobs: [.dashMarker], "- One\n- Two\n  - Nested"),
        .init("list.letters", "Letter marker", path: .document, knobs: [.letterMarker], "1. One\n2. Two\n   1. Nested"),
        .init("list.indent", "Wider indent", path: .document, knobs: [.listIndent], "- One\n  - Nested\n- Two"),
    ])

    // MARK: Quotes

    static let quotes = CatalogGroup(id: "quotes", title: "Quotes", fixtures: [
        .init("quote.plain", "Quote", "> \(sentence)"),
        .init("quote.rich", "With marks", "> **Bold**, *italic*, `code`, a [link](https://example.com).\n>\n> A second paragraph.\n>\n> - A list\n> - in a quote"),
        .init("quote.nested", "Nested", "> Outer\n>\n> > Inner\n> >\n> > > Innermost"),
        .init("quote.code", "With code", "> A quote with code\n>\n> ```swift\n> let x = 1\n> ```"),
        .init("quote.cjk", "Chinese", "> \(chinese)"),
        .init("quote.tint", "Tint", knobs: [.tintQuote], "> A tinted quote"),
        .init("quote.decoration", "Decoration", path: .selectableText, knobs: [.quoteDecoration], "Text drawn as a quote by its host, not by its markdown."),
        .init("quote.github", "GitHub style", path: .document, knobs: [.quoteGithub], "> A GitHub quote\n>\n> # With a heading\n>\n> And **bold**."),
        .init("quote.document", "In MarkdownView", path: .document, "> A quote in MarkdownView\n>\n> And **bold**."),
    ])

    // MARK: Code

    static let code = CatalogGroup(id: "code", title: "Code", fixtures: [
        .init("code.swift", "Default", swiftCode),
        .init("code.highlighted", "Highlighted", knobs: [.codeHighlighter], swiftCode),
        .init("code.plain", "No language", "```\nplain text\n  indented\n```"),
        .init("code.languages", "Language icons", ["bash", "c", "cpp", "css", "go", "html", "java", "javascript", "json", "python", "ruby", "rust", "swift", "typescript"].map { "```\($0)\n\($0)\n```" }.joined(separator: "\n\n")),
        .init("code.badges", "Language badges", "```kotlin\nkotlin\n```\n\n```js\njs\n```\n\n```unknownlang\nunknown\n```"),
        .init("code.wrapping", "Long lines", "```swift\nlet long = \"\(sentence) \(sentence)\"\n```"),
        .init("code.scrollable", "Scrolls sideways", knobs: [.codeScrollable], "```swift\nlet long = \"\(sentence) \(sentence)\"\nlet short = 1\n```"),
        .init("code.limit", "Over the line limit", longCode),
        .init("code.full", "Showing all lines", knobs: [.codeFull], longCode),
        .init("code.font", "Font", knobs: [.fontCode], swiftCode),
        .init("code.renderer", "Custom renderer picker", knobs: [.codeRenderer], "```catalog\nCustom preview\n```"),
        .init("code.renderer.bare", "Bare renderer", knobs: [.codeRendererBare], "```catalog\nCustom preview\n```"),
        .init("code.renderer.off", "Renderer disabled", knobs: [.codeRendererDisabled], "```catalog\nCustom preview\n```"),
        .init("code.floo", "floo's code box", knobs: [.codeFloo, .codeHighlighter], swiftCode),
    ])

    // MARK: Tables

    static let tables = CatalogGroup(id: "tables", title: "Tables", fixtures: [
        .init("table.default", "Default", table),
        .init("table.inline", "With marks", "| Name | Value |\n| --- | --- |\n| **Bold** | `code` |\n| [link](https://example.com) | *italic* |\n| first<br>second | $x^2$ |"),
        .init("table.align", "Alignment", "| Left | Center | Right |\n| :-- | :-: | --: |\n| a | b | c |\n| longer text | longer text | longer text |"),
        .init("table.wide", "Wide", "| One | Two | Three | Four | Five | Six | Seven |\n| --- | --- | --- | --- | --- | --- | --- |\n| \(sentence) | a | b | c | d | e | f |"),
        .init("table.cjk", "Chinese", "| 名称 | 说明 |\n| --- | --- |\n| 第一项 | \(chinese) |\n| 第二项 | 短 |"),
        .init("table.github", "GitHub style", knobs: [.tableGithub], table),
        .init("table.grid", "Grid style", knobs: [.tableGrid], table),
        .init("table.font", "Fonts", knobs: [.fontTable], table),
        .init("table.padding", "Cell padding", knobs: [.tableCellPadding], table),
        .init("table.overlay", "Cell overlay", knobs: [.tableCellOverlay], table),
        .init("table.row.background", "Row background", knobs: [.tableRowBackground], table),
        .init("table.scrollable", "Scrollable", knobs: [.tableScrollable], table),
        .init("table.scrollable.wide", "Scrollable, wide", knobs: [.tableScrollable], "| One | Two | Three | Four | Five | Six | Seven |\n| --- | --- | --- | --- | --- | --- | --- |\n| \(sentence) | a | b | c | d | e | f |\n| x | y | z | x | y | z | x |"),
        .init("table.header.column", "Header column", knobs: [.tableHeaderColumn], table),
        .init("table.header.none", "No header row", knobs: [.tableNoHeaderRow], table),
        .init("table.stripe.none", "No stripes", knobs: [.tableNoStripe], table),
        .init("table.stripe.color", "Stripe colour", knobs: [.tableStripeColor], table),
        .init("table.design", "Serif cells", knobs: [.tableSerif], table),
        .init("table.cells", "Cell looks", knobs: [.tableCellLooks], "| Name | Kind | Size |\n| --- | --- | --- |\n| Fill one | Fill two | Fill three |\n| Tag | Center mono | Right serif |\n| Justified text that wraps over a couple of lines at least | b | c |"),
        .init("table.parentheticals", "Dim parentheticals", knobs: [.tableDimsParentheticals], "| Item | Price (USD) | Weight (kg) |\n| --- | --- | --- |\n| Coffee | 4.5 | 0.3 |"),
        .init("table.selectable", "Selectable cells", knobs: [.tableCellsSelectable], table),
        .init("table.replacement", "Cell replacement", knobs: [.tableCellReplacement], table),
        .init("table.decoration", "Decoration", knobs: [.tableDecoration], table),
        .init("table.image", "Image in a cell", knobs: [.tableImage], "| Name | Picture |\n| --- | --- |\n| Square | ![square](https://\(CatalogImages.host)/square.png) |"),
    ])

    // MARK: Images

    static let images = CatalogGroup(id: "images", title: "Images", fixtures: [
        .init("image.network", "Network", waitsForImages: true, "![A landscape](https://\(CatalogImages.host)/wide.png)"),
        .init("image.tall", "Tall", waitsForImages: true, "![A tall one](https://\(CatalogImages.host)/tall.png)"),
        .init("image.noalt", "No alt text", waitsForImages: true, "![](https://\(CatalogImages.host)/square.png)"),
        .init("image.inline", "Beside text", waitsForImages: true, "Before ![square](https://\(CatalogImages.host)/square.png) and after the picture."),
        .init("image.two", "Two together", waitsForImages: true, "![one](https://\(CatalogImages.host)/square.png) ![two](https://\(CatalogImages.host)/wide.png)"),
        .init("image.svg", "SVG", waitsForImages: true, "![A drawing](https://\(CatalogImages.host)/drawing.svg)"),
        .init("image.error", "Failed", waitsForImages: true, "![Missing](https://\(CatalogImages.host)/missing.png)"),
        .init("image.loading", "Loading", waitsForImages: true, "![Never comes](https://\(CatalogImages.host)/never.png)"),
        .init("image.relative", "Relative path", knobs: [.baseURL], waitsForImages: true, "![Relative](square.png)"),
        .init("image.nobase", "Relative, no base", "![Alt text only](square.png)"),
        .init("image.custom", "Custom renderer", knobs: [.imageRenderer], "![Custom](catalog://x)"),
    ])

    // MARK: Math

    static let math = CatalogGroup(id: "math", title: "Math", fixtures: [
        .init("math.inline", "Inline", "Euler's identity \\(e^{i\\pi} + 1 = 0\\) and $x^2 + y^2 = z^2$ in text, 公式 \\(\\frac{a}{b}\\) 混排。"),
        .init("math.display", "Display", "Before\n\n$$\n\\int_0^\\infty e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}\n$$\n\nAfter"),
        .init("math.wide", "Wider than the page", "$$\n\(String(repeating: "a_1 + b_2 + c_3 + ", count: 14))z\n$$"),
        .init("math.tall", "Tall", "$$\n\\begin{pmatrix} a & b & c \\\\ d & e & f \\\\ g & h & i \\end{pmatrix}\n$$"),
        .init("math.heading", "In a heading", "## Area \\(\\pi r^2\\)"),
        .init("math.color", "Coloured", "$$\n\\color{red}{x} + \\color{blue}{y}\n$$"),
        .init("math.font", "Font", knobs: [.fontMath], "Inline \\(x^2\\)\n\n$$\ny = x^2\n$$"),
        .init("math.error", "Invalid", "Inline \\(\\notacommand{x}\\)\n\n$$\n\\notacommand{y}\n$$"),
    ])

    // MARK: Other blocks

    static let otherBlocks = CatalogGroup(id: "blocks", title: "Other blocks", fixtures: [
        .init("rule", "Thematic break", "Above\n\n---\n\nBelow"),
        .init("html.block", "HTML block", "<div class=\"note\">\nRaw HTML shows as its source.\n</div>"),
        .init("directive.custom", "Directive", knobs: [.directive], "@note {\nA note from a custom renderer.\n}"),
        .init("directive.unregistered", "Unknown directive", "@unknown {\nIts content as **markdown**.\n}"),
        .init("nested.rule", "A rule in a quote and an item", "> Above\n>\n> ---\n>\n> Below\n\n- Item\n\n  ---\n- Next"),
        .init("nested.html", "HTML in a quote and an item", "> Text\n>\n> <div>\n> Raw\n> </div>\n\n- Item\n\n  <div>\n  Raw\n  </div>\n- Next"),
        .init("nested.directive", "A directive in a quote", knobs: [.directive], "> Text\n>\n> @note {\n> A note.\n> }"),
        .init("nested.image", "Images in a quote and an item", waitsForImages: true, "> ![In a quote](https://\(CatalogImages.host)/wide.png)\n\n- ![In an item](https://\(CatalogImages.host)/wide.png)\n- ![Square](https://\(CatalogImages.host)/square.png)\n\n> > ![Deeper](https://\(CatalogImages.host)/square.png)"),
    ])

    // MARK: Footnotes

    static let footnotes = CatalogGroup(id: "footnotes", title: "Footnotes", fixtures: [
        .init("footnote.reference", "References", knobs: [.footnotes], "A sentence with a note[^1] and another[^named]."),
        .init("footnote.inline", "Inline note", knobs: [.footnotes], "An inline note^[The note's text] in a sentence."),
        .init("footnote.definitions", "Definitions", knobs: [.footnotes], "[^1]: The first definition.\n[^named]: The second one, with **bold**."),
        .init("footnote.off", "Without an index", "A literal reference[^1] stays.\n\n[^1]: A definition."),
    ])

    // MARK: Settings

    private static let sample = "# Heading\n\n## Second heading\n\n\(sentence) **Bold** and *italic* with `code` and a [link](https://example.com).\n\n> A quote\n\n- A list\n- Of things\n\n" + table

    static let settings = CatalogGroup(id: "settings", title: "Settings", fixtures: [
        .init("type.doc", "Doc's typography", knobs: [.typographyDoc], sample),
        .init("type.inline.code", "Monospaced inline code", knobs: [.typographyInlineCode], "Call `moved(by:)` and `print`."),
        .init("type.leading.off", "Font's own leading", knobs: [.typographyLeadingOff], "\(sentence) \(sentence)"),
        .init("type.serif", "Serif body", knobs: [.typographySerif], "\(sentence) **Bold** and *italic*."),
        .init("type.strong", "Heavier bold", knobs: [.typographyStrong], "Plain and **bold** and **粗体**."),
        .init("type.centered", "Centred lines", knobs: [.typographyCentered], sentence),
        .init("spacing.line", "Line spacing", knobs: [.lineSpacing], "\(sentence) \(sentence)\n\n\(chinese)"),
        .init("spacing.edges.off", "No edge insets", knobs: [.noEdgeInsets], "One\n\nTwo\n\n- Three"),
        .init("color.base", "Base text colour", knobs: [.baseTextColor], sample),
        .init("color.theme", "Theme colours", knobs: [.colors], sample + "\n\n" + swiftCode),
        .init("color.preferred", "Bold colour", knobs: [.preferredColor], "Plain and **bold**."),
        .init("color.inline.code", "Inline code tint", knobs: [.tintInlineCode], "Some `code` tinted."),
        .init("decor.range", "Range underlines", knobs: [.rangeDecoration], sentence),
        .init("decor.anchor", "Topic bubble", knobs: [.inlineAnchor], sentence),
        .init("selectable.text", "A Doc text block", path: .selectableText, sample),
        .init("legacy.sample", "MarkdownView", path: .document, sample),
        .init("legacy.fonts", "Font group", path: .document, knobs: [.fontGroup], sample),
        .init("legacy.font.one", "A font per kind", path: .document, knobs: [.fontBody, .fontHeading, .fontQuote], sample),
        .init("legacy.heading.colors", "Heading colours", path: .document, knobs: [.headingStyleGroup], "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six"),
        .init("legacy.heading.one", "One heading's colour", path: .document, knobs: [.headingStyleOne], "# One\n\n## Two"),
        .init("legacy.heading.padding", "Heading padding", path: .document, knobs: [.headingPadding], "# One\n\n\(sentence)\n\n## Two\n\n\(sentence)"),
        .init("legacy.spacing", "Component spacing", path: .document, knobs: [.componentSpacing], "One\n\nTwo\n\n- Three\n- Four"),
        .init("legacy.search", "Search", path: .document, knobs: [.search], "A needle in a haystack, and another needle."),
        .init("legacy.editor", "Editor style", path: .document, knobs: [.editorStyle], sample),
    ])

    // MARK: Whole

    static let whole = CatalogGroup(id: "whole", title: "Together", fixtures: [
        .init("whole.flooChat", "As floo's chat sets it", knobs: [.tableScrollable, .codeFloo, .codeHighlighter, .siteIcons], "## A reply\n\n\(sentence) See [the docs](https://\(CatalogImages.host)/docs) and [Apple](https://\(CatalogImages.host)/a \"cite\").\n\n- One\n- Two\n\n\(swiftCode)\n\n\(table)\n\n> A quote\n\n$$\nE = mc^2\n$$"),
        .init("whole.document", "All in a row", "# Title\n\n\(sentence)\n\n## Lists\n\n- One\n- Two\n  - Nested\n\n1. First\n2. Second\n\n## Code\n\n\(swiftCode)\n\n## Table\n\n\(table)\n\n## Quote\n\n> \(chinese)\n\n---\n\nThe end, with \\(x^2\\)."),
    ])
}
