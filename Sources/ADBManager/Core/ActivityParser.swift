import Foundation

/// 当前前台 Activity 的解析结果。
public enum ActivityResult: Equatable {
    /// 成功解析到前台 Activity（带包名与完整 Activity 名）
    case activity(package: String, activity: String)
    /// 无前台 Activity / 未连接设备 / 解析失败（含指向 Service）
    case none
}

/// 解析 `adb shell dumpsys window` 输出，提取当前前台 Activity。
public enum ActivityParser {
    /// 匹配 mCurrentFocus 行中的 `pkg/act`：
    /// 形如 `mCurrentFocus=Window{... com.example/.MainActivity}` 或全名形式。
    private static let regex: NSRegularExpression? = {
        // `…` 用 [^}]* 表示 Window{...} 内部任意内容；`\s` 匹配 pkg/act 前的空白；
        // 捕获组 (\S+?/\S+?) 非贪婪取 pkg/act，其后紧跟 `}`。
        try? NSRegularExpression(pattern: #"mCurrentFocus=Window\{[^}]*\s(\S+?/\S+?)\}"#)
    }()

    /// 从 dumpsys window 输出解析当前前台 Activity。
    /// - Parameter dumpsys: `dumpsys window` 的标准输出
    /// - Returns: 解析结果；无匹配 / null / 指向 Service → `.none`
    public static func parse(_ dumpsys: String) -> ActivityResult {
        guard let regex = regex else { return .none }

        let range = NSRange(dumpsys.startIndex..., in: dumpsys)
        guard let match = regex.firstMatch(in: dumpsys, range: range),
              let fullRange = Range(match.range(at: 1), in: dumpsys) else {
            return .none
        }

        let full = String(dumpsys[fullRange])  // 形如 `pkg/act` 或 `pkg/.Activity`
        let components = full.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return .none }

        let package = components[0]
        var activity = components[1]

        // act 以 `.` 开头则补全为 `pkg + act`
        if activity.hasPrefix(".") {
            activity = package + activity
        }

        // 若指向 Service（如系统导航栏服务），视为无有效前台 Activity
        if activity.lowercased().contains("service") {
            return .none
        }

        guard !package.isEmpty, !activity.isEmpty else { return .none }
        return .activity(package: package, activity: activity)
    }
}
