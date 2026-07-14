import Foundation

/// 内置 adb 命令枚举
public enum AdbCommand {
    case devices
    case connect(address: String)
    case disconnect(address: String?)
    case screenshot
    case install(apk: String)
    case uninstall(package: String)
    case push(from: String, to: String)
    case pull(from: String, to: String)
    case logcat
    case reboot
    case recovery
    case bootloader
    case getprop
    case packages
    case clear(package: String)
    case screenrecord(duration: TimeInterval)
    case version
    case killServer
    case startServer
    case custom(args: [String])
    case listPackages(thirdPartyOnly: Bool)
    case currentFocus
}

/// 命令参数构造器（纯函数，便于测试）
public enum CommandBuilder {
    /// 根据命令与可选 serial（-s）构造 adb 参数
    /// - Parameters:
    ///   - command: 要执行的命令
    ///   - serial: 选中设备的序列号；非空时在所有参数前插入 `-s <serial>`
    /// - Returns: 完整的 adb 参数数组
    public static func buildArgs(for command: AdbCommand, serial: String? = nil) -> [String] {
        let base: [String]
        switch command {
        case .devices:
            base = ["devices", "-l"]
        case .connect(let address):
            base = ["connect", address]
        case .disconnect(let address):
            base = address.map { ["disconnect", $0] } ?? ["disconnect"]
        case .screenshot:
            // 二进制 PNG 直接输出到 stdout
            base = ["exec-out", "screencap", "-p"]
        case .install(let apk):
            base = ["install", "-r", apk]
        case .uninstall(let package):
            base = ["uninstall", package]
        case .push(let from, let to):
            base = ["push", from, to]
        case .pull(let from, let to):
            base = ["pull", from, to]
        case .logcat:
            base = ["logcat", "-d", "-v", "time"]
        case .reboot:
            base = ["reboot"]
        case .recovery:
            base = ["reboot", "recovery"]
        case .bootloader:
            base = ["reboot", "bootloader"]
        case .getprop:
            base = ["shell", "getprop"]
        case .packages:
            base = ["shell", "pm", "list", "packages"]
        case .clear(let package):
            base = ["shell", "pm", "clear", package]
        case .screenrecord:
            base = ["shell", "screenrecord", "/sdcard/rec.mp4"]
        case .version:
            base = ["version"]
        case .killServer:
            base = ["kill-server"]
        case .startServer:
            base = ["start-server"]
        case .custom(let args):
            base = args
        case .listPackages(let thirdPartyOnly):
            base = thirdPartyOnly
                ? ["shell", "pm", "list", "packages", "-3"]
                : ["shell", "pm", "list", "packages"]
        case .currentFocus:
            base = ["shell", "dumpsys", "window"]
        }
        if let serial, !serial.isEmpty {
            return ["-s", serial] + base
        }
        return base
    }
}
