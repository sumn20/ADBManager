# ADB 管理器（macOS 原生）

基于 **Swift + SwiftUI** 的零依赖原生 macOS 工具，用于管理 adb（Android Debug Bridge）。
以**菜单栏（Menu Bar）常驻**方式运行，专为「adb 经常挂掉」的场景设计：后台心跳监测 + 无条件自动重启 + TCP 设备自动重连，并内置常用命令面板、TRTC 日志下载、当前 Activity 查看等能力。

## 功能

- **后台心跳 + 无条件自动重启**：后台定时探测（`adb devices -l`），发现 adb 无响应 / 挂掉时自动重启（`kill-server` → 探测 → 必要时 `pkill` → `start-server`），并自动重连之前通过 TCP 连过的设备。无开关、始终开启，是工具的立身之本。
  - **AIMD 自适应稳态间隔**：稳态每次成功后间隔 +base 缓慢放宽（封顶 30s），adb 稳定时探测频率降到约 1/3；失败立刻回 base 收紧灵敏度；用户操作 adb 命令失败会自动 poke 心跳立刻复核，稳态延迟只发生在完全空闲期。
- **TCP 设备自动重连**：保存的 TCP 地址（`savedTcp`）在每次重启后并发重连（最坏 8s，而非逐台串行）。
- **TRTC 日志下载**：选中设备 → 搜索 / 勾选第三方应用包名 → 一键拉取 `/sdcard/Android/data/<pkg>/files/log/liteav/` 到本地 `~/Downloads/ADBManager/<pkg>_liteav_<时间戳>`。
- **当前 Activity 查看**：常用命令面板内「获取当前 Activity」，解析 `adb shell dumpsys window` 的 `mCurrentFocus`，展示 `包名/Activity`。
- **常用命令面板**：截图、安装 / 卸载 APK、推送 / 拉取文件、logcat、重启手机、进 recovery / bootloader、查看设备信息（`getprop`）、列出已装应用、清理应用数据、录屏、获取当前 Activity。
- **设备连接管理**：列出设备、通过 TCP/IP 连接手机（`adb connect ip:port`）、断开。
- **自定义命令**：任意 adb 命令 + 参数，等宽字体终端风格输出。
- **应用状态诊断**：工具栏「状态」按钮弹出诊断 dialog，展示 adb 路径 / 版本、心跳状态、设备与连接情况、实时心跳日志；支持「复制报告」「立即重启 adb」「打开日志目录」。

## 构建与运行

要求：**macOS 14+、Swift 6（Xcode 16+）**。

```bash
cd adb-manager

# 编译 release（受限环境下 SwiftPM 的 sandbox 会拦截文件 / 进程操作，必须加 --disable-sandbox）
swift build -c release --disable-sandbox

# 跑单测
swift test --disable-sandbox

# 一键打包成可双击运行的 ADBManager.app
bash build.sh
```

`build.sh` 会在当前目录生成 `ADBManager.app`，双击即可启动（菜单栏出现图标）。

> 重新生成应用图标：修改 `gen_icon.py` 后执行 `python3 gen_icon.py`（依赖 Pillow + macOS `iconutil`），再 `bash build.sh`。

## 使用说明

- **首次启动自动探测 adb 路径**，依次检查：`which adb` → `/opt/local/bin/adb` → `/usr/local/bin/adb` → `/opt/homebrew/bin/adb` → `$ANDROID_HOME/platform-tools/adb` → `~/Library/Android/sdk/platform-tools/adb`。
- **状态指示**：菜单栏 / 工具栏状态点为四色——可用（绿）/ 重启中（橙）/ 不可用（红）/ 检测中（灰）。
- **工具窗口**：左侧为设备列表与 TCP 连接表单；右侧上半为命令面板、下半为终端输出（上下比例可在窗口内拖拽调整）。截图以弹窗预览，可保存为 PNG。
- **自动重启始终开启**（无开关）。若 adb 路径被指向错误位置，退出 App 后用以下命令重置为自动探测，再重启 App：

  ```bash
  defaults delete com.example.adbmanager adbPathOverride
  ```

- **应用状态诊断**：点击工具栏「状态」按钮，可查看 adb 路径 / 版本、心跳运行情况（间隔、最近检测、最近重启次数、可见设备数）、实时心跳日志，并支持「立即重启 adb」与「打开日志目录」（日志持久化在 `~/Library/Application Support/ADBManager/logs/`）。

## 说明

- 录屏命令默认录制约 60 秒（由超时控制），到点后自动停止，生成 `/sdcard/rec.mp4`。
- 所有 adb 调用均通过 `AdbRunner` 真实执行（`Process` + `Pipe`，并发读空输出避免大输出死锁），无假数据。
- 作为常驻小工具，内存占用有严格控制（实测前台运行时物理内存约 70MB、CPU 接近 0%），输出与日志均有环形截断上限。

## 目录结构

```
adb-manager/
├── Package.swift              # SwiftPM 配置（零第三方依赖）
├── build.sh                   # 打包 ADBManager.app
├── gen_icon.py                # 生成 ADBManager.icns
├── Sources/ADBManager/
│   ├── ADBManagerApp.swift    # @main 入口 + MenuBarExtra
│   ├── Core/                  # AdbRunner / AppModel / Monitor / Commands / 解析层 / Settings 等
│   ├── Models/Device.swift
│   └── Views/                 # ContentView / CommandView / DeviceView / TerminalView / DiagnosticsView / TrtcLogCard 等
└── Tests/ADBManagerTests/     # 解析层与心跳机制的单元测试
```
