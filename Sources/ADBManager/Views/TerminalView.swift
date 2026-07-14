import SwiftUI
import AppKit

/// 终端风格输出展示（等宽字体、可滚动、可复制 / 清空、自动滚底）
struct TerminalView: View {
    @EnvironmentObject var model: AppModel

    // 底部锚点 ID，用于 auto-scroll
    private let bottomAnchorID = "terminal_bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("输出", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Button("复制") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(model.terminalOutput, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("清空") {
                    model.terminalOutput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // 输出区：ScrollViewReader 实现新输出自动滚底；固定 minHeight 保证可见区域，
            // 不用 maxHeight:.infinity 避免撑出大片空白（空间分配由父级控制）
            ScrollViewReader { proxy in
                ScrollView {
                    if model.terminalOutput.isEmpty {
                        Text("暂无输出")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    } else {
                        Text(model.terminalOutput)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }

                    // 隐形底部锚点：新内容追加后自动滚到这里
                    Color.clear.frame(height: 1).id(bottomAnchorID)
                }
                // 有内容时给一个合理的最小高度（约显示 8-10 行），避免被压扁；
                // 不设 maxHeight，让视图按实际内容+父级分配自然决定大小
                .frame(minHeight: model.terminalOutput.isEmpty ? 60 : 180)
                .onChange(of: model.terminalOutput) { _, _ in
                    // 延迟一帧等 SwiftUI 布局完成后再滚动，确保新内容已渲染
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .padding()
    }
}
