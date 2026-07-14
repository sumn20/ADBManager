import SwiftUI

/// TRTC 日志下载卡片：列出已安装包、支持把 liteav 日志拉取到本机 Downloads。
struct TrtcLogCard: View {
    @EnvironmentObject var model: AppModel

    @State private var thirdPartyOnly: Bool = true
    @State private var searchText: String = ""

    /// 本地过滤后的包名列表（大小写不敏感子串匹配）
    private var filteredPackages: [String] {
        let list = model.packageList
        guard !searchText.isEmpty else { return list }
        let query = searchText.lowercased()
        return list.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            toggles
            refreshRow
            packageListSection
            selectedRow
            actionRow
            statusRow
        }
        .card()
        .onAppear {
            Task { await model.loadPackages(thirdPartyOnly: thirdPartyOnly) }
        }
    }

    private var header: some View {
        Label("TRTC 日志下载", systemImage: "square.and.arrow.down")
            .font(.headline)
    }

    private var toggles: some View {
        Toggle("仅第三方应用(-3)", isOn: $thirdPartyOnly)
    }

    private var refreshRow: some View {
        HStack(spacing: 8) {
            TextField("搜索包名", text: $searchText)
            Button("刷新") {
                Task { await model.loadPackages(thirdPartyOnly: thirdPartyOnly) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
        }
    }

    private var packageListSection: some View {
        ScrollView {
            packageRows
        }
        .frame(maxHeight: 200)
    }

    private var packageRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if filteredPackages.isEmpty {
                Text("暂无包（点「刷新」拉取）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredPackages, id: \.self) { pkg in
                    packageRow(pkg)
                }
            }
        }
    }

    private func packageRow(_ pkg: String) -> some View {
        let selected = model.selectedPackage == pkg
        return Button {
            model.selectedPackage = pkg
        } label: {
            HStack {
                Text(pkg)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedRow: some View {
        HStack(spacing: 6) {
            Text("已选：\(model.selectedPackage ?? "—")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("下载 liteav 日志") {
                if let pkg = model.selectedPackage {
                    Task { await model.downloadTrtcLogs(for: pkg) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.selectedPackage == nil || model.selectedSerial == nil)

            if let path = model.lastDownloadPath {
                Button("在 Finder 中打开") {
                    model.revealInFinder(path)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if !model.downloadStatus.isEmpty {
            Text(model.downloadStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
