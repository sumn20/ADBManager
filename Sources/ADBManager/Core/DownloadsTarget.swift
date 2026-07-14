import Foundation

/// 下载目标路径与目录管理：把设备上的 liteav 日志拉取到本机 `~/Downloads/ADBManager` 下。
public struct DownloadsTarget {
    /// 根目录名（下载日志统一放在 `~/Downloads/ADBManager` 下）
    public static let rootFolderName: String = "ADBManager"

    /// 根据包名生成目标目录路径：`~/Downloads/ADBManager/<pkg>_liteav_<yyyyMMdd_HHmmss>`
    /// - Parameter package: 应用包名
    /// - Returns: 目标目录的完整路径字符串
    public static func buildDestinationPath(package: String) -> String {
        // 用 FileManager 取 Downloads 目录，避免硬编码 HOME
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let dirName = "\(package)_liteav_\(timestampString())"
        return downloads
            .appendingPathComponent(rootFolderName)
            .appendingPathComponent(dirName)
            .path
    }

    /// 创建包名对应的本地下载目录，返回目录 URL；失败返回 nil
    /// - Parameter package: 应用包名
    /// - Returns: 已创建的目录 URL，失败为 nil
    public static func createDir(package: String) -> URL? {
        let url = URL(fileURLWithPath: buildDestinationPath(package: package))
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
            return url
        } catch {
            return nil
        }
    }

    /// 递归统计目录下的文件数量（跳过以 `.` 开头的隐藏文件 / 目录）
    /// - Parameter directoryURL: 待统计的目录 URL
    /// - Returns: 该目录（含子目录）下普通文件的数量
    public static func countFiles(in directoryURL: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            // 兜底过滤隐藏文件（枚举已用 skipsHiddenFiles，这里再保险一次）
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            guard let resource = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resource.isRegularFile == true else {
                continue
            }
            count += 1
        }
        return count
    }

    /// 依据当前时间生成时间戳字符串（yyyyMMdd_HHmmss，en_US_POSIX 稳定格式）
    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
