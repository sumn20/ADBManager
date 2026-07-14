import Foundation

/// 已连接设备模型
public struct Device: Identifiable, Hashable {
    /// 设备序列号（USB 序列号或 TCP 地址），同时作为唯一标识
    public var id: String { serial }

    /// 序列号
    public let serial: String
    /// 状态：device / offline / unauthorized 等
    public let state: String
    /// 附带的详细信息（model:.. transport:.. 等）
    public let detail: String

    public init(serial: String, state: String, detail: String = "") {
        self.serial = serial
        self.state = state
        self.detail = detail
    }

    /// 解析 `adb devices -l` 的标准输出
    /// - Parameter output: 命令输出文本
    /// - Returns: 解析出的设备数组（跳过表头与空行）
    public static func parse(_ output: String) -> [Device] {
        var devices: [Device] = []
        let lines = output.components(separatedBy: .newlines)
        // 第一行是 "List of devices attached" 表头，从第二行开始解析
        guard lines.count > 1 else { return devices }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // 形如：serial<TAB或空格>state model:.. transport:..
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let serial = parts[0]
            let state = parts[1]
            let detail = parts.dropFirst(2).joined(separator: " ")
            devices.append(Device(serial: serial, state: state, detail: detail))
        }
        return devices
    }
}
