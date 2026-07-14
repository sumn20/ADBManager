import SwiftUI

/// 主界面：左侧设备，右侧命令面板 + 终端；顶部工具栏
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            DeviceView()
                .navigationTitle("设备")
        } detail: {
            // 高度分配：使用 VSplitView，命令区与输出区之间是一根「可拖动的分隔条」，
            // 用户可自由拖拽调整两者的高度比例。各自设置最小高度避免被压扁。
            VSplitView {
                CommandView()
                    .frame(minHeight: 160)
                TerminalView()
                    .frame(minHeight: 120)
            }
        }
        .toolbar {
            // 状态指示：仅显示「可用 / 不可用」两种状态，基于心跳检测结果
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(phaseColor(model.monitor.phase))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    Text(model.monitor.lastStatus)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    // 重启中/不可用时显示重启次数（便于用户感知进展，避免以为 UI 卡死）
                    if model.monitor.restartAttempts > 1,
                       (model.monitor.phase == .restarting || model.monitor.phase == .unavailable) {
                        Text("(第\(model.monitor.restartAttempts)次)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            ToolbarItem {
                Stepper("间隔 \(model.settings.interval)s", value: Binding(
                    get: { model.settings.interval },
                    set: { model.settings.interval = $0 }
                ), in: 1...3600)
            }
            ToolbarItem {
                Button("版本: \(model.adbVersion)") {
                    Task { await model.loadVersion() }
                }
            }
            ToolbarItem {
                Button("状态") {
                    model.showDiagnostics = true
                }
            }
            ToolbarItem {
                Button("立即重启") {
                    Task { await model.restartAdb() }
                }
                .disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $model.showScreenshot, onDismiss: {
            // 关闭截图预览后立刻释放 PNG 数据（1~5MB/张），避免反复截图占内存
            model.screenshotData = nil
        }) {
            ScreenshotView()
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsView(monitor: model.monitor)
        }
    }

    /// 心跳阶段对应的状态点颜色：可用=绿 / 重启中=橙 / 不可用=红 / 检测中=灰
    private func phaseColor(_ phase: HeartbeatPhase) -> Color {
        switch phase {
        case .available: return .green
        case .restarting: return .orange
        case .unavailable: return .red
        case .checking: return .gray
        }
    }
}
