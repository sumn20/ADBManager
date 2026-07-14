import SwiftUI
import AppKit

/// 应用自身状态诊断 dialog：展示 adb 路径 / 版本、心跳运行情况、设备与连接状态，
/// 以及心跳的实时诊断日志。用于排查「一直检测中」「adb 不可用」等问题。
///
/// 直接以 `@ObservedObject` 观察 `monitor`，使 dialog 内的心跳日志 / 状态实时刷新
/// （主界面出于去抖只在心跳阶段变化时刷新，见 AppModel.bindNested）。
struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var monitor: Monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            reportArea
            actionBar
        }
        .padding()
        .frame(width: 560, height: 540)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("应用状态", systemImage: "stethoscope")
                .font(.title3).bold()
            Spacer()
            Circle()
                .fill(phaseColor)
                .frame(width: 10, height: 10)
            Text(monitor.lastStatus)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    /// 心跳阶段颜色：可用=绿 / 重启中=橙 / 不可用=红 / 检测中=灰
    private var phaseColor: Color {
        switch monitor.phase {
        case .available: return .green
        case .restarting: return .orange
        case .unavailable: return .red
        case .checking: return .gray
        }
    }

    private var reportArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.diagnosticsReport())
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("心跳日志（最近）").font(.headline)
                    if monitor.diagnostics.isEmpty {
                        Text("暂无日志")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        // 最新在上
                        ForEach(Array(monitor.diagnostics.enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(10)
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

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button("复制报告") {
                let pb = NSPasteboard.general
                pb.clearContents()
                let text = model.diagnosticsReport()
                    + "\n\n== 心跳日志 ==\n"
                    + monitor.diagnostics.joined(separator: "\n")
                pb.setString(text, forType: .string)
            }
            .buttonStyle(.bordered)

            Button("立即重启 adb") {
                Task { await model.restartAdb() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            Button("打开日志目录") {
                // 心跳日志持久化在 ~/Library/Application Support/ADBManager/logs/
                // 用 Finder 打开供用户查看历史（跨会话回溯，最多 7 天）
                NSWorkspace.shared.open(MonitorLogger.shared.logDirectory)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("关闭") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}
