//
//  MarkdownHeading.swift
//  MarkdownView
//
//  Created by Yanan Li on 2025/2/22.
//

import SwiftUI
import Markdown

struct MarkdownHeading: View {
    let heading: Heading

    @Environment(\.markdownRendererConfiguration) private var configuration
    @Environment(\.markdownFontGroup) private var fontGroup
    @Environment(\.headingStyleGroup) private var headingStyleGroup
    @Environment(\.headingPaddings) private var paddings
    @Environment(\.markdownHeadingLevelOffset) private var levelOffset

    /// 实际渲染层级 = AST 层级 + 环境偏移(Extended Heading 的 subtitle 注入 +1),
    /// 钳在 1...6。字体/字重/前景色/padding/无障碍全部按这个层级取。
    private var level: Int {
        min(max(heading.level + levelOffset, 1), 6)
    }

    private var fontWeight: Font.Weight {
        return switch level {
            case 1: .heavy
            case 2: .bold
            case 3: .semibold
            case 4, 5, 6: .medium
            default: .regular
        }
    }
    private var font: Font {
        return switch level {
        case 1: fontGroup.h1
        case 2: fontGroup.h2
        case 3: fontGroup.h3
        case 4: fontGroup.h4
        case 5: fontGroup.h5
        case 6: fontGroup.h6
        default: fontGroup.body
        }
    }
    private var foregroundStyle: AnyShapeStyle {
        return switch level {
        case 1: headingStyleGroup.h1
        case 2: headingStyleGroup.h2
        case 3: headingStyleGroup.h3
        case 4: headingStyleGroup.h4
        case 5: headingStyleGroup.h5
        case 6: headingStyleGroup.h6
        default: AnyShapeStyle(.foreground)
        }
    }
    private var accessibilityHeadingLevel: AccessibilityHeadingLevel {
        return switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        case 6: .h6
        default: .unspecified
        }
    }

    var body: some View {
        CmarkNodeVisitor(configuration: configuration)
            .descendInto(heading)
            .font(font)
            .fontWeight(fontWeight)
            .foregroundStyle(foregroundStyle)
            .accessibilityHeading(accessibilityHeadingLevel)
            .padding(paddings[level])
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Heading Level Offset

struct MarkdownHeadingLevelOffsetEnvironmentKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// 标题渲染层级偏移。Extended Heading 的 subtitle 子树注入 +1,
    /// 使其按 title 的下一级标题样式渲染。
    var markdownHeadingLevelOffset: Int {
        get { self[MarkdownHeadingLevelOffsetEnvironmentKey.self] }
        set { self[MarkdownHeadingLevelOffsetEnvironmentKey.self] = newValue }
    }
}
