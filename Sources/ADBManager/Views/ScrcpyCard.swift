import SwiftUI

/// scrcpy 投屏/录制卡片：检测安装状态，未安装引导跳转官网，已安装提供常用命令按钮。
struct ScrcpyCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("scrcpy 投屏", systemImage: "rectangle.on.rectangle")
                .font(.headline)

            if model.isScrcpyAvailable {
                installedContent
            } else {
                notInstalledContent
            }
        }
        .card()
    }

    // MARK: - 已安装：命令按钮网格

    private var installedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            commandGrid
            recordSection
            Divider().padding(.vertical, 2)
            keyEventSection
            if !model.scrcpyStatus.isEmpty {
                Text(model.scrcpyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandGrid: some View {
        let items: [(title: String, action: () -> Void)] = [
            ("默认投屏",   { model.launchScrcpy() }),
            ("性能优先",   { model.launchScrcpy(args: ["-m1024"]) }),
            ("高质量",    { model.launchScrcpy(args: ["--video-codec=h265", "-m1920", "--max-fps=60", "--no-audio", "-K"]) }),
            ("关屏投屏",   { model.launchScrcpy(args: ["--turn-screen-off"]) }),
            ("仅视频",    { model.launchScrcpy(args: ["--no-audio"]) }),
            ("仅音频",    { model.launchScrcpy(args: ["--no-video"]) }),
            ("窗口置顶",   { model.launchScrcpy(args: ["--always-on-top"]) }),
        ]
        let rows = stride(from: 0, to: items.count, by: 3)
            .map { Array(items[$0..<min($0 + 3, items.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(0..<row.count, id: \.self) { i in
                        CommandButton(title: row[i].title) {
                            row[i].action()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // 最后一行不足 3 列时填充占位，让按钮宽度保持一致
                    if row.count < 3 {
                        ForEach(0..<(3 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var recordSection: some View {
        HStack(spacing: 8) {
            if model.scrcpyRecordProcess != nil {
                Button("停止录屏") {
                    model.stopScrcpyRecord()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button("开始录屏") {
                    model.startScrcpyRecord()
                }
                .buttonStyle(.bordered)
            }
            Text("录屏文件保存到 ~/Downloads/ADBManager/")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 设备按键（通过 adb shell input keyevent 发送，无需 scrcpy 也可用）

    /// Android KeyEvent 常量（见 https://developer.android.com/reference/android/view/KeyEvent）
    private var keyEventItems: [(title: String, keycode: Int)] {
        [
            ("Home",      3),
            ("返回",      4),
            ("多任务",    187),
            ("菜单",      82),
            ("电源",      26),
            ("音量+",     24),
            ("音量-",     25),
            ("静音",      164),
        ]
    }

    private var keyEventSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("设备按键", systemImage: "square.grid.3x2.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("需选中设备；scrcpy 未开也可用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            let items = keyEventItems
            let rows = stride(from: 0, to: items.count, by: 4)
                .map { Array(items[$0..<min($0 + 4, items.count)]) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(0..<row.count, id: \.self) { i in
                            let item = row[i]
                            Button(item.title) {
                                Task { await model.sendKeyEvent(item.keycode, label: item.title) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .disabled(model.selectedSerial == nil)
                        }
                        if row.count < 4 {
                            ForEach(0..<(4 - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 未安装：引导

    private var notInstalledContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("未检测到 scrcpy，请先安装并配置环境变量。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("前往 scrcpy 官网安装") {
                    if let url = URL(string: "https://scrcpyapp.org/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("重新检测") {
                    model.detectScrcpy()
                }
                .buttonStyle(.bordered)
            }

            Text("安装后请确保 scrcpy 在 PATH 中（终端输入 which scrcpy 能找到路径）。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
