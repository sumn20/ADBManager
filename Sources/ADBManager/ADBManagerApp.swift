import SwiftUI
import AppKit

/// 应用入口：SwiftUI App 生命周期
@main
struct ADBManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    // 加载版本号、刷新设备列表到 UI（心跳由 AppModel.init 统一启动，避免重复）
                    await model.loadVersion()
                    await model.refreshDevices()
                }
        }
        // 首次打开即采用舒适窗口尺寸；最小尺寸由内容自身 min size 决定，不强制限制
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)

        // 菜单栏常驻图标：使用应用自身图标，显示 adb 可用状态 + 快捷操作
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(nsImage: menuBarIcon())
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 安全加载菜单栏图标。
/// 优先从 App 包直接读取 icns，不依赖 NSApp 初始化时机——
/// 当 App 作为后台 LaunchAgent 被 launchd 拉起时，NSApp.applicationIconImage
/// 可能尚未就绪（隐式解包可选值为 nil），直接传给 Image(nsImage:) 会崩溃。
/// 这里全程走可选绑定/兜底，绝不强制解包。
@MainActor
private func menuBarIcon() -> NSImage {
    // 始终以固定 22pt 渲染，并把图标内容内缩 ~16%，
    // 留出透明边距，避免实心方块贴边、视觉上比系统菜单栏图标「大」。
    let drawSize = NSSize(width: 22, height: 22)
    let inset: CGFloat = 0.12
    let result = NSImage(size: drawSize)
    result.lockFocus()
    let src: NSImage? = {
        if let url = Bundle.main.url(forResource: "ADBManager", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        return NSApp.applicationIconImage
    }()
    if let src {
        let w = drawSize.width * (1 - inset)
        let h = drawSize.height * (1 - inset)
        let rect = NSRect(x: (drawSize.width - w) / 2,
                          y: (drawSize.height - h) / 2,
                          width: w, height: h)
        src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    } else if let fallback = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                     accessibilityDescription: "ADBManager") {
        let w = drawSize.width * (1 - inset)
        let h = drawSize.height * (1 - inset)
        fallback.draw(in: NSRect(x: (drawSize.width - w) / 2,
                                 y: (drawSize.height - h) / 2,
                                 width: w, height: h))
    }
    result.unlockFocus()
    return result
}

/// 菜单栏下拉内容
private struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    /// 心跳阶段颜色：可用=绿 / 重启中=橙 / 不可用=红 / 检测中=灰
    private var menuStatusColor: Color {
        switch model.monitor.phase {
        case .available: return .green
        case .restarting: return .orange
        case .unavailable: return .red
        case .checking: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(menuStatusColor)
                    .frame(width: 8, height: 8)
                Text(model.monitor.lastStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.monitor.phase == .restarting || model.monitor.phase == .unavailable {
                    Text("· 正在自动重启")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Divider()
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("立即重启 adb") {
                Task { await model.restartAdb() }
            }
            .disabled(model.isBusy)
            Divider()
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
    }
}
