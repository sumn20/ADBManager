import Foundation

/// 解析 `adb shell pm list packages` 输出，提取纯包名列表。
///
/// 处理规则：
/// 1. 逐行剥离开头的 `package:` 前缀；
/// 2. 去除空行与首尾空白；
/// 3. 没有 `package:` 前缀的垃圾行（如表头/无关输出）直接跳过；
/// 4. 去重并保持首次出现顺序。
public enum PackageParser {
    /// 从命令输出中解析出包名数组。
    /// - Parameter stdout: `pm list packages` 的标准输出
    /// - Returns: 纯包名字符串数组（已去重、去空、去垃圾行）
    public static func parse(_ stdout: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // 跳过空行
            guard !line.isEmpty else { continue }

            let pkg: String
            if line.hasPrefix("package:") {
                // 剥离 `package:` 前缀并再次去空白
                pkg = String(line.dropFirst("package:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // 没有 `package:` 前缀 → 视为垃圾行，跳过
                continue
            }
            guard !pkg.isEmpty else { continue }

            if !seen.contains(pkg) {
                seen.insert(pkg)
                result.append(pkg)
            }
        }
        return result
    }
}
