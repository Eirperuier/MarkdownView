import SwiftUI

/// 自定义 bullet 视图:emoji 与 SF Symbol 统一等宽高方框(随 Dynamic Type 缩放);
/// SF Symbol = 高亮色圆底 + 白色前景;emoji = 居中文字。
struct CustomListMarkerView: View {
    let marker: CustomListMarker
    @Environment(\.markdownRendererConfiguration) private var configuration
    /// 方框边长(随正文动态字号缩放),emoji/symbol 共用以保证等宽高。
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 20

    var body: some View {
        switch marker {
        case .emoji(let e):
            SwiftUI.Text(e)
                .font(.system(size: side * 0.86))
                .frame(width: side, height: side)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: side * 0.56, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: side, height: side)
                .background(Circle().fill(configuration.preferredColor))
        }
    }
}
