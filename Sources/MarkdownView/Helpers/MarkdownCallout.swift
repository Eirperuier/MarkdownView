import SwiftUI

extension MarkdownCallout.Kind {
    var color: Color {
        switch self {
        case .note: .blue
        case .tip: .green
        case .important: .purple
        case .warning: .orange
        case .caution: .red
        }
    }
}

/// 提示块标题行:kind 色图标 + 标题(加粗、同色)。
struct MarkdownCalloutHeader: View {
    let callout: MarkdownCallout

    var body: some View {
        Label {
            Text(callout.title).fontWeight(.semibold)
        } icon: {
            Image(systemName: callout.kind.symbol)
        }
        .foregroundStyle(callout.kind.color)
        .labelStyle(CalloutLabelStyle())
    }

    private struct CalloutLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                configuration.icon
                configuration.title
            }
        }
    }
}
