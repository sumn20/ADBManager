import XCTest
import Darwin
@testable import ADBManager

/// 纯逻辑单测：Device 解析、buildArgs 构造、Monitor 决策、AdbRunner 超时/成功
final class AdbTests: XCTestCase {

    // MARK: - Device 解析

    func testDeviceParse() {
        let output = """
        List of devices attached
        emulator-5554  device product:sdk_gphone64_x86_64 model:sdk model transport:id
        192.168.1.5:5555  device model:Pixel transport:network

        """
        let devices = Device.parse(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "emulator-5554")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertTrue(devices[0].detail.contains("model:sdk"))
        XCTAssertEqual(devices[1].serial, "192.168.1.5:5555")
        XCTAssertEqual(devices[1].state, "device")
    }

    func testDeviceParseEmpty() {
        XCTAssertEqual(Device.parse("List of devices attached").count, 0)
    }

    // MARK: - buildArgs 参数构造

    func testBuildArgs() {
        XCTAssertEqual(CommandBuilder.buildArgs(for: .devices), ["devices", "-l"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .connect(address: "1.2.3.4:5555")), ["connect", "1.2.3.4:5555"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .disconnect(address: "1.2.3.4:5555")), ["disconnect", "1.2.3.4:5555"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .disconnect(address: nil)), ["disconnect"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .screenshot), ["exec-out", "screencap", "-p"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .install(apk: "/a/b.apk")), ["install", "-r", "/a/b.apk"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .uninstall(package: "com.x")), ["uninstall", "com.x"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .push(from: "/a", to: "/b")), ["push", "/a", "/b"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .pull(from: "/c", to: "/d")), ["pull", "/c", "/d"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .logcat), ["logcat", "-d", "-v", "time"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .reboot), ["reboot"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .recovery), ["reboot", "recovery"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .bootloader), ["reboot", "bootloader"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .getprop), ["shell", "getprop"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .packages), ["shell", "pm", "list", "packages"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .clear(package: "com.x")), ["shell", "pm", "clear", "com.x"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .screenrecord(duration: 60)), ["shell", "screenrecord", "/sdcard/rec.mp4"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .version), ["version"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .killServer), ["kill-server"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .startServer), ["start-server"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .custom(args: ["shell", "ls"])), ["shell", "ls"])
    }

    func testBuildArgsWithSerial() {
        XCTAssertEqual(
            CommandBuilder.buildArgs(for: .getprop, serial: "emulator-5554"),
            ["-s", "emulator-5554", "shell", "getprop"]
        )
        XCTAssertEqual(
            CommandBuilder.buildArgs(for: .install(apk: "/a.apk"), serial: "serial1"),
            ["-s", "serial1", "install", "-r", "/a.apk"]
        )
        // 空 serial 不插入 -s
        XCTAssertEqual(CommandBuilder.buildArgs(for: .getprop, serial: ""), ["shell", "getprop"])
    }

    // MARK: - Monitor 重启决策（无条件，无开关）

    func testMonitorDecision() {
        let ok = AdbResult(stdout: "List of devices attached\n", exitCode: 0)
        let fail = AdbResult(stdout: "", stderr: "error", exitCode: 1)
        let timeout = AdbResult(stdout: "", stderr: "", exitCode: 0, timedOut: true)

        // 自动重启是核心能力，无条件：成功不重启，失败/超时必重启
        XCTAssertFalse(MonitorDecision.shouldRestart(result: ok))
        XCTAssertTrue(MonitorDecision.shouldRestart(result: fail))
        XCTAssertTrue(MonitorDecision.shouldRestart(result: timeout))
    }

    // MARK: - 指数退避算法

    func testNextBackoff() {
        let base: TimeInterval = 10
        let cap: TimeInterval = 120
        // 首轮（previous=0）→ 保持 base（新语义：失败后至少 base，翻倍到 cap 封顶）
        XCTAssertEqual(MonitorDecision.nextBackoff(0, base: base, cap: cap), base)
        // 连续翻倍
        XCTAssertEqual(MonitorDecision.nextBackoff(10, base: base, cap: cap), 20)
        XCTAssertEqual(MonitorDecision.nextBackoff(20, base: base, cap: cap), 40)
        XCTAssertEqual(MonitorDecision.nextBackoff(40, base: base, cap: cap), 80)
        XCTAssertEqual(MonitorDecision.nextBackoff(80, base: base, cap: cap), cap)
        // 封顶保护
        XCTAssertEqual(MonitorDecision.nextBackoff(120, base: base, cap: cap), cap)
        XCTAssertEqual(MonitorDecision.nextBackoff(999, base: base, cap: cap), cap)
        // 下限保护（不会低于 base，即便 previous 很小）
        XCTAssertEqual(MonitorDecision.nextBackoff(1, base: base, cap: cap), base)
    }

    // MARK: - AdbRunner 真实执行

    func testAdbRunnerSuccess() async {
        let runner = AdbRunner(adbPath: "/bin/echo")
        let r = await runner.run(["hello"], timeout: 5)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertFalse(r.timedOut)
    }

    func testAdbRunnerTimeoutAndTerminate() async {
        // 用 /bin/sleep 作为"会挂起"的进程，验证超时后被 terminate
        let runner = AdbRunner(adbPath: "/bin/sleep")
        let start = Date()
        let r = await runner.run(["5"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.success)
        // 应在超时附近结束，而非真的睡眠 5 秒
        XCTAssertLessThan(elapsed, 4)
    }

    func testAdbRunnerNonZeroExit() async {
        // 通过 /bin/sh -c "exit 7" 验证非零退出码被正确捕获
        let runner = AdbRunner(adbPath: "/bin/sh")
        let r = await runner.run(["-c", "exit 7"], timeout: 5)
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.exitCode, 7)
        XCTAssertFalse(r.timedOut)
    }

    // MARK: - Monitor 重启编排（mock runner，避免真实副作用）

    func testMonitorRestartOrchestration() async {
        let mock = MockRunner(result: AdbResult(stdout: "List of devices attached\n", exitCode: 0))
        let settings = Settings()
        settings.savedTcp = ["192.168.1.5:5555"]
        // Monitor 为 @MainActor，需在 MainActor 上构造
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = {} // 注入空操作，避免测试时真的 pkill
            return m
        }

        await monitor.restart()

        XCTAssertTrue(mock.calls.contains(where: { $0 == ["kill-server"] }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["start-server"] }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["connect", "192.168.1.5:5555"] }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["devices", "-l"] }))
        let lastRestart = await monitor.lastRestart
        XCTAssertNotNil(lastRestart)
    }

    // MARK: - Device.parse 健壮性（边界补充）

    func testDeviceParseStates() {
        // 覆盖 offline / unauthorized / device 三种状态
        let output = """
        List of devices attached
        8087abcd    device
        emulator-5554    offline
        ABCD12EF    unauthorized
        """
        let devices = Device.parse(output)
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].serial, "8087abcd")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertEqual(devices[1].serial, "emulator-5554")
        XCTAssertEqual(devices[1].state, "offline")
        XCTAssertEqual(devices[2].serial, "ABCD12EF")
        XCTAssertEqual(devices[2].state, "unauthorized")
    }

    func testDeviceParseMultiFieldDetail() {
        // 含 model: / transport_id: 等多字段，detail 应被完整保留
        let output = """
        List of devices attached
        192.168.1.10:5555    device product:Pixel model:Pixel_7 transport_id:1
        """
        let devices = Device.parse(output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "192.168.1.10:5555")
        XCTAssertEqual(devices[0].state, "device")
        XCTAssertTrue(devices[0].detail.contains("product:Pixel"))
        XCTAssertTrue(devices[0].detail.contains("model:Pixel_7"))
        XCTAssertTrue(devices[0].detail.contains("transport_id:1"))
    }

    func testDeviceParseRobustAgainstGarbage() {
        // 空行、异常行（不足两字段/单行）不能崩溃，应被安全跳过
        let output = """
        List of devices attached




        garbage_line_without_state
        onlyoneserial
        abc123    device
        """
        let devices = Device.parse(output)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "abc123")
        XCTAssertEqual(devices[0].state, "device")
    }

    func testDeviceParseEmptyString() {
        // 空字符串 / 仅空白不应崩溃
        XCTAssertEqual(Device.parse("").count, 0)
        XCTAssertEqual(Device.parse("   \n  \n").count, 0)
    }

    func testDeviceParseMultipleDevices() {
        let output = """
        List of devices attached
        usb1    device model:A
        tcp1:5555    device model:B transport:network
        usb2    offline
        usb3    unauthorized
        """
        let devices = Device.parse(output)
        XCTAssertEqual(devices.count, 4)
        XCTAssertEqual(devices.map { $0.serial }, ["usb1", "tcp1:5555", "usb2", "usb3"])
    }

    // MARK: - CommandBuilder.buildArgs serial 插放与命令参数（边界补充）

    func testBuildArgsSerialPlacement() {
        // serial 必须插在所有参数最前面（-s <serial> 在最前）
        XCTAssertEqual(CommandBuilder.buildArgs(for: .screenshot, serial: "S1"),
                       ["-s", "S1", "exec-out", "screencap", "-p"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .push(from: "a", to: "b"), serial: "S1"),
                       ["-s", "S1", "push", "a", "b"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .pull(from: "c", to: "d"), serial: "S1"),
                       ["-s", "S1", "pull", "c", "d"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .logcat, serial: "S1"),
                       ["-s", "S1", "logcat", "-d", "-v", "time"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .getprop, serial: "S1"),
                       ["-s", "S1", "shell", "getprop"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .packages, serial: "S1"),
                       ["-s", "S1", "shell", "pm", "list", "packages"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .clear(package: "com.x"), serial: "S1"),
                       ["-s", "S1", "shell", "pm", "clear", "com.x"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .screenrecord(duration: 10), serial: "S1"),
                       ["-s", "S1", "shell", "screenrecord", "/sdcard/rec.mp4"])
    }

    func testBuildArgsNoSerialNoDashS() {
        // 未选中 serial（nil 或空）时不插入 -s
        XCTAssertEqual(CommandBuilder.buildArgs(for: .screenshot, serial: nil),
                       ["exec-out", "screencap", "-p"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .getprop, serial: ""),
                       ["shell", "getprop"])
    }

    // MARK: - CommandBuilder TRTC 新 case（listPackages / currentFocus）

    func testBuildArgsTrtcNewCases() {
        // listPackages：thirdPartyOnly 决定参数是否含 -3
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: true)),
                       ["shell", "pm", "list", "packages", "-3"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: false)),
                       ["shell", "pm", "list", "packages"])
        // currentFocus
        XCTAssertEqual(CommandBuilder.buildArgs(for: .currentFocus),
                       ["shell", "dumpsys", "window"])
        // serial 前缀 -s 位置（插在最前）
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: true), serial: "S1"),
                       ["-s", "S1", "shell", "pm", "list", "packages", "-3"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .currentFocus, serial: "S2"),
                       ["-s", "S2", "shell", "dumpsys", "window"])
    }

    // MARK: - MonitorDecision.shouldRestart 组合（边界补充）

    func testMonitorDecisionCombinations() {
        let ok = AdbResult(stdout: "x", exitCode: 0)
        let timeout = AdbResult(stdout: "", exitCode: 0, timedOut: true)
        let nonZero = AdbResult(stdout: "", stderr: "e", exitCode: 3)

        // 成功 → 不重启
        XCTAssertFalse(MonitorDecision.shouldRestart(result: ok))
        // 超时 → 重启
        XCTAssertTrue(MonitorDecision.shouldRestart(result: timeout))
        // 非零退出 → 重启
        XCTAssertTrue(MonitorDecision.shouldRestart(result: nonZero))
    }

    // MARK: - AdbRunner 真实执行边界（边界补充）

    func testAdbRunnerStdoutCapture() async {
        let runner = AdbRunner(adbPath: "/bin/echo")
        let r = await runner.run(["hello world", "second"], timeout: 5)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world second")
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.timedOut)
    }

    func testAdbRunnerExitCodePassthrough() async {
        // 验证非零退出码被正确透传（不同于既有测试用的 7）
        let runner = AdbRunner(adbPath: "/bin/sh")
        let r = await runner.run(["-c", "exit 42"], timeout: 5)
        XCTAssertFalse(r.success)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.exitCode, 42)
    }

    func testAdbRunnerTimeoutTerminatesResidualProcess() async {
        // 用一个会卡住的进程（sleep 30），超时后确认被 terminate 且无残留
        let pidFile = "/tmp/adb_qa_timeout_pid"
        try? FileManager.default.removeItem(atPath: pidFile)
        let runner = AdbRunner(adbPath: "/bin/sh")
        let args = ["-c", "echo $$ > \(pidFile); exec sleep 30"]
        let start = Date()
        let r = await runner.run(args, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.success)
        XCTAssertLessThan(elapsed, 5)
        // 给系统一点时间回收进程
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let pidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            XCTFail("未能读取 pid 文件，无法验证进程残留")
            return
        }
        // kill(pid, 0) 仅探测存在性：返回 -1(ESRCH) 表示进程已不存在 → 无残留
        let rc = kill(pid, 0)
        XCTAssertEqual(rc, -1, "超时后进程(pid=\(pid))仍存活，存在残留未被终止")
    }

    // MARK: - Monitor.restart 编排（边界补充）

    func testMonitorRestartEmptyTcpNoConnect() async {
        let mock = MockRunner(result: AdbResult(stdout: "List of devices attached\n", exitCode: 0))
        let settings = Settings()
        settings.savedTcp = []   // 空
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = {}
            return m
        }
        await monitor.restart()
        // 空 savedTcp → 不应有任何 connect 调用
        XCTAssertFalse(mock.calls.contains(where: { $0.first == "connect" }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["kill-server"] }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["start-server"] }))
    }

    func testMonitorRestartConnectOrder() async {
        let mock = MockRunner(result: AdbResult(stdout: "List of devices attached\n", exitCode: 0))
        let settings = Settings()
        settings.savedTcp = ["10.0.0.1:5555", "10.0.0.2:5555"]
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = {}
            return m
        }
        await monitor.restart()
        // 新语义：TCP connect 并发执行，各设备顺序不保证；
        // 但整体阶段顺序仍是：kill-server → start-server → (并发 connect) → 最终 devices -l。
        guard let killIdx = mock.calls.firstIndex(of: ["kill-server"]),
              let startIdx = mock.calls.firstIndex(of: ["start-server"]),
              let c1 = mock.calls.firstIndex(of: ["connect", "10.0.0.1:5555"]),
              let c2 = mock.calls.firstIndex(of: ["connect", "10.0.0.2:5555"]),
              let devIdx = mock.calls.lastIndex(of: ["devices", "-l"]) else {
            XCTFail("缺少预期调用：\(mock.calls)")
            return
        }
        XCTAssertLessThan(killIdx, startIdx)
        XCTAssertLessThan(startIdx, c1)
        XCTAssertLessThan(startIdx, c2)
        XCTAssertLessThan(c1, devIdx)
        XCTAssertLessThan(c2, devIdx)
    }

    func testMonitorRestartInvokesPkill() async {
        // 新语义：pkill 只在 kill-server 后 quickProbe 仍失败时才调（避免误伤其他 IDE 的 adb）。
        // 用始终失败的 mock 触发 pkill 路径。
        var pkillCalled = false
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "dead", exitCode: 1))
        let settings = Settings()
        settings.savedTcp = []
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = { pkillCalled = true }
            return m
        }
        await monitor.restart()
        XCTAssertTrue(pkillCalled, "kill-server 后 quickProbe 仍失败时应调 pkill 兜底")
    }

    func testMonitorRestartSkipsPkillWhenAdbRecovers() async {
        // 新语义反面用例：kill-server 后 quickProbe 恢复即跳过 pkill，避免误伤其他 IDE 的 adb。
        var pkillCalled = false
        let mock = MockRunner(result: AdbResult(stdout: "List of devices attached\n", exitCode: 0))
        let settings = Settings()
        settings.savedTcp = []
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = { pkillCalled = true }
            return m
        }
        await monitor.restart()
        XCTAssertFalse(pkillCalled, "kill-server 后 quickProbe 已恢复应跳过 pkill")
    }

    // MARK: - Monitor.tick 心跳集成（无条件重启 + 退避）

    /// 心跳探测失败 → 无条件触发重启编排，且重试仍失败时状态不可用、间隔被退避放大
    func testMonitorTickFailureTriggersRestartAndBackoff() async {
        // mock 始终失败（初始探测失败 → 内部 restart 里的 devices -l 也失败 → 重试失败）
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "dead", exitCode: 1))
        let settings = Settings()
        settings.interval = 1  // 缩短 sleep，避免测试久等
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = {}
            return m
        }

        await monitor.tick()

        // 失败 → 无条件重启（核心能力，无开关）
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["kill-server"] }))
        XCTAssertTrue(mock.calls.contains(where: { $0 == ["start-server"] }))
        // 重试后仍失败 → 状态不可用
        let available = await monitor.isAdbAvailable
        let status = await monitor.lastStatus
        let interval = await monitor.currentInterval
        XCTAssertFalse(available)
        XCTAssertEqual(status, "不可用")
        // 退避：间隔 >= base（新语义：首轮失败后至少保持 base，之后翻倍到 cap 封顶）
        XCTAssertGreaterThanOrEqual(interval, 1)
    }

    /// 心跳探测成功 → 不重启，状态可用，间隔保持基础值
    func testMonitorTickSuccessNoRestart() async {
        let mock = MockRunner(result: AdbResult(stdout: "List of devices attached\n", exitCode: 0))
        let settings = Settings()
        settings.interval = 1
        let monitor = await MainActor.run {
            let m = Monitor(runner: mock, settings: settings)
            m.pkillAction = {}
            return m
        }

        await monitor.tick()

        let available = await monitor.isAdbAvailable
        let status = await monitor.lastStatus
        let interval = await monitor.currentInterval
        XCTAssertTrue(available)
        XCTAssertEqual(status, "可用")
        XCTAssertEqual(interval, 1)
        // 成功路径不调用重启
        XCTAssertFalse(mock.calls.contains(where: { $0 == ["kill-server"] }))
    }
}

/// 测试用 mock runner：记录调用参数并返回预设结果
final class MockRunner: AdbRunning, @unchecked Sendable {
    var result: AdbResult
    var calls: [[String]] = []

    init(result: AdbResult) {
        self.result = result
    }

    func run(_ args: [String], timeout: TimeInterval) async -> AdbResult {
        calls.append(args)
        return result
    }
}
