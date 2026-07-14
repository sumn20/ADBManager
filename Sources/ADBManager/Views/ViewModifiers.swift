import SwiftUI

/// 区块卡片样式：圆角矩形 + 系统背景 + 细边框，统一各区域视觉语言，
/// 让界面从「裸控件平铺」升级为卡片化、有层次感的现代 macOS 观感。
struct CardModifier: ViewModifier {
    /// 卡片内边距，默认 12（与全局间距规范一致）
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    /// 统一卡片容器修饰符
    func card(padding: CGFloat = 12) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// 常用命令卡片式按钮：accent 淡底 + 描边，hover 高亮、按下轻微缩放。
/// 用作命令面板的统一按钮风格，区别于 Toolbar 的 .bordered / .borderedProminent。
struct CommandButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovered ? Color.accentColor.opacity(0.2) : Color.accentColor.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(hovered ? 0.5 : 0.25), lineWidth: 1)
                )
                .foregroundStyle(Color.accentColor)
                .scaleEffect(hovered ? 1.02 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

extension Array {
    /// 将数组按指定大小分块，用于把按钮数组切成每 3 个一行。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [[]] }
        var result: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            result.append(Array(self[index..<end]))
            index = end
        }
        return result
    }
}
