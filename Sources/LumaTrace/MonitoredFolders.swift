import SwiftUI
import AppKit

struct WatchedFolder: Identifiable {
    var path: String
    var indexed: Int
    var photos: Int
    var videos: Int
    var status: String
    var statusSymbol: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct MonitoredFoldersView: View {
    @ObservedObject var store: LibraryStore
    var query = ""
    @StoredState private var selected = Set<String>()
    private var folders: [WatchedFolder] {
        store.state.roots.map { root in
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let media = store.state.items.filter { $0.path.hasPrefix(prefix) }
            var isDirectory: ObjCBool = false
            let available = FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue
            let hasWarning = store.scanWarnings.contains { $0.contains(root) }
            let isScanning = store.busy && (store.scanLocation == root || store.scanLocation.hasPrefix(prefix))
            let status = !available ? "文件夹不可用" : hasWarning ? "需要检查" : isScanning ? "正在扫描" : "已连接"
            let symbol = !available ? "externaldrive.badge.xmark" : hasWarning ? "exclamationmark.triangle.fill" : isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
            return WatchedFolder(path: root, indexed: media.count, photos: media.filter { !$0.isVideo }.count, videos: media.filter(\.isVideo).count, status: status, statusSymbol: symbol)
        }.filter { query.isEmpty || $0.path.localizedStandardContains(query) }
    }
    private var visibleSelection: Set<String> { selected.intersection(Set(folders.map(\.id))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr("已配置 \(store.state.roots.count) 个扫描位置")).foregroundStyle(.secondary)
                Spacer()
                Button { store.refreshFolders(store.state.roots) } label: { Label(tr("刷新全部"), systemImage: "arrow.clockwise") }
                    .help(tr("刷新所有监测文件夹的影像和连接状态"))
                    .disabled(store.isReadOnly || store.state.roots.isEmpty)
                Button(action: store.addRoot) { Label(tr("添加文件夹"), systemImage: "plus") }.disabled(store.isReadOnly)
                Button { store.removeRoots(visibleSelection); selected = [] } label: { Label(tr("移除所选"), systemImage: "minus") }.disabled(visibleSelection.isEmpty || store.isReadOnly)
            }
            if store.state.roots.isEmpty {
                ContentUnavailableView {
                    Label(tr("尚未添加监测文件夹"), systemImage: "folder.badge.plus")
                } description: {
                    Text(tr("添加一个或多个文件夹后，会自动监测其中新增或修改的照片和视频。"))
                } actions: {
                    Button(tr("添加文件夹"), action: store.addRoot).disabled(store.isReadOnly).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if folders.isEmpty {
                ContentUnavailableView(tr("没有匹配的文件夹"), systemImage: "magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(folders, selection: $selected) {
                    TableColumn(tr("名称")) { folder in Label(folder.name, systemImage: "folder").help(folder.path) }.width(min: 120, ideal: 180)
                    TableColumn(tr("完整路径")) { folder in Text(folder.path).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(folder.path) }.width(min: 200, ideal: 400)
                    TableColumn(tr("照片")) { folder in Text(folder.photos, format: .number).monospacedDigit() }.width(70)
                    TableColumn(tr("视频")) { folder in Text(folder.videos, format: .number).monospacedDigit() }.width(70)
                    TableColumn(tr("连接状态")) { folder in
                        let statusColor: Color = folder.status == "已连接" ? .green : folder.status == "正在扫描" ? Color(red: 0.14, green: 0.42, blue: 0.99) : .orange
                        Label {
                            Text(tr(folder.status))
                        } icon: {
                            Image(systemName: folder.statusSymbol)
                        }
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                    }.width(min: 100, ideal: 130)
                    TableColumn(tr("刷新")) { folder in
                        Button { store.refreshFolders([folder.path]) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help(tr("刷新此文件夹"))
                            .accessibilityLabel(tr("刷新") + " " + folder.name).disabled(store.isReadOnly)
                    }.width(42)
                    TableColumn("") { folder in
                        Button { store.removeRoot(folder.path); selected.remove(folder.path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(tr("移除")).accessibilityLabel(tr("移除") + " " + folder.name).disabled(store.isReadOnly)
                    }.width(35)
                }
            }
            Text(tr("移除后保留原文件和已收录记录。")).font(.caption).foregroundStyle(.secondary)
            if store.configurationPending { Text(tr("正在应用设置，保留已完成结果…")).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: store.state.roots) { _, roots in selected.formIntersection(Set(roots)) }
    }
}
