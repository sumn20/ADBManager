import Foundation
import Combine

/// 用户设置（持久化到 UserDefaults）
public final class Settings: ObservableObject {
    /// 手动覆盖的 adb 路径（为空则自动探测）
    @Published public var adbPathOverride: String {
        didSet { UserDefaults.standard.set(adbPathOverride, forKey: "adbPathOverride") }
    }
    /// 监测间隔（秒，基础心跳间隔；连续失败时会指数退避放大）
    @Published public var interval: Int {
        didSet {
            let clamped = min(3600, max(1, interval))
            UserDefaults.standard.set(clamped, forKey: "interval")
            if clamped != interval { interval = clamped }
        }
    }
    /// 已保存的 TCP 设备地址（ip:port），用于自动重连
    @Published public var savedTcp: [String] {
        didSet { UserDefaults.standard.set(savedTcp, forKey: "savedTcp") }
    }

    public init() {
        let ud = UserDefaults.standard
        self.adbPathOverride = ud.string(forKey: "adbPathOverride") ?? ""
        let i = ud.integer(forKey: "interval")
        self.interval = i <= 0 ? 10 : i
        self.savedTcp = ud.stringArray(forKey: "savedTcp") ?? []
    }

    /// 解析最终使用的 adb 路径（override 优先，否则自动探测）
    public func resolvedAdbPath() -> String? {
        return AdbRunner.detectAdbPath(override: adbPathOverride.isEmpty ? nil : adbPathOverride)
    }

    /// 新增一个 TCP 地址（去重、去空）
    public func addTcp(_ address: String) {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, !savedTcp.contains(a) else { return }
        savedTcp.append(a)
    }

    /// 移除一个 TCP 地址
    public func removeTcp(_ address: String) {
        savedTcp.removeAll { $0 == address }
    }
}
