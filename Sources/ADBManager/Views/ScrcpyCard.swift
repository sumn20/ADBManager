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
            ("手柄模式",   { model.launchScrcpy(args: ["-G"]) }),
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
