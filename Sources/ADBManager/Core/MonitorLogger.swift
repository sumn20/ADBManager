import Foundation

/// 心跳日志持久化：把 `Monitor` 的每条诊断事件追加到本地磁盘。
///
/// 设计要点（作为常驻小工具）：
/// - **位置**：`~/Library/Application Support/ADBManager/logs/monitor-YYYYMMDD.log`（macOS 标准 App 数据目录）
/// - **滚动**：单文件超 `maxBytes` (2MB) 或跨天时切换新文件；最多保留 `maxFiles` (7) 个，超过按时间倒序清理
///   → 总上限约 14MB，足够回溯一周
/// - **异步串行**：写入放在专用 `DispatchQueue` 串行队列，不阻塞 `@MainActor`
/// - **崩溃安全**：每条 flush，进程崩溃也不会丢已写入的历史
///
/// 不使用 `os_log`：那套东西查看要开 Console.app，`os_log` 存到系统 unified log 里，用户不好导出。
/// 本地纯文本文件更适合"复制报告发工程师"的场景。
public final class MonitorLogger: @unchecked Sendable {
    /// 单文件大小上限（字节）。超过则滚动到新文件。
    public static let maxBytes: Int = 2 * 1024 * 1024
    /// 保留的日志文件个数上限。
    public static let maxFiles: Int = 7

    /// 全局共享实例（心跳日志唯一写入方）
    public static let shared = MonitorLogger()

    private let queue = DispatchQueue(label: "com.sumn.adbmanager.monitor-logger", qos: .utility)
    private let fm = FileManager.default
    /// 时间戳格式：`2026-07-14 09:12:34.567`（含毫秒，便于按耗时排查）
    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    /// 文件名日期后缀：`YYYYMMDD`（用于跨天滚动）
    private let dateSuffixFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    // MARK: - 公共 API

    /// 日志根目录：`~/Library/Application Support/ADBManager/logs/`
    public var logDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("ADBManager", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// 追加一条日志（异步、非阻塞）
    /// - Parameters:
    ///   - level: 级别（INFO/WARN/ERROR），用于视觉分层
    ///   - message: 消息正文（不带时间戳，方法内部会拼上完整时间戳）
    public func log(_ level: LogLevel, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        queue.async { [weak self] in
            self?.writeAppending(line)
        }
    }

    /// 列出所有日志文件（按时间倒序，最新在前）。给「打开日志目录 / 导出」用。
    public func listLogFiles() -> [URL] {
        (try? fm.contentsOfDirectory(at: logDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]))
            .flatMap { urls in
                urls.filter { $0.lastPathComponent.hasPrefix("monitor-") && $0.pathExtension == "log" }
                    .sorted { lhs, rhs in
                        let lt = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let rt = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return lt > rt
                    }
            } ?? []
    }

    /// 读取最近 `n` 行日志（跨文件按时间正序拼接）。供诊断 dialog 快速回看。
    public func readTail(lines n: Int) -> String {
        let files = listLogFiles()   // 新在前
        var collected: [String] = []
        for url in files {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let fileLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            collected.insert(contentsOf: fileLines, at: 0)
            if collected.count >= n { break }
        }
        return collected.suffix(n).joined(separator: "\n")
    }

    // MARK: - 内部实现

    private func writeAppending(_ line: String) {
        do {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            // 目录创建失败就放弃这条日志（不能因为日志把 App 弄崩）
            return
        }
        let target = currentFileURL()
        let data = Data(line.utf8)
        if fm.fileExists(atPath: target.path) {
            // 追加：用 FileHandle 避免整块重写
            if let handle = try? FileHandle(forWritingTo: target) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: target)
        }
        rollIfNeeded(target)
        pruneOldFiles()
    }

    /// 当前应写入的文件路径：`monitor-YYYYMMDD.log`（按 App 所在时区的日期）
    private func currentFileURL() -> URL {
        let name = "monitor-\(dateSuffixFormatter.string(from: Date())).log"
        return logDirectory.appendingPathComponent(name)
    }

    /// 单文件超上限时滚动：把当前文件加序号后缀改名腾出新文件
    private func rollIfNeeded(_ url: URL) {
        guard let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > MonitorLogger.maxBytes else { return }
        // 找到未占用的序号：monitor-YYYYMMDD.log → monitor-YYYYMMDD.1.log / .2.log ...
        let dir = url.deletingLastPathComponent()
        let stem = (url.lastPathComponent as NSString).deletingPathExtension  // monitor-YYYYMMDD
        for i in 1...99 {
            let candidate = dir.appendingPathComponent("\(stem).\(i).log")
            if !fm.fileExists(atPath: candidate.path) {
                try? fm.moveItem(at: url, to: candidate)
                return
            }
        }
    }

    /// 只保留最新的 `maxFiles` 个文件；其余按修改时间从旧到新删除
    private func pruneOldFiles() {
        let files = listLogFiles()  // 新在前
        guard files.count > MonitorLogger.maxFiles else { return }
        for url in files.suffix(from: MonitorLogger.maxFiles) {
            try? fm.removeItem(at: url)
        }
    }
}

/// 日志级别（对齐常见约定）
public enum LogLevel: String, Sendable {
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}
