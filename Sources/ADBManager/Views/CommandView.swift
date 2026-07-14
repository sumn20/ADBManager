import SwiftUI

/// 内置命令按钮网格 + 自定义命令输入 + 参数
struct CommandView: View {
    @EnvironmentObject var model: AppModel
    @State private var customArgs: String = ""
    @State private var apkPath: String = ""
    @State private var pkgName: String = ""

    var body: some View {
        // 命令区按自然高度展示（不含 maxHeight:.infinity），
        // 避免ScrollView吞掉detail区全部剩余空间导致大片空白。
        // 空间分配由 ContentView 控制：TerminalView 用 maxHeight:.infinity 吃掉剩余。
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // —— TRTC 日志下载（第一位）——
                TrtcLogCard()

                // —— 常用命令卡片（含获取当前 Activity）——
                VStack(alignment: .leading, spacing: 10) {
                    Label("常用命令", systemImage: "terminal.fill")
                        .font(.headline)
                    commandGrid
                    currentActivitySection
                }
                .card()

                // —— 更多操作 ——
                VStack(alignment: .leading, spacing: 10) {
                    Text("更多操作").font(.headline)
                    actionRows
                }
                .card()

                // 当前选中设备提示
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                    if let serial = model.selectedSerial {
                        Text("当前选中设备：\(serial)")
                    } else {
                        Text("未选中设备（命令将作用于全部设备）")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    /// 常用命令网格：显式 HStack 行布局（不依赖 Grid/懒加载/透明占位），
    /// 确保每行按钮稳定渲染，不会被 SwiftUI 测量逻辑吞掉。
    /// 「当前 Activity」与截图/设备信息等同为网格按钮，使用统一 CommandButton 样式（3+3 布局）。
    private var commandGrid: some View {
        let items: [(title: String, run: () async -> Void)] = [
            ("截图",        { await model.runCommand(.screenshot, timeout: 15) }),
            ("设备信息",     { await model.runCommand(.getprop, timeout: 15) }),
            ("已装应用",     { await model.runCommand(.packages, timeout: 15) }),
            ("logcat",      { await model.runCommand(.logcat, timeout: 15) }),
            ("录屏(~60s)",   { await model.runCommand(.screenrecord(duration: 60), timeout: 70) }),
            ("当前Activity", { await model.fetchCurrentActivity() })
        ]
        let rows = stride(from: 0, to: items.count, by: 3)
            .map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(0..<row.count, id: \.self) { i in
                        CommandButton(title: row[i].title) {
                            Task { await row[i].run() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// 当前 Activity 结果展示：按钮已并入 commandGrid，这里只显示获取结果小字。
    private var currentActivitySection: some View {
        Group {
            if let current = model.currentActivity {
                switch current {
                case .none:
                    Text(model.selectedSerial == nil ? "未连接设备" : "无前台 Activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .activity(let package, let activity):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前 Activity：\(package)/\(activity)")
                            .font(.callout)
                        Text("所属包名：\(package)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("点「当前Activity」获取前台界面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    /// 安装 / 卸载 / 清理 / 自定义 命令输入行（主操作使用 .borderedProminent，次要用 .bordered）
    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("安装 APK 路径", text: $apkPath)
                Button("安装") { Task { await model.runCommand(.install(apk: apkPath), timeout: 30) } }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                TextField("包名（卸载/清理）", text: $pkgName)
                Button("卸载") { Task { await model.runCommand(.uninstall(package: pkgName)) } }
                    .buttonStyle(.bordered)
                Button("清理数据") { Task { await model.runCommand(.clear(package: pkgName)) } }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 8) {
                TextField("任意 adb 命令参数，如 shell ls /sdcard", text: $customArgs)
                Button("执行") { Task { await model.runCustom(customArgs) } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
