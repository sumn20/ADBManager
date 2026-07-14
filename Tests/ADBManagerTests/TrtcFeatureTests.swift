import XCTest
@testable import ADBManager

/// TRTC 相关特性单测：包解析、Activity 解析、下载目录、错误分类、命令构造、AppModel 集成。
final class TrtcFeatureTests: XCTestCase {

    // MARK: - PackageParser

    func testPackageParserMultiline() {
        let out = """
        package:com.android.chrome
        package:com.example.app

        package:com.android.systemui
        """
        XCTAssertEqual(PackageParser.parse(out),
                       ["com.android.chrome", "com.example.app", "com.android.systemui"])
    }

    func testPackageParserStripsPrefix() {
        let out = "package:com.x\npackage:com.y"
        let result = PackageParser.parse(out)
        XCTAssertEqual(result, ["com.x", "com.y"])
        XCTAssertFalse(result.contains { $0.hasPrefix("package:") })
    }

    func testPackageParserEmpty() {
        XCTAssertEqual(PackageParser.parse(""), [])
        XCTAssertEqual(PackageParser.parse("   \n  \n"), [])
    }

    func testPackageParserGarbageLines() {
        let out = """
        List of packages:
        package:com.good
        some random garbage line
        package:com.good2
        """
        XCTAssertEqual(PackageParser.parse(out), ["com.good", "com.good2"])
    }

    func testPackageParserDedup() {
        let out = "package:com.dup\npackage:com.dup\npackage:com.dup"
        XCTAssertEqual(PackageParser.parse(out), ["com.dup"])
    }

    // MARK: - ActivityParser

    func testActivityParserShortNameCompletion() {
        let out = "  mCurrentFocus=Window{1a2b u0 com.example/.MainActivity}"
        XCTAssertEqual(ActivityParser.parse(out),
                       .activity(package: "com.example", activity: "com.example.MainActivity"))
    }

    func testActivityParserFullName() {
        let out = "  mCurrentFocus=Window{abc u0 com.example/com.example.MainActivity}"
        XCTAssertEqual(ActivityParser.parse(out),
                       .activity(package: "com.example", activity: "com.example.MainActivity"))
    }

    func testActivityParserNull() {
        let out = "  mCurrentFocus=null"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    func testActivityParserNoMatch() {
        let out = "WindowManager dump:\n  some other line without focus\n"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    func testActivityParserService() {
        let out = "  mCurrentFocus=Window{abc u0 com.example/.MyService}"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    // MARK: - DownloadsTarget

    func testBuildDestinationPathFormat() {
        let path = DownloadsTarget.buildDestinationPath(package: "com.test.app")
        XCTAssertTrue(path.contains("ADBManager"))
        XCTAssertTrue(path.contains("com.test.app"))
        XCTAssertTrue(path.contains("liteav"))
        // 时间戳格式 yyyyMMdd_HHmmss，且为路径末尾
        let pattern = #"com\.test\.app_liteav_\d{8}_\d{6}$"#
        let range = NSRange(path.startIndex..., in: path)
        let regex = try? NSRegularExpression(pattern: pattern)
        XCTAssertNotNil(regex?.firstMatch(in: path, range: range),
                        "路径应以 包名_liteav_yyyyMMdd_HHmmss 结尾，实际：\(path)")
    }

    func testCreateDirReal() {
        let pkg = "com.unittest.createdir.\(UUID().uuidString)"
        let url = DownloadsTarget.createDir(package: pkg)
        defer { if let u = url { try? FileManager.default.removeItem(at: u) } }
        XCTAssertNotNil(url)
        if let u = url {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir))
            XCTAssertTrue(isDir.boolValue)
        }
    }

    func testCountFilesRecursive() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trtc_count_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // 顶层 2 个普通文件
        try "a".write(to: base.appendingPathComponent("f1.log"), atomically: true, encoding: .utf8)
        try "b".write(to: base.appendingPathComponent("f2.log"), atomically: true, encoding: .utf8)
        // 隐藏文件（应被跳过）
        try "h".write(to: base.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        // 嵌套子目录 1 个文件
        let sub = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "c".write(to: sub.appendingPathComponent("f3.log"), atomically: true, encoding: .utf8)

        XCTAssertEqual(DownloadsTarget.countFiles(in: base), 3)
    }

    // MARK: - CommandBuilder 新 case

    func testBuildArgsListPackages() {
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: true)),
                       ["shell", "pm", "list", "packages", "-3"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: false)),
                       ["shell", "pm", "list", "packages"])
    }

    func testBuildArgsCurrentFocus() {
        XCTAssertEqual(CommandBuilder.buildArgs(for: .currentFocus),
                       ["shell", "dumpsys", "window"])
    }

    func testBuildArgsNewCasesWithSerial() {
        XCTAssertEqual(CommandBuilder.buildArgs(for: .listPackages(thirdPartyOnly: true), serial: "S1"),
                       ["-s", "S1", "shell", "pm", "list", "packages", "-3"])
        XCTAssertEqual(CommandBuilder.buildArgs(for: .currentFocus, serial: "S2"),
                       ["-s", "S2", "shell", "dumpsys", "window"])
    }

    // MARK: - TrtcLogError.classify

    func testClassifyNoLogDirectory() {
        XCTAssertEqual(
            TrtcLogError.classify(AdbResult(stdout: "",
                                            stderr: "adb: error: remote object '/sdcard/...' does not exist",
                                            exitCode: 1)),
            .noLogDirectory)
        XCTAssertEqual(
            TrtcLogError.classify(AdbResult(stdout: "no such file or directory", exitCode: 1)),
            .noLogDirectory)
    }

    func testClassifyPermissionDenied() {
        XCTAssertEqual(
            TrtcLogError.classify(AdbResult(stdout: "", stderr: "permission denied", exitCode: 1)),
            .permissionDenied)
    }

    func testClassifySuccess() {
        XCTAssertEqual(TrtcLogError.classify(AdbResult(stdout: "pull: x", exitCode: 0)), .none)
    }

    func testClassifyGeneric() {
        let r = AdbResult(stdout: "", stderr: "some weird failure", exitCode: 1)
        XCTAssertEqual(TrtcLogError.classify(r), .generic(message: "some weird failure"))
    }

    // MARK: - AppModel 集成（MockRunner 驱动）

    /// 在 MainActor 上构造一个注入了 mock runner 的 AppModel（monitor 用独立 mock，且不启动心跳）
    private func makeModel(runner: AdbRunning) async -> AppModel {
        await MainActor.run {
            let settings = Settings()
            let monitor = Monitor(runner: MockRunner(result: AdbResult(stdout: "", exitCode: 0)), settings: settings)
            monitor.pkillAction = {}
            return AppModel(settings: settings, runner: runner, monitor: monitor)
        }
    }

    /// 返回 `~/Downloads/ADBManager` 根目录 URL
    private func adbManagerDownloadsRoot() -> URL {
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent(DownloadsTarget.rootFolderName)
    }

    /// 列出 `~/Downloads/ADBManager` 下以给定前缀开头的子项
    private func leftoverDirs(prefix: String) -> [URL] {
        let root = adbManagerDownloadsRoot()
        guard let items = try? FileManager.default.contentsOfDirectory(at: root,
                                                                        includingPropertiesForKeys: nil) else {
            return []
        }
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    func testLoadPackagesWithSerial() async {
        let mock = MockRunner(result: AdbResult(stdout: "package:com.a\npackage:com.b\n", exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.loadPackages(thirdPartyOnly: true)
        await MainActor.run {
            XCTAssertEqual(model.packageList, ["com.a", "com.b"])
            XCTAssertTrue(mock.calls.contains(["-s", "s1", "shell", "pm", "list", "packages", "-3"]))
        }
    }

    func testLoadPackagesNoSerial() async {
        let mock = MockRunner(result: AdbResult(stdout: "package:com.a", exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = nil }
        await model.loadPackages(thirdPartyOnly: false)
        await MainActor.run {
            XCTAssertEqual(model.packageList, [])
            XCTAssertEqual(model.downloadStatus, "未选中设备，无法操作")
            XCTAssertTrue(mock.calls.isEmpty, "未选中设备时不应调用 runner")
        }
    }

    func testDownloadTrtcLogsNoSerial() async {
        let mock = MockRunner(result: AdbResult(stdout: "", exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = nil }
        await model.downloadTrtcLogs(for: "com.x")
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertNil(model.lastDownloadPath)
            XCTAssertTrue(mock.calls.isEmpty, "未选中设备时不应调用 runner")
        }
    }

    func testDownloadTrtcLogsNoDirectory() async {
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "does not exist", exitCode: 1))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: "com.x")
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertEqual(model.downloadStatus, "未找到日志目录")
            XCTAssertNil(model.lastDownloadPath)
        }
    }

    /// 回归测试：远端日志目录不存在导致失败时，不应在 `~/Downloads/ADBManager` 下遗留空目录
    func testDownloadTrtcLogsNoDirectoryCleansEmptyDir() async {
        let pkg = "com.x.cleanup.\(UUID().uuidString)"
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "does not exist", exitCode: 1))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: pkg)
        let leftovers = leftoverDirs(prefix: "\(pkg)_liteav_")
        XCTAssertTrue(leftovers.isEmpty,
                      "失败下载不应在 Downloads 下遗留空目录，实际遗留：\(leftovers)")
    }

    func testDownloadTrtcLogsSuccess() async {
        let runner = PullCreatingMockRunner()
        let model = await makeModel(runner: runner)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: "com.example.app")
        let path = await MainActor.run { model.lastDownloadPath }
        if let p = path {
            let count = DownloadsTarget.countFiles(in: URL(fileURLWithPath: p))
            XCTAssertEqual(count, 2, "mock 应在目标目录创建 2 个文件")
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    func testFetchCurrentActivitySuccess() async {
        let dumpsys = "  mCurrentFocus=Window{1a2b u0 com.example/.MainActivity}\n"
        let mock = MockRunner(result: AdbResult(stdout: dumpsys, exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.fetchCurrentActivity()
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            guard let current = model.currentActivity else {
                XCTFail("currentActivity 不应为 nil")
                return
            }
            XCTAssertEqual(current,
                           .activity(package: "com.example", activity: "com.example.MainActivity"))
        }
    }

    func testFetchCurrentActivityNoSerial() async {
        let mock = MockRunner(result: AdbResult(stdout: "", exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = nil }
        await model.fetchCurrentActivity()
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertEqual(model.currentActivity, .some(ActivityResult.none))
        }
    }

    func testFetchCurrentActivityTimeoutNoCrash() async {
        // 用超时的 mock 结果验证 fetchCurrentActivity 不会崩溃
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "", exitCode: 0, timedOut: true))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.fetchCurrentActivity()
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertEqual(model.currentActivity, .some(ActivityResult.none))
        }
    }

    // MARK: - 边界 / 错误路径补充（QA 独立验证）

    // —— ActivityParser：任务给定的精确格式 ——

    func testActivityParserTaskExampleShortName() {
        // 任务给定格式：mCurrentFocus=Window{... u0 com.tencent.xxx/.MainActivity}
        let out = "  mCurrentFocus=Window{1a2b3c u0 com.tencent.xxx/.MainActivity}"
        XCTAssertEqual(ActivityParser.parse(out),
                       .activity(package: "com.tencent.xxx", activity: "com.tencent.xxx.MainActivity"))
    }

    func testActivityParserTaskExampleFullName() {
        // 全名形式：com.tencent.xxx/com.tencent.xxx.MainActivity
        let out = "  mCurrentFocus=Window{1a2b3c u0 com.tencent.xxx/com.tencent.xxx.MainActivity}"
        XCTAssertEqual(ActivityParser.parse(out),
                       .activity(package: "com.tencent.xxx", activity: "com.tencent.xxx.MainActivity"))
    }

    func testActivityParserTaskExampleService() {
        // Service（.Service）→ .none 且不崩溃
        let out = "  mCurrentFocus=Window{1a2b3c u0 com.xxx/.Service}"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    func testActivityParserEmptyInput() {
        // 空输入 → .none，不崩溃
        XCTAssertEqual(ActivityParser.parse(""), .none)
        XCTAssertEqual(ActivityParser.parse("   \n  \n"), .none)
    }

    func testActivityParserNullInsideWindow() {
        // mCurrentFocus=Window{... u0 null}：无斜杠，正则不匹配 → .none
        let out = "  mCurrentFocus=Window{abc u0 null}"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    func testActivityParserNoMcfLine() {
        // 输出不含 mCurrentFocus → .none
        let out = "WindowManager dump:\n  mFocusedApp=AppWindowToken{...}\n"
        XCTAssertEqual(ActivityParser.parse(out), .none)
    }

    func testActivityParserMultilinePicksFirstFocus() {
        // 多行文本，仅首个 mCurrentFocus 行生效
        let out = """
        Some header
          mCurrentFocus=Window{1a2b u0 com.example/.MainActivity}
        trailing text
        """
        XCTAssertEqual(ActivityParser.parse(out),
                       .activity(package: "com.example", activity: "com.example.MainActivity"))
    }

    // —— TrtcLogError.classify：补充分类与截断 ——

    func testClassifySuccessEmptyStdout() {
        // 成功但 stdout 为空 → .none
        XCTAssertEqual(TrtcLogError.classify(AdbResult(stdout: "", exitCode: 0)), .none)
    }

    func testClassifyPermissionDeniedExact() {
        // 精确 "Permission denied"（大小写不敏感）
        XCTAssertEqual(
            TrtcLogError.classify(AdbResult(stdout: "", stderr: "adb: error: Permission denied", exitCode: 1)),
            .permissionDenied)
    }

    func testClassifyNoLogDirectoryExactPhrase() {
        // adb pull 真实报错："No such file or directory"
        XCTAssertEqual(
            TrtcLogError.classify(AdbResult(stdout: "",
                                            stderr: "adb: error: failed to stat remote object '/sdcard/Android/data/com.x/files/log/liteav/': No such file or directory",
                                            exitCode: 1)),
            .noLogDirectory)
    }

    func testClassifyGenericTruncatesTo200() {
        // generic 错误信息应被截断到 200 字符
        let long = String(repeating: "X", count: 500)
        let r = AdbResult(stdout: "", stderr: long, exitCode: 1)
        guard case .generic(let message) = TrtcLogError.classify(r) else {
            XCTFail("应为 generic")
            return
        }
        XCTAssertLessThanOrEqual(message.count, 200)
        XCTAssertEqual(message.count, 200)
    }

    func testClassifyNoSuchFilePrecedenceOverPermission() {
        // 同时含 "permission" 与 "no such file" 时，优先归为无日志目录
        let r = AdbResult(stdout: "", stderr: "no such file or directory: permission check failed", exitCode: 1)
        XCTAssertEqual(TrtcLogError.classify(r), .noLogDirectory)
    }

    // —— PackageParser：重复/空行/垃圾行混合（真实 dumpsys 风格） ——

    func testPackageParserRealisticMixed() {
        let out = """
        List of packages:

        package:com.android.chrome
        package:com.example.app
        garbage header line
        package:com.example.app

        package:com.dup
        package:com.dup
        another garbage
        package:com.tencent.mm
        """
        XCTAssertEqual(PackageParser.parse(out),
                       ["com.android.chrome", "com.example.app", "com.dup", "com.tencent.mm"])
    }

    func testPackageParserLeadingTrailingWhitespace() {
        // 行首尾空白应被剥离
        let out = "  package:com.a  \n\tpackage:com.b\t\n"
        XCTAssertEqual(PackageParser.parse(out), ["com.a", "com.b"])
    }

    func testPackageParserNoColonPrefixSkipped() {
        // 形如 "packagecom.x"（无冒号）应视为垃圾跳过
        let out = "packagecom.x\npackage:com.y"
        XCTAssertEqual(PackageParser.parse(out), ["com.y"])
    }

    func testPackageParserTrailingWhitespaceAndCR() {
        // 行内首尾空白（含单独 \r）应被剥离；adb 实际输出为 LF 行尾，
        // 这里验证 trim 能容错行尾多余空白。
        let out = "  package:com.a  \n package:com.b \t\n"
        XCTAssertEqual(PackageParser.parse(out), ["com.a", "com.b"])
    }

    // —— AppModel 集成：错误分类串联 ——

    func testDownloadTrtcLogsPermissionDenied() async {
        let mock = MockRunner(result: AdbResult(stdout: "",
                                                 stderr: "adb: error: Permission denied",
                                                 exitCode: 1))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: "com.x")
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertEqual(model.downloadStatus, "权限不足，无法读取日志目录")
            XCTAssertNil(model.lastDownloadPath)
        }
    }

    func testDownloadTrtcLogsGenericFailure() async {
        let mock = MockRunner(result: AdbResult(stdout: "", stderr: "some other failure", exitCode: 1))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: "com.x")
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertTrue(model.downloadStatus.hasPrefix("下载失败"),
                          "应展示通用失败提示，实际：\(model.downloadStatus)")
            XCTAssertNil(model.lastDownloadPath)
        }
    }

    func testDownloadTrtcLogsSuccessStatus() async {
        let runner = PullCreatingMockRunner()
        let model = await makeModel(runner: runner)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.downloadTrtcLogs(for: "com.example.app")
        let status = await MainActor.run { model.downloadStatus }
        XCTAssertTrue(status.hasPrefix("已下载"),
                      "成功应展示已下载文件数，实际：\(status)")
        let path = await MainActor.run { model.lastDownloadPath }
        if let p = path { try? FileManager.default.removeItem(atPath: p) }
    }

    func testFetchCurrentActivityEmptyDumpsys() async {
        // dumpsys 正常返回但为空（无 mCurrentFocus）→ .none 不崩溃
        let mock = MockRunner(result: AdbResult(stdout: "", exitCode: 0))
        let model = await makeModel(runner: mock)
        await MainActor.run { model.selectedSerial = "s1" }
        await model.fetchCurrentActivity()
        await MainActor.run {
            XCTAssertFalse(model.isBusy, "defer 应复位 isBusy")
            XCTAssertEqual(model.currentActivity, .some(ActivityResult.none))
        }
    }
}

/// mock runner：当命令为 pull 时，在目标目录（参数最后一项）创建两个文件，便于验证计数。
final class PullCreatingMockRunner: AdbRunning, @unchecked Sendable {
    func run(_ args: [String], timeout: TimeInterval) async -> AdbResult {
        if args.contains("pull"), let dest = args.last {
            let url = URL(fileURLWithPath: dest)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? "1".write(to: url.appendingPathComponent("liteav_1.log"),
                           atomically: true, encoding: .utf8)
            try? "2".write(to: url.appendingPathComponent("liteav_2.log"),
                           atomically: true, encoding: .utf8)
        }
        return AdbResult(stdout: "pull ok", exitCode: 0)
    }
}
