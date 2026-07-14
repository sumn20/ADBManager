import Foundation
import Combine

/// 心跳算法纯函数集合（便于单测，无副作用）
public enum MonitorDecision {
    /// 是否需要重启：心跳探测失败（超时或非零退出）即判定需要救活。
    /// 自动重启是工具的核心能力，无条件执行，不再依赖开关。
    public static func shouldRestart(result: AdbResult) -> Bool {
        return result.timedOut || !result.success
    }

    /// 指数退避：连续失败时把心跳间隔翻倍，封顶 cap，下限 base。
    /// - previous: 上一轮的间隔（秒）；首轮用 0 表示"尚未退避"（首轮直接退到 base）
    /// - base: 基础间隔（秒）
    /// - cap: 退避上限（秒）
    ///
    /// 语义：**失败后至少保持 base，然后每次翻倍到 cap 封顶**。
    /// - previous=0 → base（首轮退避保持 base，不立即翻倍）
    /// - previous>0 → clamp(previous*2, base, cap)
    public static func nextBackoff(_ previous: TimeInterval, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        return min(cap, max(base, previous * 2))
    }
}

/// 心跳阶段：驱动 UI 的状态指示（颜色 / 文案）与去抖判定的唯一真相源。
public enum HeartbeatPhase: String, Equatable, Sendable {
    /// 首次检测中（初始占位，仅出现在首轮 tick 完成前）
    case checking
    /// adb 可用
    case available
    /// 探测失败，正在自动重启（此前显示「可用」时也会切到此态，让异常即时可见）
    case restarting
    /// 重启后仍不可用
    case unavailable

    /// 状态文案（供 lastStatus / 诊断报告展示）
    public var label: String {
        switch self {
        case .checking: return "检测中…"
        case .available: return "可用"
        case .restarting: return "重启中…"
        case .unavailable: return "不可用"
        }
    }
}

/// 后台心跳监测器：检测 adb 是否存活，不可用时**无条件自动重启**并重连 TCP 设备
/// 标记为 @MainActor，使所有状态更新都发生在主线程，避免跨 actor 发送错误。
@MainActor
public final class Monitor: ObservableObject {
    public let runner: AdbRunning
    public let settings: Settings

    /// 可注入的 pkill 兜底动作（默认执行真实 `pkill -f "adb -L"`，测试时可替换为空操作）
    public var pkillAction: () async -> Void = { await Monitor.defaultPkill() }

    @Published public private(set) var running: Bool = false
    @Published public private(set) var lastCheck: Date?
    @Published public private(set) var lastRestart: Date?
    /// 心跳阶段（唯一真相源）：可用 / 重启中 / 不可用 / 检测中。UI 据此显示颜色与文案。
    @Published public private(set) var phase: HeartbeatPhase = .checking
    /// 是否可用（派生自 phase == .available，保留以兼容既有 UI / 测试）
    @Published public private(set) var isAdbAvailable: Bool = false
    /// 状态文案（派生自 phase.label，保留以兼容既有 UI / 测试）
    @Published public private(set) var lastStatus: String = "检测中…"
    @Published public private(set) var lastDevices: [Device] = []
    /// 当前心跳间隔（秒）：成功后重置为基础值，连续失败则指数退避放大。
    @Published public private(set) var currentInterval: TimeInterval = 0
    /// 连续重启次数（每次成功清零）。用于 UI 显示「重启中… (第 N 次)」，
    /// 也让相同 phase 但计数不同的更新能被 @Published 感知（否则 setPhase 去抖会吃掉）。
    @Published public private(set) var restartAttempts: Int = 0

    /// 诊断事件日志（最近 diagMax 条）：记录心跳每轮探测 / 重启 / 状态变化，
    /// 供「应用状态」dialog 实时查看，用于排查「一直检测中」「adb 不可用」等问题。
    @Published public private(set) var diagnostics: [String] = []
    private static let diagMax = 200
    private static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 探测超时（秒）：`adb devices -l` 正常几十毫秒，3s 足够（过长会让 UI 卡在旧状态）
    private static let probeTimeout: TimeInterval = 3
    /// server 生命周期命令超时（秒）：kill/start-server 正常瞬时完成
    private static let serverCmdTimeout: TimeInterval = 3
    /// TCP connect 超时（秒）：并发执行，每台设备各自 8s 上限
    private static let connectTimeout: TimeInterval = 8
    /// 退避上限（秒）
    private static let backoffCap: TimeInterval = 120

    /// 追加一条带时间戳的诊断日志，并做环形截断（一次赋值，最多触发一次 @Published 发布）。
    /// 同时**镜像写入本地文件**（`MonitorLogger`），供崩溃后回看与工程师排查。
    /// - Parameters:
    ///   - level: 级别（INFO/WARN/ERROR），落到本地文件带前缀，内存 UI 用图标符号区分
    ///   - message: 消息正文（不带时间戳，此方法内部会拼上）
    private func diag(_ level: LogLevel = .info, _ message: String) {
        // 1) 内存环形：给诊断 dialog 实时刷新用；HH:mm:ss 简短，配合级别符号增强可读性
        let ts = Monitor.diagTimeFormatter.string(from: Date())
        let icon: String
        switch level {
        case .info:  icon = ""
        case .warn:  icon = "⚠ "
        case .error: icon = "✗ "
        }
        let entry = "[\(ts)] \(icon)\(message)"
        var next = diagnostics
        next.append(entry)
        if next.count > Monitor.diagMax {
            next.removeFirst(next.count - Monitor.diagMax)
        }
        diagnostics = next

        // 2) 本地文件：完整时间戳 + 级别标签（供跨会话回溯，最多保留 7 天）
        MonitorLogger.shared.log(level, message)
    }

    /// 耗时格式化：毫秒展示（Int 毫秒精度足够，避免打印噪音）
    private func elapsedMs(_ start: Date) -> String {
        let ms = Int((Date().timeIntervalSince(start) * 1000).rounded())
        return "\(ms)ms"
    }

    /// 提取 stderr 首行做摘要（超过 120 字符截断），避免多行 adb 报错刷屏
    private func stderrSummary(_ raw: String) -> String {
        let firstLine = raw.split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// 计算设备列表增删差异，用于「可用」时输出更详细的变化日志
    private func deviceDiff(old: [Device], new: [Device]) -> (added: [String], removed: [String]) {
        let oldSerials = Set(old.map(\.serial))
        let newSerials = Set(new.map(\.serial))
        let added = newSerials.subtracting(oldSerials).sorted()
        let removed = oldSerials.subtracting(newSerials).sorted()
        return (added, removed)
    }

    private var task: Task<Void, Never>?
    /// 快速唤醒信号：`pokeNow()` 通过它中断当前 sleep，让下一轮探测立即执行
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    public init(runner: AdbRunning, settings: Settings) {
        self.runner = runner
        self.settings = settings
    }

    /// 更新 @Published 属性（Monitor 为 @MainActor，调用方均处于主线程）
    private func update(_ block: @escaping () -> Void) {
        block()
    }

    /// 开始后台监测循环（幂等：已在跑则直接返回）
    public func start() {
        guard !running else { return }
        update { self.running = true }
        let adbPath = (runner as? AdbRunner)?.adbPath ?? "?"
        diag(.info, "心跳启动｜adb=\(adbPath)｜基础间隔=\(settings.interval)s｜TCP=\(settings.savedTcp.count) 台")
        task = Task { [weak self] in
            while let strong = self, !Task.isCancelled {
                await strong.tick()
            }
            self?.update { self?.running = false }
        }
    }

    /// 停止监测。返回后循环 Task 已收到 cancel 信号，tick 内部会在每个 await 点后短路。
    public func stop() {
        task?.cancel()
        // 也把等待中的 sleep 立刻唤醒，避免要等最长 120s 才响应 cancel
        wakeContinuation?.resume()
        wakeContinuation = nil
        task = nil
        update { self.running = false }
        diag(.info, "心跳停止")
    }

    /// 立即唤醒当前 sleep，让心跳下一轮立刻探测。
    /// 用于用户手工触发操作后（如手动重启 adb / 刷新设备）快速恢复，不用等退避的 120s。
    public func pokeNow() {
        guard let cont = wakeContinuation else { return }
        wakeContinuation = nil
        cont.resume()
    }

    /// 单次心跳
    ///
    /// 流程：
    /// 1. 探测 `adb devices -l`（3s 超时，快速失败）
    /// 2. 可用 → 重置间隔为基础值，去抖发布"可用"
    /// 3. 不可用 → 分级降级重启：kill-server → 重探；仍失败才 pkill → start-server → 并发重连 TCP
    ///    - 重试可用 → 重置间隔，发布"可用"
    ///    - 重试仍不可用 → 间隔指数退避（封顶），发布"不可用"
    /// 4. `sleepFor` 挂起当前轮间隔——挂起期间零 CPU，可被 `stop()` / `pokeNow()` 中断
    func tick() async {
        let base = max(1, TimeInterval(settings.interval))

        let probeStart = Date()
        let result = await runner.run(["devices", "-l"], timeout: Monitor.probeTimeout)
        let probeElapsed = elapsedMs(probeStart)
        update { self.lastCheck = Date() }

        if Task.isCancelled { return }  // stop() 后立刻短路，避免副作用

        // 心跳成功：直接可用，重置退避与重启计数
        if !MonitorDecision.shouldRestart(result: result) {
            let devs = Device.parse(result.stdout)
            let (added, removed) = deviceDiff(old: lastDevices, new: devs)
            if added.isEmpty && removed.isEmpty {
                diag(.info, "探测成功｜耗时=\(probeElapsed)｜设备=\(devs.count) 台")
            } else {
                var changes: [String] = []
                if !added.isEmpty   { changes.append("新增[\(added.joined(separator: ","))]") }
                if !removed.isEmpty { changes.append("断开[\(removed.joined(separator: ","))]") }
                diag(.info, "探测成功｜耗时=\(probeElapsed)｜设备=\(devs.count) 台｜变化：\(changes.joined(separator: " "))")
            }
            setPhase(.available, devices: devs)
            resetRestartAttempts()
            setInterval(base)
            await sleepFor(base)
            return
        }

        // 心跳失败：先把 UI 切到「重启中」，让异常即时可见
        let reason: String
        if result.timedOut {
            reason = "探测超时(>\(Int(Monitor.probeTimeout))s)"
        } else {
            let errSum = stderrSummary(result.stderr)
            reason = errSum.isEmpty ? "探测失败(exit=\(result.exitCode))" : "探测失败(exit=\(result.exitCode))｜stderr=\(errSum)"
        }
        diag(.warn, "\(reason)｜耗时=\(probeElapsed)｜触发自动重启")
        bumpRestartAttempts()
        setPhase(.restarting)

        let restartStart = Date()
        await restart()
        if Task.isCancelled { return }

        let retryStart = Date()
        let retry = await runner.run(["devices", "-l"], timeout: Monitor.probeTimeout)
        let retryElapsed = elapsedMs(retryStart)
        if Task.isCancelled { return }
        let retryOk = !MonitorDecision.shouldRestart(result: retry)

        if retryOk {
            let devs = Device.parse(retry.stdout)
            diag(.info, "重启成功｜重启耗时=\(elapsedMs(restartStart))｜重试探测耗时=\(retryElapsed)｜设备=\(devs.count) 台")
            setPhase(.available, devices: devs)
            resetRestartAttempts()
            setInterval(base)
        } else {
            let retryReason: String
            if retry.timedOut {
                retryReason = "重启后仍超时"
            } else {
                let errSum = stderrSummary(retry.stderr)
                retryReason = errSum.isEmpty ? "重启后仍失败(exit=\(retry.exitCode))" : "重启后仍失败(exit=\(retry.exitCode))｜stderr=\(errSum)"
            }
            diag(.error, "\(retryReason)｜重启耗时=\(elapsedMs(restartStart))｜重试探测耗时=\(retryElapsed)｜累计重启=\(restartAttempts) 次")
            setPhase(.unavailable, devices: Device.parse(retry.stdout))
            let next = MonitorDecision.nextBackoff(currentInterval, base: base, cap: Monitor.backoffCap)
            setInterval(next)
            diag(.warn, "退避间隔 \(Int(currentInterval))s → \(Int(next))s（下一轮探测将延迟）")
        }

        await sleepFor(currentInterval)
    }

    /// 阶段去抖：仅在阶段真正变化时写 @Published，避免每轮 tick 无谓触发 SwiftUI 重绘。
    /// phase 是唯一真相源，并同步派生 isAdbAvailable / lastStatus（兼容既有 UI / 测试）。
    /// 初始为 .checking，首轮 tick 无论结果都会切到其它阶段，天然覆盖初始占位「检测中…」。
    private func setPhase(_ newPhase: HeartbeatPhase, devices: [Device]? = nil) {
        update {
            if self.phase != newPhase {
                self.phase = newPhase
                self.lastStatus = newPhase.label
                self.isAdbAvailable = (newPhase == .available)
            }
            if let devices, self.lastDevices != devices {
                self.lastDevices = devices
            }
        }
    }

    private func setInterval(_ value: TimeInterval) {
        update { self.currentInterval = value }
    }

    private func bumpRestartAttempts() {
        update { self.restartAttempts += 1 }
    }

    private func resetRestartAttempts() {
        if restartAttempts != 0 {
            update { self.restartAttempts = 0 }
        }
    }

    /// 可中断的挂起：注册 wakeContinuation 让 `pokeNow()` / `stop()` 能立刻唤醒。
    /// 相比裸 `Task.sleep`：既节能（零 CPU）又能被主动打断——退避到 120s 时用户手工操作也能实时响应。
    /// 双重 resume 防护：无论超时兜底还是 pokeNow/stop 唤醒，都通过「置空 wakeContinuation」二选一。
    private func sleepFor(_ seconds: TimeInterval) async {
        guard seconds > 0, !Task.isCancelled else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.wakeContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await MainActor.run {
                    guard let self, self.wakeContinuation != nil else { return }
                    // 仍持有 continuation 说明未被 poke/stop 唤醒过，这里由超时正常收尾
                    self.wakeContinuation = nil
                    cont.resume()
                }
            }
        }
    }

    /// 重启 adb（分级降级）：
    /// 1. `kill-server`（正常路径，几十毫秒完成）
    /// 2. 快速探测：还行就跳过 pkill，避免误伤其他 IDE 的 adb（Android Studio 等）
    /// 3. 仍失败才 `pkill -f "adb -L"`（只匹配 adb server 的 fork-server 进程，不误伤真机连接）
    /// 4. `start-server` → 并发 `connect` 所有已存 TCP（相比串行，N 台设备从 N*8s 变为最长 8s）
    /// 5. 探测一次刷新 lastDevices；phase 由调用方（tick / restartAdb）根据结果决定
    public func restart() async {
        let killStart = Date()
        _ = await runner.run(["kill-server"], timeout: Monitor.serverCmdTimeout)
        diag(.info, "  ├ kill-server 完成｜耗时=\(elapsedMs(killStart))")

        // 快速探测：kill-server 后 adb 已能响应说明是"轻挂"，无须 pkill 骚扰其他 adb 用户
        let qpStart = Date()
        let quickProbe = await runner.run(["devices", "-l"], timeout: Monitor.probeTimeout)
        if MonitorDecision.shouldRestart(result: quickProbe) {
            diag(.warn, "  ├ kill-server 后仍无响应（耗时=\(elapsedMs(qpStart))），调用 pkill -f 'adb -L' 兜底")
            let pkStart = Date()
            await pkillAction()
            diag(.info, "  ├ pkill 完成｜耗时=\(elapsedMs(pkStart))")
        } else {
            diag(.info, "  ├ kill-server 已恢复（耗时=\(elapsedMs(qpStart))），跳过 pkill 兜底")
        }

        let startStart = Date()
        _ = await runner.run(["start-server"], timeout: Monitor.serverCmdTimeout)
        diag(.info, "  ├ start-server 完成｜耗时=\(elapsedMs(startStart))")

        // 并发重连所有已存 TCP 设备（串行时 N 台 × 8s → 并发时最长 8s）
        let addrs = settings.savedTcp
        if !addrs.isEmpty {
            let connStart = Date()
            await withTaskGroup(of: Void.self) { group in
                for addr in addrs {
                    group.addTask { [runner] in
                        _ = await runner.run(["connect", addr], timeout: Monitor.connectTimeout)
                    }
                }
            }
            diag(.info, "  ├ 并发重连 TCP \(addrs.count) 台｜耗时=\(elapsedMs(connStart))")
        }

        let finalStart = Date()
        let r = await runner.run(["devices", "-l"], timeout: Monitor.probeTimeout)
        let devs = r.success ? Device.parse(r.stdout) : []
        diag(.info, "  └ 重启后探测｜耗时=\(elapsedMs(finalStart))｜设备=\(devs.count) 台")
        update {
            self.lastRestart = Date()
            // 状态由调用方（tick / 手动 restartAdb）基于后续检测结果决定
            self.lastDevices = devs
        }
    }

    /// 默认兜底：只终结 adb server 进程（`adb -L tcp:5037 fork-server ...`），
    /// **不匹配裸 "adb"**——否则会误杀 Android Studio / 其他 IDE 里挂着的 adb server 与真机连接会话。
    private static func defaultPkill() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "adb -L"]
        do {
            try process.run()
        } catch {
            return
        }
        process.waitUntilExit()
    }
}
