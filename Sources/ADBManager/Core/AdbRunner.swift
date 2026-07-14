import Foundation

/// adb 单次执行的结果封装
public struct AdbResult: Sendable {
    /// 标准输出原始字节（截图等二进制命令使用此字段）
    public let outputData: Data
    /// 标准错误原始字节
    public let stderrData: Data
    /// 进程退出码
    public let exitCode: Int32
    /// 是否因超时被终止
    public let timedOut: Bool

    public init(outputData: Data = Data(), stderrData: Data = Data(), exitCode: Int32 = 0, timedOut: Bool = false) {
        self.outputData = outputData
        self.stderrData = stderrData
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    /// 标准输出文本（UTF-8 解码，失败返回空串）
    public var stdout: String {
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    /// 标准错误文本（UTF-8 解码，失败返回空串）
    public var stderr: String {
        return String(data: stderrData, encoding: .utf8) ?? ""
    }

    /// 是否执行成功：未超时且退出码为 0
    public var success: Bool {
        return !timedOut && exitCode == 0
    }
}

extension AdbResult {
    /// 便捷构造（用于单测与手写结果）
    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0, timedOut: Bool = false) {
        self.init(outputData: Data(stdout.utf8), stderrData: Data(stderr.utf8), exitCode: exitCode, timedOut: timedOut)
    }
}

/// 执行 adb 的抽象协议，便于测试时注入 mock
public protocol AdbRunning: Sendable {
    func run(_ args: [String], timeout: TimeInterval) async -> AdbResult
}

/// 真实的 adb 执行器，基于 Foundation.Process
public final class AdbRunner: AdbRunning, Sendable {
    /// adb 可执行文件路径
    public let adbPath: String

    public init(adbPath: String) {
        self.adbPath = adbPath
    }

    /// 自动探测 adb 路径：优先使用 override，否则按候选顺序查找第一个存在的可执行文件
    public static func detectAdbPath(override: String? = nil) -> String? {
        if let override, !override.isEmpty {
            if FileManager.default.isExecutableFile(atPath: override) {
                return override
            }
            return nil
        }
        // 1. which adb
        if let w = which("adb"), FileManager.default.isExecutableFile(atPath: w) {
            return w
        }
        // 2. 固定候选路径 + 环境变量相关路径
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let androidHome = ProcessInfo.processInfo.environment["ANDROID_HOME"]
        var candidates: [String] = [
            "/opt/local/bin/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/usr/bin/adb"
        ]
        if let ah = androidHome {
            candidates.append("\(ah)/platform-tools/adb")
        }
        candidates.append("\(home)/Library/Android/sdk/platform-tools/adb")
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// 执行 `which` 命令定位可执行文件
    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 阻塞执行（应在后台线程调用），超时后终止进程
    private func runBlocking(_ args: [String], timeout: TimeInterval) -> AdbResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        // 关键：必须在 waitUntilExit() 之前并发地把两个 pipe 读空。
        // 否则当 adb 输出超过 pipe 内核缓冲区（约 64KB）时，子进程会阻塞在 write，
        // 而父进程阻塞在 waitUntilExit()，形成经典死锁——logcat -d / getprop /
        // dumpsys window / pm list packages 等大输出命令必现（表现为每次都超时被杀、输出被截断）。
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let readQueue = DispatchQueue(label: "adb.pipe.reader", attributes: .concurrent)
        readQueue.async(group: group) { outBox.set(outHandle.readDataToEndOfFile()) }
        readQueue.async(group: group) { errBox.set(errHandle.readDataToEndOfFile()) }

        // timedOut 会被超时 workItem（全局队列）写、主流程读，用锁保护消除数据竞争。
        let timeoutFlag = FlagBox()
        let workItem = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            timeoutFlag.set(true)
            process.terminate()
        }

        do {
            try process.run()
        } catch {
            workItem.cancel()
            // 关闭写端，让读取协程收到 EOF 退出，避免泄漏
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            return AdbResult(stdout: "", stderr: "无法启动进程 (\(adbPath))：\(error.localizedDescription)", exitCode: -1, timedOut: false)
        }

        // 超时后终止进程
        if timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: workItem)
        }

        process.waitUntilExit()
        workItem.cancel()
        // 进程已退出，pipe 写端关闭 → 两个读取协程读到 EOF 结束，这里等它们收尾。
        group.wait()

        return AdbResult(outputData: outBox.value,
                         stderrData: errBox.value,
                         exitCode: process.terminationStatus,
                         timedOut: timeoutFlag.value)
    }

    /// 对外异步接口：在后台线程执行阻塞调用，避免阻塞调用方
    public func run(_ args: [String], timeout: TimeInterval) async -> AdbResult {
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let result = self.runBlocking(args, timeout: timeout)
                continuation.resume(returning: result)
            }
        }
    }
}

/// 线程安全的 Data 容器：供并发 pipe 读取协程写入、主流程读取。
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// 线程安全的布尔标志容器：供超时 workItem 写、主流程读。
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ v: Bool) { lock.lock(); flag = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
