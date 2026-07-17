import Foundation
import Combine
import AppKit

/// 视图模型：串联 runner / monitor / settings 与 UI 状态
/// 标记为 @MainActor：所有异步方法均由 SwiftUI 的 `Task`（继承 @MainActor）调用，
/// UI 更新与状态读写统一在主线程进行；runner 为 Sendable、monitor 同为 @MainActor，跨 actor 发送安全。
@MainActor
public final class AppModel: ObservableObject {
    @Published public var settings: Settings
    @Published public var runner: AdbRunning
    @Published public var monitor: Monitor

    @Published public var adbPath: String = ""
    @Published public var adbVersion: String = "未知"
    @Published public var devices: [Device] = []
    @Published public var selectedSerial: String? = nil
    @Published public var terminalOutput: String = ""
    @Published public var isBusy: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var screenshotData: Data? = nil
    @Published public var showScreenshot: Bool = false
    /// 「应用状态」诊断 dialog 的展示开关
    @Published public var showDiagnostics: Bool = false

    /// 桥接嵌套 ObservableObject（settings / monitor）变化用的订阅集合
    private var cancellables = Set<AnyCancellable>()

    // —— scrcpy 相关状态 ——
    @Published public var scrcpyPath: String? = nil
    @Published public var isScrcpyAvailable: Bool = false
    /// 当前正在录屏的 scrcpy 进程（用于停止录屏）
    @Published public var scrcpyRecordProcess: Process? = nil
    /// scrcpy 状态提示（如启动失败、正在录屏等）
    @Published public var scrcpyStatus: String = ""

    // —— TRTC 日志 / 包管理 / 当前 Activity 相关状态 ——
    @Published public var packageList: [String] = []
    @Published public var selectedPackage: String? = nil
    @Published public var downloadStatus: String = ""
    @Published public var lastDownloadPath: String? = nil
    @Published public var currentActivity: ActivityResult? = nil

    /// 默认初始化：自动探测 adb 路径并装配 runner / monitor
    public init() {
        let settings = Settings()
        let path = settings.resolvedAdbPath() ?? "/opt/local/bin/adb"
        let runner = AdbRunner(adbPath: path)
        let monitor = Monitor(runner: runner, settings: settings)
        self.settings = settings
        self.runner = runner
        self.monitor = monitor
        self.adbPath = path
        // 桥接嵌套 ObservableObject 的变化到自身（详见 bindNested 注释）
        bindNested()
        // 启动时立即开启后台心跳（幂等：guard !running）。
        // 依赖窗口/菜单的 onAppear 不可靠——LaunchAgent 后台拉起时窗口未必创建、
        // 菜单栏下拉内容也只在点击展开时才实例化，都会导致心跳永不启动。
        monitor.start()
        // 检测 scrcpy 安装状态
        detectScrcpy()
    }

    /// 供测试注入依赖
    public init(settings: Settings, runner: AdbRunning, monitor: Monitor) {
        self.settings = settings
        self.runner = runner
        self.monitor = monitor
        if let r = runner as? AdbRunner {
            self.adbPath = r.adbPath
        }
        bindNested()
    }

    /// 桥接嵌套 ObservableObject 的变化到自身。
    /// SwiftUI 不会自动把外层 `@Published` 属性（settings / monitor，二者本身是 ObservableObject）
    /// 的**内部**变化传播到持有它们的 AppModel，导致 `ContentView` 读 `model.monitor.lastStatus`、
    /// `DeviceView` 读 `model.settings.savedTcp` 时不刷新——典型症状：心跳早已「可用」，
    /// 顶部状态却一直停在「检测中…」。这里手动转发关键变化。
    private func bindNested() {
        cancellables.removeAll()
        // settings 变化频率低（间隔/自启/TCP 列表），全量转发
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // monitor 仅转发「心跳阶段」变化（setPhase 已去抖），避免每轮心跳都重绘主界面；
        // dropFirst 跳过订阅瞬间的初始值。诊断日志/lastCheck 等高频字段不在此转发，
        // 由 DiagnosticsView 以 @ObservedObject 直接观察 monitor 实时刷新。
        monitor.$phase
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 重启计数变化时也刷新 UI，让「重启中… (第 N 次)」的文案能滚动更新
        monitor.$restartAttempts
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// 重新探测 adb 路径并重建 runner / monitor
    public func refreshPath() {
        if let p = settings.resolvedAdbPath() {
            adbPath = p
            // 先停掉旧心跳循环，再用新 runner 重建并重新启动——
            // 否则新建的 Monitor 从未 start()，旧 Monitor 释放后其循环退出，心跳会永久停摆。
            monitor.stop()
            runner = AdbRunner(adbPath: p)
            let newMonitor = Monitor(runner: runner, settings: settings)
            monitor = newMonitor
            bindNested()          // 重新订阅新 monitor（会先清掉旧订阅）
            newMonitor.start()
            statusMessage = "adb 路径已更新：\(p)"
        } else {
            statusMessage = "未找到 adb，请在设置中指定路径"
        }
    }

    /// 用户操作 adb 命令后的失败钩子：任何 timeout / 非零退出都触发 `monitor.pokeNow()`，
    /// 让心跳立刻探测一轮。因为稳态 AIMD 把探测间隔放宽到 30s，这能保证「用户在用时秒级响应」。
    ///
    /// 例：稳态心跳挂起在第 25s，此刻用户跑命令失败（超时/非零），下一轮探测本要等到 30s；
    /// 调用后立即打断挂起、下一轮探测秒级触发——用户体感"命令一失败工具就发现了"。
    /// 忽略成功结果避免无谓抢占心跳节奏（成功不意味 adb server 有异常）。
    private func pokeMonitorIfFailed(_ r: AdbResult) {
        if r.timedOut || !r.success {
            monitor.pokeNow()
        }
    }

    /// 加载 adb 版本号
    public func loadVersion() async {
        let r = await runner.run(["version"], timeout: 8)
        if r.success {
            adbVersion = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            adbVersion = "获取失败"
            pokeMonitorIfFailed(r)
        }
    }

    /// 刷新设备列表
    public func refreshDevices() async {
        let r = await runner.run(["devices", "-l"], timeout: 8)
        if r.success {
            devices = Device.parse(r.stdout)
            // 选中的设备已断开则清空选择
            if let s = selectedSerial, !devices.contains(where: { $0.serial == s }) {
                selectedSerial = nil
            }
            statusMessage = "已刷新设备列表（\(devices.count) 台）"
        } else {
            statusMessage = "刷新失败：\(r.stderr)"
            pokeMonitorIfFailed(r)
        }
    }

    /// 立即手动重启 adb（含 TCP 重连）
    public func restartAdb() async {
        await monitor.restart()
        await refreshDevices()
        // 打破退避：用户手工干预后，立刻唤醒心跳下一轮探测，
        // 避免退避到 120s 时 adb 已恢复却要等 2 分钟才发现
        monitor.pokeNow()
        statusMessage = "已重启 adb 服务"
    }

    /// 通过 TCP/IP 连接设备
    public func connectTcp(_ address: String) async {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        let args = CommandBuilder.buildArgs(for: .connect(address: a))
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: 8)
        append(r.stdout)
        append(r.stderr)
        if r.success {
            settings.addTcp(a)
        } else {
            pokeMonitorIfFailed(r)
        }
        await refreshDevices()
    }

    /// 断开当前选中的设备
    public func disconnectSelected() async {
        guard let s = selectedSerial else { return }
        let args = CommandBuilder.buildArgs(for: .disconnect(address: s))
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: 8)
        append(r.stdout)
        append(r.stderr)
        pokeMonitorIfFailed(r)
        await refreshDevices()
    }

    /// 执行内置命令；截图命令会弹出预览
    public func runCommand(_ command: AdbCommand, timeout: TimeInterval = 15) async {
        isBusy = true
        defer { isBusy = false }
        let args = CommandBuilder.buildArgs(for: command, serial: selectedSerial)
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: timeout)
        if case .screenshot = command {
            if r.success {
                screenshotData = r.outputData
                showScreenshot = true
                append("截图成功，已弹出预览")
            } else {
                append(r.stderr)
                pokeMonitorIfFailed(r)
            }
            return
        }
        append(r.stdout)
        if !r.stderr.isEmpty {
            append(r.stderr)
        }
        pokeMonitorIfFailed(r)
    }

    /// 执行自定义 adb 命令（参数为空格分隔的原始字符串）
    public func runCustom(_ raw: String, timeout: TimeInterval = 30) async {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let args = CommandBuilder.buildArgs(for: .custom(args: parts), serial: selectedSerial)
        isBusy = true
        defer { isBusy = false }
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: timeout)
        append(r.stdout)
        if !r.stderr.isEmpty {
            append(r.stderr)
        }
        pokeMonitorIfFailed(r)
    }

    /// 向选中设备发送 `input keyevent <code>`（Home / Back / 音量等）
    /// - Parameters:
    ///   - keycode: Android KeyEvent 数字码（如 3=HOME、4=BACK、26=POWER）
    ///   - label: 日志显示用的可读名称（如 "HOME"）
    public func sendKeyEvent(_ keycode: Int, label: String) async {
        guard let serial = selectedSerial, !serial.isEmpty else {
            append("[按键] 未选中设备，无法发送 \(label)")
            statusMessage = "请先选中设备"
            return
        }
        // shell input keyevent <code> —— 走 custom 通道，享受统一日志/超时/心跳 poke
        let args = CommandBuilder.buildArgs(
            for: .custom(args: ["shell", "input", "keyevent", String(keycode)]),
            serial: serial
        )
        append("> adb \(args.joined(separator: " "))  # \(label)")
        let r = await runner.run(args, timeout: 5)
        if !r.stdout.isEmpty { append(r.stdout) }
        if !r.stderr.isEmpty { append(r.stderr) }
        pokeMonitorIfFailed(r)
    }

    /// 终端输出最大保留字符数（约 1 MB UTF-8）。超出时保留末尾 90%，避免 logcat / getprop
    /// 等大输出无限累积——对常驻小工具尤其重要（Peak footprint 会被拉高、swap 增加）。
    private static let terminalMaxChars = 1_000_000
    /// 截断时保留末尾的比例（保留 900_000 字符，丢弃开头 100_000，让"新输出"完整可见）
    private static let terminalKeepChars = 900_000

    /// 向终端输出追加一行（忽略空文本），超过上限时做环形截断
    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        if terminalOutput.isEmpty {
            terminalOutput = text
        } else {
            terminalOutput += "\n" + text
        }
        // 环形截断：超上限则保留末尾 90%，前面加"…已截断"标记提示
        if terminalOutput.count > Self.terminalMaxChars {
            let keepStart = terminalOutput.index(terminalOutput.endIndex, offsetBy: -Self.terminalKeepChars)
            terminalOutput = "…（输出过长已截断）\n" + String(terminalOutput[keepStart...])
        }
    }

    // MARK: - 包管理 / TRTC 日志 / 当前 Activity

    /// 加载已安装应用包列表（可选仅第三方应用）
    /// - Parameter thirdPartyOnly: 为 true 时只列出第三方应用（追加 `-3` 参数）
    public func loadPackages(thirdPartyOnly: Bool) async {
        guard selectedSerial != nil else {
            downloadStatus = "未选中设备，无法操作"
            return
        }
        let args = CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: thirdPartyOnly), serial: selectedSerial)
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: 8)
        append(r.stdout)
        if !r.stderr.isEmpty {
            append(r.stderr)
        }
        packageList = PackageParser.parse(r.stdout)
        pokeMonitorIfFailed(r)
    }

    /// 下载指定包的 liteav 日志到本机 `~/Downloads/ADBManager` 目录
    /// - Parameter package: 目标应用包名
    public func downloadTrtcLogs(for package: String) async {
        isBusy = true
        defer { isBusy = false }
        guard selectedSerial != nil else {
            downloadStatus = "未选中设备，无法操作"
            return
        }

        let remote = "/sdcard/Android/data/\(package)/files/log/liteav/"
        guard let dest = DownloadsTarget.createDir(package: package) else {
            downloadStatus = "无法创建本地目录"
            return
        }

        let args = CommandBuilder.buildArgs(for: .pull(from: remote, to: dest.path), serial: selectedSerial)
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: 120)
        append(r.stdout)
        append(r.stderr)

        switch TrtcLogError.classify(r) {
        case .noLogDirectory:
            downloadStatus = "未找到日志目录"
            cleanupEmptyDownloadDir(dest)
            // 目录不存在通常是包侧问题（无 TRTC 日志），不代表 adb 挂——不 poke
        case .permissionDenied:
            downloadStatus = "权限不足，无法读取日志目录"
            cleanupEmptyDownloadDir(dest)
            // 同上：权限是设备侧策略问题，不 poke
        case .none:
            let n = DownloadsTarget.countFiles(in: dest)
            lastDownloadPath = dest.path
            downloadStatus = "已下载 \(n) 个文件到 \(dest.path)"
        case .generic(let message):
            downloadStatus = "下载失败：\(message)"
            cleanupEmptyDownloadDir(dest)
            // 未分类失败：可能是 adb 侧异常，poke 一下让心跳复核
            pokeMonitorIfFailed(r)
        }
    }

    /// 下载失败时清理遗留的空目录，避免 `~/Downloads/ADBManager` 下堆积无用的空文件夹。
    /// 仅当目录确实存在且其中没有任何文件时才删除（部分成功留下的文件予以保留）。
    /// - Parameter url: 待清理的本地目标目录
    private func cleanupEmptyDownloadDir(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              DownloadsTarget.countFiles(in: url) == 0 else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// 获取当前前台 Activity（解析 `dumpsys window` 的 mCurrentFocus）
    public func fetchCurrentActivity() async {
        isBusy = true
        defer { isBusy = false }
        guard selectedSerial != nil else {
            currentActivity = ActivityResult.none
            append("未连接设备，无法获取 Activity")
            return
        }

        let args = CommandBuilder.buildArgs(for: .currentFocus, serial: selectedSerial)
        append("> adb \(args.joined(separator: " "))")
        let r = await runner.run(args, timeout: 15)
        append(r.stdout)
        if !r.stderr.isEmpty {
            append(r.stderr)
        }
        currentActivity = ActivityParser.parse(r.stdout)
        if let parsed = currentActivity, parsed == .none {
            append("未检测到前台 Activity")
        }
        pokeMonitorIfFailed(r)
    }

    /// 生成应用自身状态诊断报告（供「应用状态」dialog 展示 / 复制）。
    /// 汇总 adb 路径 / 版本、心跳运行情况、设备与连接状态，便于排查「检测中」「不可用」等问题。
    public func diagnosticsReport() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func fmt(_ d: Date?) -> String { d.map { df.string(from: $0) } ?? "—" }
        let info = Bundle.main.infoDictionary
        let appVer = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"

        var lines: [String] = []
        lines.append("== 应用 ==")
        lines.append("App 版本：\(appVer) (build \(build))")
        lines.append("adb 路径：\(adbPath)")
        lines.append("adb 版本：\(adbVersion)")
        lines.append("")
        lines.append("== 心跳 ==")
        lines.append("运行中：\(monitor.running ? "是" : "否")")
        lines.append("adb 可用：\(monitor.isAdbAvailable ? "是" : "否")（\(monitor.lastStatus)）")
        let base = TimeInterval(settings.interval)
        let cur = monitor.currentInterval
        lines.append("基础间隔：\(Int(base))s　当前间隔：\(Int(cur))s")
        lines.append("稳态上限：\(Int(Monitor.idleCap))s　退避上限：\(Int(Monitor.backoffCap))s")
        // 根据 phase 推断"下一轮探测何时发生 / 为什么"——让 AIMD 递增 / 退避的节奏透明可见
        lines.append("下一轮探测：\(nextProbeDescription(phase: monitor.phase, currentInterval: cur, base: max(1, base)))")
        lines.append("累计重启：\(monitor.restartAttempts) 次")
        lines.append("最近检测：\(fmt(monitor.lastCheck))")
        lines.append("最近重启：\(fmt(monitor.lastRestart))")
        lines.append("心跳可见设备：\(monitor.lastDevices.count) 台")
        lines.append("")
        lines.append("== 设备 / 连接 ==")
        lines.append("列表设备：\(devices.count) 台")
        lines.append("当前选中：\(selectedSerial ?? "—")")
        lines.append("已存 TCP：\(settings.savedTcp.isEmpty ? "—" : settings.savedTcp.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    /// 「下一轮探测」文案：让 AIMD 递增 / MD 收紧 / 指数退避的节奏可见。
    /// - phase: 当前心跳阶段
    /// - currentInterval: 当前挂起间隔（秒）
    /// - base: 基础间隔（秒，非零）
    /// 返回如 "20s 后 → 30s（AIMD 稳态递增）" / "40s 后（退避中）" / "重启完成后决定" 等。
    private func nextProbeDescription(phase: HeartbeatPhase, currentInterval: TimeInterval, base: TimeInterval) -> String {
        switch phase {
        case .available:
            // 成功路径：下一轮走 AIMD 递增
            let next = MonitorDecision.nextIdle(currentInterval, base: base, cap: Monitor.idleCap)
            let capped = next >= Monitor.idleCap
            let tag = capped ? "已封顶 idleCap" : "AIMD 稳态递增"
            return "\(Int(currentInterval))s 后 → 下一轮\(Int(next))s（\(tag)）"
        case .unavailable:
            // 失败重启仍失败：下一轮走指数退避
            let next = MonitorDecision.nextBackoff(currentInterval, base: base, cap: Monitor.backoffCap)
            let capped = next >= Monitor.backoffCap
            let tag = capped ? "已封顶 backoffCap" : "指数退避中"
            return "\(Int(currentInterval))s 后 → 下一轮\(Int(next))s（\(tag)）"
        case .restarting:
            return "重启完成后决定（可用→回 base；失败→退避）"
        case .checking:
            return "首次探测中"
        }
    }

    /// 在 Finder 中打开指定路径（文件则选中高亮，目录则打开目录）
    /// - Parameter path: 本地文件 / 目录路径；为 nil 时直接返回
    public func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    // MARK: - scrcpy

    /// 检测 scrcpy 安装状态（同步，只在 init / 手动刷新时调用）
    public func detectScrcpy() {
        let found = ScrcpyRunner.detectPath()
        scrcpyPath = found
        isScrcpyAvailable = found != nil
        if let p = found {
            append("[scrcpy] 已检测到：\(p)")
        } else {
            append("[scrcpy] 未检测到 scrcpy，请先安装（brew install scrcpy 或前往官网）")
        }
    }

    /// 启动 scrcpy（fire-and-forget），自动加 -s serial（如果有选中设备）
    /// - Parameter args: 额外参数（如 `["-m1024"]`、`["--turn-screen-off"]` 等）
    public func launchScrcpy(args: [String] = []) {
        guard let path = scrcpyPath else {
            scrcpyStatus = "scrcpy 未安装"
            append("[scrcpy] 未安装，无法启动")
            return
        }
        let currentAdb = adbPath
        let currentSerial = selectedSerial
        let result = ScrcpyRunner.launch(
            path: path,
            args: args,
            serial: currentSerial,
            adbPath: currentAdb,
            stderrHandler: { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.append("[scrcpy] \(trimmed)")
                }
            },
            terminationHandler: { [weak self] code in
                Task { @MainActor [weak self] in
                    self?.append("[scrcpy] 进程退出（exit=\(code)）")
                    if code != 0 {
                        self?.scrcpyStatus = "scrcpy 已退出（exit=\(code)），请查看输出日志"
                    }
                }
            }
        )
        append("[scrcpy] 启动命令：\(result.command)")
        if let proc = result.process {
            scrcpyStatus = "已启动 scrcpy（PID \(proc.processIdentifier)）"
            append("[scrcpy] 已启动，PID=\(proc.processIdentifier)，设备=\(currentSerial ?? "默认")")
        } else {
            scrcpyStatus = "scrcpy 启动失败：\(result.launchError ?? "未知错误")"
            append("[scrcpy] 启动失败：\(result.launchError ?? "未知错误")")
        }
    }

    /// 开始 scrcpy 录屏（录屏文件落在 ~/Downloads/ADBManager/）
    public func startScrcpyRecord() {
        guard let path = scrcpyPath else {
            scrcpyStatus = "scrcpy 未安装"
            append("[scrcpy] 未安装，无法录屏")
            return
        }
        guard scrcpyRecordProcess == nil else {
            scrcpyStatus = "已在录屏中"
            append("[scrcpy] 已在录屏中，忽略重复启动")
            return
        }

        // 确保下载目录存在（复用 DownloadsTarget 的根目录）
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let dir = downloads.appendingPathComponent(DownloadsTarget.rootFolderName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "scrcpy_record_\(df.string(from: Date())).mp4"
        let filePath = dir.appendingPathComponent(filename).path

        let args = ["--record=\(filePath)"]
        let currentAdb = adbPath
        let currentSerial = selectedSerial

        let result = ScrcpyRunner.launch(
            path: path,
            args: args,
            serial: currentSerial,
            adbPath: currentAdb,
            stderrHandler: { [weak self] text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.append("[scrcpy] \(trimmed)")
                }
            },
            terminationHandler: { [weak self] code in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.append("[scrcpy] 录屏进程退出（exit=\(code)）")
                    self.scrcpyRecordProcess = nil
                    if code == 0 {
                        self.scrcpyStatus = "录屏已结束：\(filePath)"
                    } else {
                        self.scrcpyStatus = "录屏异常退出（exit=\(code)）"
                    }
                }
            }
        )
        append("[scrcpy] 录屏命令：\(result.command)")
        if let proc = result.process {
            scrcpyRecordProcess = proc
            scrcpyStatus = "正在录屏（PID \(proc.processIdentifier)）：\(filename)"
            append("[scrcpy] 录屏已启动，PID=\(proc.processIdentifier)，输出=\(filePath)")
        } else {
            scrcpyStatus = "scrcpy 录屏启动失败：\(result.launchError ?? "未知错误")"
            append("[scrcpy] 录屏启动失败：\(result.launchError ?? "未知错误")")
        }
    }

    /// 停止当前 scrcpy 录屏
    public func stopScrcpyRecord() {
        guard let process = scrcpyRecordProcess else {
            scrcpyStatus = "没有正在进行的录屏"
            append("[scrcpy] 没有正在进行的录屏")
            return
        }
        process.terminate()
        // terminationHandler 会清理 scrcpyRecordProcess
        scrcpyStatus = "正在停止录屏..."
        append("[scrcpy] 已发送停止信号（SIGTERM）")
    }
}
