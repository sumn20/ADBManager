import SwiftUI

/// 设备列表 + TCP 连接表单 + 断开 + 刷新
struct DeviceView: View {
    @EnvironmentObject var model: AppModel
    @State private var tcpAddress: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // —— 设备列表卡片 ——
            VStack(alignment: .leading, spacing: 8) {
                Text("设备列表").font(.headline)
                List(selection: $model.selectedSerial) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 10) {
                            StateBadge(state: device.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.serial)
                                    .font(.system(.body, design: .monospaced))
                                if !device.detail.isEmpty {
                                    Text(device.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .tag(device.serial as String?)
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 150)
                .listStyle(.inset)
                // 让 List 背景透明，露出卡片背景，保持卡片化观感
                .scrollContentBackground(.hidden)
            }
            .card()

            HStack(spacing: 8) {
                Button("刷新") { Task { await model.refreshDevices() } }
                    .buttonStyle(.bordered)
                Button("断开选中") { Task { await model.disconnectSelected() } }
                    .buttonStyle(.bordered)
                    .disabled(model.selectedSerial == nil)
            }

            // —— TCP/IP 连接卡片 ——
            VStack(alignment: .leading, spacing: 10) {
                Text("通过 TCP/IP 连接").font(.headline)
                HStack(spacing: 8) {
                    TextField("IP:端口，如 192.168.1.5:5555", text: $tcpAddress)
                    Button("连接") {
                        Task { await model.connectTcp(tcpAddress) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !model.settings.savedTcp.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.settings.savedTcp, id: \.self) { addr in
                                HStack(spacing: 4) {
                                    Text(addr)
                                        .font(.system(.caption, design: .monospaced))
                                    Button {
                                        model.settings.removeTcp(addr)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
            }
            .card()

            Spacer()
        }
        .padding()
    }
}

/// 设备状态彩色徽章：device=绿 / offline=灰 / unauthorized=橙 / 其它=蓝
struct StateBadge: View {
    let state: String

    private var color: Color {
        switch state {
        case "device": return .green
        case "offline": return .gray
        case "unauthorized": return .orange
        default: return .blue
        }
    }

    var body: some View {
        Text(state)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }
}
