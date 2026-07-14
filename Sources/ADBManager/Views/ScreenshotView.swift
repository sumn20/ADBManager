import SwiftUI
import AppKit

/// 截图预览 sheet：展示 PNG 并可保存
struct ScreenshotView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("截图预览")
                    .font(.headline)
                Spacer()
            }

            if let data = model.screenshotData, let nsImage = NSImage(data: data) {
                // 图片居中、圆角、可滚动预览
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 600, maxHeight: 600)
                        .cornerRadius(10)
                        .shadow(radius: 3)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("无截图数据")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("保存为 PNG") {
                    guard let data = model.screenshotData else { return }
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.png]
                    panel.nameFieldStringValue = "screenshot.png"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? data.write(to: url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.screenshotData == nil)
                Button("关闭") {
                    model.showScreenshot = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 360)
    }
}
