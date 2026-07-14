import Foundation

/// TRTC 日志下载错误的分类。
public enum TrtcLogError: Equatable {
    /// 远程日志目录不存在（pull 报 no such file / does not exist 等）
    case noLogDirectory
    /// 权限不足，无法读取日志目录
    case permissionDenied
    /// 其他失败，携带截断后的错误信息
    case generic(message: String)
    /// 成功（无错误）
    case none

    /// 错误信息最大截断长度
    private static let maxMessageLength = 200

    /// 根据 adb 执行结果分类错误类型。
    /// - Parameter r: 一次 adb 执行结果
    /// - Returns: 对应的错误分类
    public static func classify(_ r: AdbResult) -> TrtcLogError {
        let combined = (r.stdout + r.stderr).lowercased()

        // 目录不存在
        if combined.contains("no such file")
            || combined.contains("does not exist")
            || combined.contains("no such file or directory") {
            return .noLogDirectory
        }

        // 权限不足（收紧为 "permission denied"，避免裸 "permission" 把正常输出误判为权限错误）
        if combined.contains("permission denied") {
            return .permissionDenied
        }

        // 执行成功
        if r.success {
            return .none
        }

        // 其他失败：携带截断后的错误信息
        let raw = r.stderr.isEmpty ? r.stdout : r.stderr
        let message = String(raw.prefix(Self.maxMessageLength))
        return .generic(message: message)
    }
}
