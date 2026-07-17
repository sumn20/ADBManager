import SwiftUI

/// 单个按键定义：图标 + 可读名 + KeyEvent 数字码
fileprivate struct KeyItem: Identifiable {
    let icon: String
    let label: String
    let keycode: Int
    var id: Int { keycode }
}

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

    /// Android 导航栏三键（左中右布局）
    private var navKeys: [KeyItem] {
        [
            KeyItem(icon: "arrow.uturn.backward",       label: "返回",    keycode: 4),
            KeyItem(icon: "house.fill",                  label: "Home",   keycode: 3),
            KeyItem(icon: "square.on.square",            label: "多任务", keycode: 187),
        ]
    }

    /// 硬件键（电源 + 音量组）
    private var hardwareKeys: [KeyItem] {
        [
            KeyItem(icon: "power",              label: "电源",   keycode: 26),
            KeyItem(icon: "speaker.wave.2.fill", label: "音量+", keycode: 24),
            KeyItem(icon: "speaker.wave.1.fill", label: "音量-", keycode: 25),
            KeyItem(icon: "speaker.slash.fill",  label: "静音",   keycode: 164),
            KeyItem(icon: "line.horizontal.3",   label: "菜单",   keycode: 82),
        ]
    }

    private var keyEventSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("设备按键", systemImage: "iphone.gen3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.selectedSerial == nil {
                    Text("请先选中设备")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // 一横排：导航栏（3 键，稍宽）+ 分隔 + 硬件键（电源+音量组）+ 菜单
            HStack(spacing: 10) {
                // —— 导航栏三键 ——
                HStack(spacing: 4) {
                    ForEach(navKeys) { key in
                        KeyIconButton(key: key,
                                       disabled: model.selectedSerial == nil) {
                            Task { await model.sendKeyEvent(key.keycode, label: key.label) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

                // —— 硬件键 ——
                HStack(spacing: 4) {
                    ForEach(hardwareKeys) { key in
                        KeyIconButton(key: key,
                                       disabled: model.selectedSerial == nil) {
                            Task { await model.sendKeyEvent(key.keycode, label: key.label) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

                Spacer(minLength: 0)
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

// MARK: - KeyIconButton：图标按键（模拟手机导航栏按钮）

/// 图标按键：36×32 圆角胶囊、SF Symbol 图标、悬停高亮、按下缩放、tooltip 显示名称。
private struct KeyIconButton: View {
    let key: KeyItem
    let disabled: Bool
    let action: () -> Void

    @State private var hovering: Bool = false
    @State private var pressed: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: key.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.85))
                .frame(width: 36, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && !disabled
                              ? Color.accentColor.opacity(0.18)
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(hovering && !disabled
                                      ? Color.accentColor.opacity(0.5)
                                      : Color.clear,
                                      lineWidth: 1)
                )
                .scaleEffect(pressed && !disabled ? 0.92 : 1.0)
                .animation(.easeOut(duration: 0.12), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .help(key.label)   // macOS tooltip
    }
}
