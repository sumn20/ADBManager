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

    /// 启动 scrcpy 进程（fire-and-forget），返回 Process 引用。
    /// - Parameters:
    ///   - path: scrcpy 可执行文件路径
    ///   - args: 命令行参数（不含 scrcpy 本身）
    ///   - serial: 目标设备序列号，非 nil 时自动插入 `-s <serial>`
    ///   - terminationHandler: 进程退出后的回调（在任意线程）
    /// - Returns: 启动成功返回 Process，失败返回 nil
    @discardableResult
    public static func launch(
        path: String,
        args: [String],
        serial: String? = nil,
        terminationHandler: (@Sendable (Process) -> Void)? = nil
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)

        var finalArgs: [String] = []
        if let s = serial, !s.isEmpty {
            finalArgs.append(contentsOf: ["-s", s])
        }
        finalArgs.append(contentsOf: args)
        process.arguments = finalArgs

        // scrcpy 自己管理窗口和输出，不需要捕获 stdout/stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        if let handler = terminationHandler {
            process.terminationHandler = handler
        }

        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private static func whichScrcpy() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "scrcpy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }
}
