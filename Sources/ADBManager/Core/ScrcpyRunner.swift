import Foundation

/// scrcpy 路径探测与进程启动工具。
/// scrcpy 是长驻 GUI 进程（有自己的窗口），启动后不 block 主线程，采用 fire-and-forget 模式。
/// 录屏场景需要终止进程，因此返回 Process 引用。
public enum ScrcpyRunner {

    // MARK: - 路径探测

    /// 探测 scrcpy 可执行文件路径，找不到返回 nil。
    /// 顺序：`which scrcpy` → 常见安装路径遍历。
    public static func detectPath() -> String? {
        // 1. which scrcpy
        if let path = whichScrcpy(), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // 2. 常见路径
        let candidates = [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy",
            "/opt/local/bin/scrcpy"
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return c
            }
        }
        return nil
    }

    /// 启动 scrcpy 返回结果。
    public struct LaunchResult {
        public let process: Process?
        /// 启动阶段失败信息（例如 Process.run() 抛异常）
        public let launchError: String?
        /// 用于日志展示的最终命令行
        public let command: String
    }

    /// 启动 scrcpy 进程（fire-and-forget）。
    /// - Parameters:
    ///   - path: scrcpy 可执行文件路径
    ///   - args: 命令行参数（不含 scrcpy 本身）
    ///   - serial: 目标设备序列号，非 nil 时自动插入 `-s <serial>`
    ///   - adbPath: 当前使用的 adb 路径，用于把其所在目录加入 PATH（scrcpy 会调用 adb）
    ///   - stderrHandler: 异步接收 stderr 输出（每次读到一段就回调，任意线程）
    ///   - terminationHandler: 进程退出后的回调（任意线程），参数为 (exitCode)
    /// - Returns: LaunchResult
    @discardableResult
    public static func launch(
        path: String,
        args: [String],
        serial: String? = nil,
        adbPath: String? = nil,
        stderrHandler: (@Sendable (String) -> Void)? = nil,
        terminationHandler: (@Sendable (Int32) -> Void)? = nil
    ) -> LaunchResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        var finalArgs: [String] = []
        if let s = serial, !s.isEmpty {
            finalArgs.append(contentsOf: ["-s", s])
        }
        finalArgs.append(contentsOf: args)
        process.arguments = finalArgs

        // —— 关键：注入 PATH，让 scrcpy 能找到 adb ——
        // GUI app 启动的子进程默认 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
        // 不含 Homebrew，导致 scrcpy 找不到 adb 立刻退出（用户看到"点击没反应"）。
        var env = ProcessInfo.processInfo.environment
        var pathParts: [String] = []
        if let adbPath, !adbPath.isEmpty {
            let adbDir = (adbPath as NSString).deletingLastPathComponent
            if !adbDir.isEmpty { pathParts.append(adbDir) }
        }
        // scrcpy 自身所在目录也加入
        let scrcpyDir = (path as NSString).deletingLastPathComponent
        if !scrcpyDir.isEmpty { pathParts.append(scrcpyDir) }
        pathParts.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
        if let existing = env["PATH"], !existing.isEmpty {
            pathParts.append(existing)
        } else {
            pathParts.append("/usr/bin:/bin:/usr/sbin:/sbin")
        }
        env["PATH"] = pathParts.joined(separator: ":")
        process.environment = env

        // stdout 丢弃；stderr 捕获用于诊断
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe

        // 异步读 stderr（避免子进程写满 pipe 阻塞）
        if let stderrHandler {
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    stderrHandler(text)
                }
            }
        } else {
            // 不需要处理时也要读掉，避免 pipe 满
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
        }

        process.terminationHandler = { proc in
            // 停止读 pipe
            errPipe.fileHandleForReading.readabilityHandler = nil
            terminationHandler?(proc.terminationStatus)
        }

        let command = "\(path) \(finalArgs.joined(separator: " "))"

        do {
            try process.run()
            return LaunchResult(process: process, launchError: nil, command: command)
        } catch {
            return LaunchResult(process: nil, launchError: "\(error)", command: command)
        }
    }

    // MARK: - Private

    private static func whichScrcpy() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 用 login shell 读 PATH（source 用户 shell 配置），提高 which 命中率
        process.arguments = ["-lc", "command -v scrcpy 2>/dev/null || which scrcpy 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
