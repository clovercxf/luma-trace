import SwiftUI
import AppKit

struct BrowserEntry: Identifiable, Sendable {
    var url: URL
    var name: String
    var directory: Bool
    var modified: Date?
    var id: String { url.path }
    var symbol: String { directory ? "folder.fill" : Analyzer.imageExtensions.contains(url.pathExtension.lowercased()) ? "photo" : Analyzer.videoExtensions.contains(url.pathExtension.lowercased()) ? "film" : "doc" }
}
@MainActor final class FolderBrowserModel: ObservableObject {
    @Published var location: URL
    @Published var pathText: String
    @Published var entries: [BrowserEntry] = []
    @Published var selection = Set<String>()
    @Published var hidden = false
    @Published var loading = false
    @Published var error: String?
    @Published private(set) var back: [URL] = []
    @Published private(set) var forward: [URL] = []
    private var revision = UUID()
    init(location: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.location = location; pathText = location.path
    }
    nonisolated static func resolve(_ text: String) -> URL? {
        let path = (text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    nonisolated static func list(_ location: URL, hidden: Bool) throws -> [BrowserEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: Array(keys), options: hidden ? [] : [.skipsHiddenFiles]).map { url in
            let values = try url.resourceValues(forKeys: keys)
            return BrowserEntry(url: url, name: FileManager.default.displayName(atPath: url.path), directory: values.isDirectory == true, modified: values.contentModificationDate)
        }.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    func go(_ url: URL, record: Bool = true) {
        let url = url.standardizedFileURL
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { error = tr("路径不存在或不是文件夹"); return }
        if record, url != location { back.append(location); forward = [] }
        location = url; pathText = url.path; selection = []; refresh()
    }
    func goPath() { guard let url = Self.resolve(pathText) else { error = tr("请输入以 / 或 ~/ 开头的完整路径"); return }; go(url) }
    func goBack() { guard let url = back.popLast() else { return }; forward.append(location); go(url, record: false) }
    func goForward() { guard let url = forward.popLast() else { return }; back.append(location); go(url, record: false) }
    func refresh() {
        let request = UUID(); revision = request; loading = true; error = nil; selection = []
        let location = location, hidden = hidden
        Task {
            let result = await Task.detached { Result { try Self.list(location, hidden: hidden) } }.value
            guard revision == request else { return }
            loading = false
            switch result {
            case .success(let entries): self.entries = entries
            case .failure(let error): self.entries = []; self.error = tr("无法读取此文件夹，请检查路径和系统访问权限。") + "\n" + error.localizedDescription
            }
        }
    }
    var chosen: [URL] { entries.filter { $0.directory && selection.contains($0.id) }.map(\.url) }
}
struct FolderBrowserView: View {
    @ObservedObject var store: LibraryStore
    var close: () -> Void
    @StateObject private var browser = FolderBrowserModel()
    @FocusState private var pathFocused: Bool
    private let home = FileManager.default.homeDirectoryForCurrentUser
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: browser.goBack) { Image(systemName: "chevron.left") }.disabled(browser.back.isEmpty).help(tr("后退"))
                Button(action: browser.goForward) { Image(systemName: "chevron.right") }.disabled(browser.forward.isEmpty).help(tr("前进"))
                Button { browser.go(browser.location.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }.disabled(browser.location.path == "/").help(tr("上一级"))
                TextField(tr("输入完整文件夹路径"), text: $browser.pathText).textFieldStyle(.roundedBorder).focused($pathFocused).onSubmit { browser.goPath() }
                Button(tr("前往"), action: browser.goPath)
                Button { pathFocused = true } label: { Image(systemName: "text.cursor") }.keyboardShortcut("l").help(tr("输入完整文件夹路径"))
            }.padding(12)
            Divider()
            HSplitView {
                List {
                    Section(tr("常用位置")) {
                        place(tr("个人文件夹"), home, "house")
                        place(tr("图片"), home.appendingPathComponent("Pictures"), "photo.on.rectangle")
                        place(tr("桌面"), home.appendingPathComponent("Desktop"), "menubar.dock.rectangle")
                        place(tr("文稿"), home.appendingPathComponent("Documents"), "doc")
                        place(tr("下载"), home.appendingPathComponent("Downloads"), "arrow.down.circle")
                        place(tr("影片"), home.appendingPathComponent("Movies"), "film")
                        place(tr("音乐"), home.appendingPathComponent("Music"), "music.note")
                    }
                    Section(tr("磁盘与位置")) {
                        place(tr("这台 Mac"), URL(fileURLWithPath: "/"), "desktopcomputer")
                        ForEach(FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [], id: \.path) { url in
                            place(FileManager.default.displayName(atPath: url.path), url, "externaldrive")
                        }
                    }
                    if !store.state.roots.isEmpty {
                        Section(tr("已添加的位置")) {
                            ForEach(store.state.roots, id: \.self) { root in place(URL(fileURLWithPath: root).lastPathComponent, URL(fileURLWithPath: root), "folder") }
                        }
                    }
                }.listStyle(.sidebar).frame(minWidth: 160, idealWidth: 185, maxWidth: 240)
                VStack(spacing: 0) {
                    if browser.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let error = browser.error {
                        ContentUnavailableView(tr("无法打开文件夹"), systemImage: "folder.badge.questionmark", description: Text(error))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(browser.entries, selection: $browser.selection) {
                            TableColumn(tr("名称")) { entry in Label(entry.name, systemImage: entry.symbol).foregroundStyle(entry.directory ? .primary : .secondary) }.width(min: 170, ideal: 290)
                            TableColumn(tr("类型")) { entry in Text(entry.directory ? tr("文件夹") : entry.url.pathExtension.uppercased()).foregroundStyle(.secondary) }.width(75)
                            TableColumn(tr("修改时间")) { entry in if let date = entry.modified { Text(localizedDate(date)).foregroundStyle(.secondary) } }.width(min: 100, ideal: 125)
                        }
                        .contextMenu(forSelectionType: String.self) { ids in
                            if let entry = browser.entries.first(where: { ids.contains($0.id) && $0.directory }) {
                                Button(tr("打开文件夹")) { browser.go(entry.url) }
                            }
                        } primaryAction: { ids in
                            if let entry = browser.entries.first(where: { ids.contains($0.id) && $0.directory }) { browser.go(entry.url) }
                        }
                    }
                }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(tr("显示隐藏文件"), isOn: $browser.hidden).toggleStyle(.checkbox).onChange(of: browser.hidden) { _, _ in browser.refresh() }
                    Spacer()
                    Text(tr("按住 ⌘ 可多选文件夹")).font(.caption).foregroundStyle(.secondary)
                }
                Text(browser.location.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                HStack {
                    Text(tr("扫描所选文件夹及其子文件夹")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("取消"), action: close).keyboardShortcut(.cancelAction)
                    Button(browser.chosen.isEmpty ? tr("添加当前文件夹") : tr("添加 \(browser.chosen.count) 个文件夹")) {
                        let panel = NSOpenPanel()
                        panel.title = tr("授予文件夹访问权限")
                        panel.message = tr("macOS 将仅向 LumaTrace 授予你选择的文件夹访问权限。")
                        panel.prompt = tr("授予访问")
                        panel.directoryURL = browser.location
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = true
                        panel.canCreateDirectories = false
                        panel.begin { response in
                            if response == .OK, !panel.urls.isEmpty { store.addRoots(panel.urls) }
                            close()
                        }
                    }.keyboardShortcut(.defaultAction).disabled(browser.loading || browser.error != nil || store.isReadOnly || (!browser.selection.isEmpty && browser.chosen.isEmpty))
                }
            }.padding(12)
        }.frame(minWidth: 700, minHeight: 460).onAppear { browser.refresh() }
            .environment(\.locale, Localization.language.locale)
    }
    private func place(_ name: String, _ url: URL, _ icon: String) -> some View {
        Button { browser.go(url) } label: { Label(name, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).help(url.path)
    }
}
