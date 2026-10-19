import SwiftUI
import AppKit
import AVFoundation
import MapKit

// Explicit wrapper alias supports SDKs that also export a State macro.
typealias StoredState<Value> = SwiftUI.State<Value>

private let accent = Color(red: 0.14, green: 0.42, blue: 0.99)
private let paper = Color(nsColor: .controlBackgroundColor)

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage("timeimprint.language") private var language = AppLanguage.systemDefault.rawValue
    @AppStorage("timeimprint.thumbnailSize") private var thumbnailSize = 180.0
    @AppStorage("timeimprint.oldestFirst") private var oldestFirst = false
    @StoredState private var camera = false
    @StoredState private var newTask = false
    @StoredState private var inspector = false
    @StoredState private var folderQuery = ""
    @StoredState private var locationEditor = false
    @StoredState private var selectionMode = false
    @FocusState private var gridFocused: Bool
    private var route: Binding<String?> {
        Binding(get: { store.selection }, set: { if let key = $0 { store.selectSection(key) } })
    }
    var body: some View {
        NavigationSplitView {
            List(selection: route) {
                Section(tr("资料库")) {
                    nav("all", tr("所有影像"), "photo.on.rectangle", count: store.displayItems.count)
                    nav("memories", tr("时光穿梭"), "clock.arrow.circlepath", count: store.state.memories.count)
                    nav("places", tr("地点"), "map")
                }
                Section(tr("媒体类型")) {
                    nav("images", tr("照片"), "photo", count: store.displayItems.filter { !$0.isVideo }.count)
                    nav("videos", tr("视频"), "film", count: store.displayItems.filter(\.isVideo).count)
                    nav("motion", tr("动态照片"), "livephoto", count: store.displayItems.filter(\.isMotion).count)
                }
                Section(tr("实用工具")) {
                    nav("duplicates", tr("重复与优选"), "square.on.square", count: store.duplicates.count)
                    nav("errors", tr("待重试的文件"), "exclamationmark.triangle", count: store.state.items.filter { $0.error != nil }.count)
                }
                Section(tr("管理")) {
                    nav("folders", tr("监测文件夹"), "folder.badge.gearshape", count: store.state.roots.count)
                }
                Section(tr("任务相册")) {
                    ForEach(store.state.rules) { rule in nav("task:" + rule.name, rule.name, "folder") }
                    Button { newTask = true } label: { Label(tr("创建任务相册"), systemImage: "plus") }.disabled(store.isReadOnly)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(tr("LumaTrace"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) {
                AnalysisControls(store: store)
            }
        } detail: {
            VStack(spacing: 0) {
                if store.isReadOnly {
                    HStack {
                        Label(tr("只读浏览，仍可切换页面和搜索"), systemImage: "info.circle").font(.callout)
                        Spacer()
                        Button(tr("重试连接")) { store.retryLibraryAccess() }
                    }.padding(12).background(.bar).help(tr(store.accessMessage ?? ""))
                }
                if store.selection == "folders" { MonitoredFoldersView(store: store, query: folderQuery) }
                else if store.selection == "memories" { MemoriesView(store: store) }
                else if store.selection == "places" { PhotoMapView(store: store) }
                else if store.selection == "duplicates" { DuplicateView(store: store) }
                else if store.selection == "errors" { RetryCenterView(store: store) }
                else if store.displayItems.isEmpty { emptyState }
                else { libraryGrid }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(title)
            .navigationSubtitle(store.selection == "folders" ? tr("已配置 \(store.state.roots.count) 个扫描位置") : store.selection == "places" ? tr("在地图上浏览带定位的影像") : tr("\(store.visible.count) 项"))
            .searchable(text: Binding(get: { store.selection == "folders" ? folderQuery : store.query }, set: { if store.selection == "folders" { folderQuery = $0 } else { store.query = $0 } }), placement: .toolbar, prompt: Text(store.selection == "folders" ? tr("搜索文件夹名称或路径") : tr("搜索照片、视频和文字")))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if showsLibrary {
                        if selectionMode {
                            Button { locationEditor = true } label: { Label(tr("为所选影像添加位置"), systemImage: "mappin.and.ellipse") }
                                .disabled(store.selectedIDs.isEmpty)
                            Button(tr("完成选择")) { selectionMode = false; store.selectedIDs = [] }
                        } else {
                            Button { selectionMode = true; store.selectedIDs = Set(store.selectedID.map { [$0] } ?? []) } label: { Label(tr("选择多项"), systemImage: "checkmark.circle") }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $thumbnailSize, in: 110...280).frame(width: 90).accessibilityLabel(tr("缩略图大小"))
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }.help(tr("缩略图大小"))
                        Menu {
                            Picker(tr("排序"), selection: $oldestFirst) {
                                Text(tr("最新优先")).tag(false)
                                Text(tr("最早优先")).tag(true)
                            }
                        } label: { Label(tr("排序"), systemImage: "arrow.up.arrow.down") }.help(tr("排序"))
                    }
                    Button { store.addRoot() } label: { Label(tr("添加目录"), systemImage: "folder.badge.plus") }.disabled(store.isReadOnly).help(tr("添加监测文件夹…"))
                    Menu {
                        Button(tr("拍摄动态照片"), systemImage: "camera") { camera = true }.disabled(store.isReadOnly)
                        Button(tr("创建任务相册"), systemImage: "folder.badge.plus") { newTask = true }.disabled(store.isReadOnly)
                        Divider()
                        Button(tr("立即扫描"), systemImage: "arrow.clockwise") { store.scan() }.disabled(store.busy || store.isReadOnly)
                        SettingsLink { Text(tr("设置…")) }
                    } label: { Label(tr("更多"), systemImage: "ellipsis.circle") }.help(tr("更多"))
                    Button { inspector.toggle() } label: { Label(tr("影像详情"), systemImage: "info.circle") }.keyboardShortcut("i").help(tr("影像详情"))
                }
            }
            .inspector(isPresented: $inspector) {
                Group {
                    if let item = store.selected { DetailView(store: store, item: item) { inspector = false; store.selectedID = nil }.id(item.id) }
                    else { ContentUnavailableView(tr("未选择影像"), systemImage: "info.circle", description: Text(tr("选择照片或视频以查看详情。"))).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.inspectorColumnWidth(min: 280, ideal: 310, max: 400)
            }
            .safeAreaInset(edge: .bottom) {
                if showsLibrary {
                    HStack(spacing: 8) {
                        Spacer()
                        if store.searching { ProgressView().controlSize(.mini) }
                        Text(tr("\(store.visible.count) 项")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(8).background(.bar)
                }
            }
        }
        .tint(accent)
        .sheet(isPresented: $camera) { CameraSheet(store: store) }
        .sheet(isPresented: $newTask) { TaskSheet(store: store) }
        .onChange(of: store.selection) { _, value in MediaBrowserWindowController.shared.closeWindow(); if value == "folders" { inspector = false } }
        .alert(tr("需要留意"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button(tr("知道了")) { store.errorMessage = nil } } message: { Text(tr(store.errorMessage ?? "")) }
    }
    private var showsLibrary: Bool { store.selection != "memories" && store.selection != "duplicates" && store.selection != "folders" }
    private func openPreview(_ item: MediaItem) {
        let groups = oldestFirst ? Array(store.sections.reversed()) : store.sections
        let ordered = groups.flatMap { oldestFirst ? Array($0.1.reversed()) : $0.1 }
        MediaBrowserWindowController.shared.show(store: store, request: item, items: ordered)
    }
    private var title: String {
        if store.selection.hasPrefix("task:") { return String(store.selection.dropFirst(5)) }
        return ["folders": tr("监测文件夹"), "all": tr("所有影像"), "images": tr("照片"), "videos": tr("视频"), "motion": tr("动态照片"), "places": tr("地点"), "duplicates": tr("重复与优选"), "memories": tr("时光穿梭"), "errors": tr("待重试的文件")][store.selection] ?? tr("资料库")
    }
    private func nav(_ key: String, _ label: String, _ icon: String, count: Int? = nil) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            if let count, count > 0 { Text(count, format: .number).font(.caption).foregroundStyle(.secondary) }
        }.tag(key).accessibilityIdentifier("sidebar.\(key)")
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label(tr("开始整理你的照片"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(tr("添加本地文件夹，自动整理照片和视频，使用自然语言查找回忆。"))
        } actions: {
            Button(tr("选择照片或视频文件夹"), action: store.addRoot).buttonStyle(.borderedProminent).disabled(store.isReadOnly)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func moveSelection(_ step: Int) -> KeyPress.Result {
        let sections = oldestFirst ? store.sections.reversed().map { $0 } : store.sections
        let items = sections.flatMap { oldestFirst ? $0.1.reversed().map { $0 } : $0.1 }
        guard !items.isEmpty else { return .ignored }
        let current = items.firstIndex { $0.id == store.selectedID }
        let next = current.map { min(max($0 + step, 0), items.count - 1) } ?? (step > 0 ? 0 : items.count - 1)
        store.selectedID = items[next].id
        return .handled
    }
    @ViewBuilder private var libraryGrid: some View {
        if store.visible.isEmpty {
            ContentUnavailableView(tr("没有找到相关影像"), systemImage: "magnifyingglass", description: Text(tr("尝试更简短的场景词、图片中的文字，或清空搜索。")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(oldestFirst ? store.sections.reversed().map { $0 } : store.sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.0).font(.title3.weight(.semibold)).padding(.horizontal, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 4)], spacing: 4) {
                            ForEach(oldestFirst ? section.1.reversed().map { $0 } : section.1) { item in
                                MediaCard(item: item, selected: store.selectedID == item.id, selectionMode: selectionMode, selectedForBatch: store.selectedIDs.contains(item.id), compact: true, open: { openPreview(item) }) {
                                    store.selectedID = item.id; gridFocused = true
                                    if selectionMode {
                                        if store.selectedIDs.contains(item.id) { store.selectedIDs.remove(item.id) } else { store.selectedIDs.insert(item.id) }
                                    }
                                }
                                    .overlay(alignment: .topTrailing) {
                                        if store.previewItems[item.id] != nil { Text(tr("正在分析")).font(.caption2).padding(5).background(.regularMaterial, in: Capsule()).padding(5).allowsHitTesting(false) }
                                    }
                                    .contextMenu {
                                        Button(tr("打开预览")) { openPreview(item) }
                                        Button(tr("影像详情")) { store.selectedID = item.id; inspector = true }
                                        Divider()
                                        Button(tr("在访达中显示")) { store.reveal(item) }
                                    }
                            }
                        }
                    }
                }
            }.padding(16)
        }
        .focusable()
        .focused($gridFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) { moveSelection(1) }
        .onKeyPress(.space) { if let item = store.selected { openPreview(item); return .handled }; return .ignored }
        .onKeyPress(.return) { if let item = store.selected { openPreview(item); return .handled }; return .ignored }
            .sheet(isPresented: $locationEditor) { BulkLocationSheet(store: store).frame(minWidth: 420, minHeight: 280) }
        }
    }
}

struct RetryCenterView: View {
    @ObservedObject var store: LibraryStore
    private var failedItems: [MediaItem] { store.state.items.filter { $0.error != nil }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("待重试的文件和文件夹")).font(.title2.bold())
                        Text(tr("分析失败的影像和扫描受阻的位置会列在这里，可单独重试。" )).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.retryFailedItems() } label: {
                        Label(tr(store.retryQueued ? "已排队，扫描后重试" : store.busy ? "当前扫描后重试" : "重试全部失败项"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent).disabled(store.isReadOnly || store.retryQueued || (failedItems.isEmpty && store.scanWarnings.isEmpty))
                }

                if !store.scanWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("文件夹扫描提醒")).font(.headline)
                        ForEach(Array(store.scanWarnings.enumerated()), id: \.offset) { _, warning in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "folder.badge.exclamationmark").foregroundStyle(.orange)
                                Text(tr(warning)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if let path = retryPath(for: warning) {
                                    Button(tr("重试此位置")) { store.retryFolder(path) }.disabled(store.isReadOnly)
                                }
                            }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                if !failedItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("影像分析失败")).font(.headline)
                        LazyVStack(spacing: 8) {
                            ForEach(failedItems) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: item.isVideo ? "film" : "photo").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                                        Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                        Text(tr(item.error ?? "")).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                                    }
                                    Spacer(minLength: 8)
                                    Button(tr("重试此文件夹")) { store.retryFolder(URL(fileURLWithPath: item.path).deletingLastPathComponent().path) }
                                        .disabled(store.isReadOnly)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }

                if failedItems.isEmpty && store.scanWarnings.isEmpty {
                    ContentUnavailableView(tr("目前没有待重试的项目"), systemImage: "checkmark.circle", description: Text(tr("扫描或分析遇到问题时，文件和文件夹会显示在这里。")))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private func retryPath(for warning: String) -> String? {
        let candidates: [String] = {
            if warning.hasPrefix("目录不可访问："), let end = warning.range(of: "。") {
                return [String(warning[warning.index(warning.startIndex, offsetBy: "目录不可访问：".count)..<end.lowerBound])]
            }
            if warning.hasPrefix("无法扫描目录：") { return [String(warning.dropFirst("无法扫描目录：".count))] }
            if warning.hasPrefix("/") , let separator = warning.range(of: "：") { return [String(warning[..<separator.lowerBound])] }
            return []
        }()
        guard let candidate = candidates.first, !candidate.isEmpty else { return nil }
        let url = URL(fileURLWithPath: candidate)
        if Analyzer.imageExtensions.contains(url.pathExtension.lowercased()) || Analyzer.videoExtensions.contains(url.pathExtension.lowercased()) {
            return url.deletingLastPathComponent().path
        }
        return candidate
    }
}

struct MediaCard: View {
    let item: MediaItem
    var selected = false
    var selectionMode = false
    var selectedForBatch = false
    var compact = false
    var open: (() -> Void)? = nil
    var choose: () -> Void
    @StoredState private var hoverPreviewVisible = false
    @StoredState private var hoverWorkItem: DispatchWorkItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { choose(); if !selectionMode { open?() } } label: {
                ZStack(alignment: .bottomLeading) {
                    Thumbnail(item: item)
                    HStack {
                        if item.isMotion { Label("LIVE", systemImage: "livephoto") }
                        if item.isVideo { Label(time(item.duration), systemImage: "play.fill") }
                        if item.error != nil { Image(systemName: "exclamationmark.triangle.fill") }
                    }.font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4)).padding(6).opacity(item.isMotion || item.isVideo || item.error != nil ? 1 : 0)
                    if selectionMode {
                        Image(systemName: selectedForBatch ? "checkmark.circle.fill" : "circle")
                            .font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, selectedForBatch ? accent : .black.opacity(0.35))
                            .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 2 : 6))
                .overlay(RoundedRectangle(cornerRadius: compact ? 2 : 6).strokeBorder(selected ? accent : .clear, lineWidth: 3))
                .contentShape(Rectangle())
                .help(selectionMode ? tr("选择这项影像") : item.name)
            }.buttonStyle(.plain).accessibilityAddTraits(.isButton)
            if !compact {
                Text(item.name).font(.caption).lineLimit(1)
                Text(localizedDate(item.date)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if hoverPreviewVisible {
                VStack(alignment: .leading, spacing: 0) {
                    Thumbnail(item: item).frame(width: 310, height: 230).clipped()
                    HStack(spacing: 6) {
                        if item.isVideo { Image(systemName: "play.fill") }
                        Text(item.name).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(localizedDate(item.date))
                    }.font(.caption).padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
                .frame(width: 310)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .zIndex(hoverPreviewVisible ? 5 : 0)
        .onHover { hovering in
            hoverWorkItem?.cancel()
            if hovering {
                let work = DispatchWorkItem { withAnimation(.easeOut(duration: 0.16)) { hoverPreviewVisible = true } }
                hoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            } else {
                hoverPreviewVisible = false
                hoverWorkItem = nil
            }
        }
        .onDisappear { hoverWorkItem?.cancel(); hoverWorkItem = nil; hoverPreviewVisible = false }
        .help(item.name + " · " + localizedDate(item.date)).accessibilityLabel(item.name).accessibilityAddTraits(.isButton)
    }
}

struct MediaPreview: View {
    @ObservedObject var store: LibraryStore
    let items: [MediaItem]
    let initialItem: MediaItem
    let onClose: () -> Void
    let onToggleFullScreen: () -> Void
    @StoredState private var selectedID: String
    @StoredState private var showFilmstrip = true
    @StoredState private var scale = 1.0
    @StoredState private var held = false
    @StoredState private var controlsVisible = true
    @StoredState private var isFullScreen = false
    @StoredState private var showInspector = false
    @StoredState private var hoveredID: String?
    @StoredState private var hoverPreviewID: String?
    @StoredState private var hoverWorkItem: DispatchWorkItem?

    init(store: LibraryStore, items: [MediaItem], initialItem: MediaItem, onClose: @escaping () -> Void = {}, onToggleFullScreen: @escaping () -> Void = {}) {
        self.store = store
        self.items = items.isEmpty ? [initialItem] : items
        self.initialItem = initialItem
        self.onClose = onClose
        self.onToggleFullScreen = onToggleFullScreen
        _selectedID = StoredState(initialValue: initialItem.id)
    }

    private var item: MediaItem { store.state.items.first(where: { $0.id == selectedID }) ?? items.first(where: { $0.id == selectedID }) ?? initialItem }
    private var selectedIndex: Int { items.firstIndex(where: { $0.id == selectedID }) ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                if controlsVisible {
                    HStack(spacing: 14) {
                        Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).keyboardShortcut(.cancelAction)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline).lineLimit(1).foregroundStyle(.white)
                            Text("\(localizedDate(item.date))  ·  \(selectedIndex + 1) / \(items.count)").font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        if item.isMotion { Label(tr("按住预览动态"), systemImage: "livephoto").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                        Button { changeZoom(by: -0.25) } label: { Image(systemName: "minus.magnifyingglass") }.help(tr("缩小"))
                        Button { resetZoom() } label: { Text("\(Int(scale * 100))%") }.help(tr("适合窗口"))
                        Button { changeZoom(by: 0.25) } label: { Image(systemName: "plus.magnifyingglass") }.help(tr("放大"))
                        Button(action: onToggleFullScreen) {
                            Label(tr(isFullScreen ? "退出全屏" : "全屏显示"), systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }.help(tr(isFullScreen ? "退出全屏" : "全屏显示"))
                        Button { withAnimation(.easeInOut(duration: 0.18)) { showInspector.toggle() } } label: {
                            Image(systemName: showInspector ? "info.circle.fill" : "info.circle")
                        }.help(tr(showInspector ? "关闭影像信息" : "显示影像信息")).accessibilityLabel(tr(showInspector ? "关闭影像信息" : "显示影像信息"))
                        Button { showFilmstrip.toggle() } label: { Image(systemName: showFilmstrip ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset.filled") }
                            .help(tr(showFilmstrip ? "收起缩略图" : "展开缩略图"))
                    }
                    .buttonStyle(.plain).foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 14)
                    .background(.ultraThinMaterial.opacity(0.65))
                }

                GeometryReader { geometry in
                    ZStack {
                        if item.isVideo {
                            MovieView(path: item.path, analysisError: item.error).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ZoomablePhotoView(path: item.path, scale: $scale, isMotion: item.isMotion, onPress: { held = $0 }) { direction in navigate(direction) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if held, let path = item.companion { MotionPlayer(path: path).allowsHitTesting(false) }
                        }
                        HStack {
                            navigationButton(direction: -1, symbol: "chevron.left")
                            Spacer()
                            navigationButton(direction: 1, symbol: "chevron.right")
                        }.padding(.horizontal, 24)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if controlsVisible && showFilmstrip {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, media in
                                    Button { select(media) } label: {
                                        Thumbnail(item: media)
                                            .frame(width: 116, height: 116).clipped()
                                            .overlay(alignment: .bottomTrailing) {
                                                if media.isVideo { Image(systemName: "play.fill").font(.caption2).padding(5).foregroundStyle(.white).background(.black.opacity(0.65), in: Circle()).padding(4) }
                                            }
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(hoveredID == media.id ? accent : selectedID == media.id ? .white : .clear, lineWidth: 2))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }.buttonStyle(.plain).id(media.id).accessibilityLabel("\(index + 1) / \(items.count), \(media.name)")
                                        .onHover { hovering in updateFilmstripHover(media, hovering: hovering) }
                                }
                            }.padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        .frame(height: 150)
                        .background(Color(white: 0.08))
                        .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
                        .onChange(of: selectedID) { _, id in withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector {
                DetailView(store: store, item: item, onClose: { withAnimation(.easeInOut(duration: 0.18)) { showInspector = false } }, showsPreview: false)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1) }
            }
            }
        }
        .overlay(alignment: .bottom) {
            if let previewID = hoverPreviewID, let previewItem = items.first(where: { $0.id == previewID }) {
                HStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 0) {
                        Thumbnail(item: previewItem).frame(width: 300, height: 220).clipped()
                        HStack(spacing: 6) {
                            if previewItem.isVideo { Image(systemName: "play.fill") }
                            Text(previewItem.name).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(localizedDate(previewItem.date))
                        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 8).background(.regularMaterial)
                    }
                    .frame(width: 300).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(.trailing, 24).padding(.bottom, showFilmstrip ? 160 : 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 1200, minHeight: 560, idealHeight: 820)
        .background(.black)
        .focusable()
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onChange(of: initialItem.id) { _, id in selectedID = id; store.selectedID = id; resetZoom(); held = false }
        .onChange(of: selectedID) { _, id in store.selectedID = id; store.selectedIDs = [id]; resetZoom(); held = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
        .onDisappear { hoverWorkItem?.cancel(); hoverWorkItem = nil; hoverPreviewID = nil }
    }

    private func navigationButton(direction: Int, symbol: String) -> some View {
        Button { navigate(direction) } label: {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 42, height: 52).background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).opacity(controlsVisible ? 0.8 : 0)
    }

    private func select(_ media: MediaItem) { selectedID = media.id; store.selectedID = media.id; store.selectedIDs = [media.id] }
    private func updateFilmstripHover(_ media: MediaItem, hovering: Bool) {
        hoverWorkItem?.cancel()
        if hovering {
            hoveredID = media.id
            let id = media.id
            let work = DispatchWorkItem { if hoveredID == id { withAnimation(.easeOut(duration: 0.16)) { hoverPreviewID = id } } }
            hoverWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        } else if hoveredID == media.id {
            hoveredID = nil
            hoverPreviewID = nil
            hoverWorkItem = nil
        }
    }
    private func navigate(_ step: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(selectedIndex + step, 0), items.count - 1)
        selectedID = items[next].id
    }
    private func resetZoom() {
        scale = 1
    }
    private func changeZoom(by step: Double) {
        scale = min(8, max(1, scale + step))
    }
}

private struct ZoomablePhotoView: NSViewRepresentable {
    var path: String
    @Binding var scale: Double
    var isMotion: Bool
    var onPress: (Bool) -> Void
    var onSwipe: (Int) -> Void
    func makeNSView(context: Context) -> ZoomablePhotoSurface {
        let view = ZoomablePhotoSurface()
        view.image = NSImage(contentsOfFile: path)
        view.scale = scale
        view.onScaleChange = { value in self.scale = value }
        view.onPressChange = { pressed in if self.isMotion { self.onPress(pressed) } }
        view.onSwipe = onSwipe
        return view
    }
    func updateNSView(_ view: ZoomablePhotoSurface, context: Context) {
        if view.imagePath != path { view.imagePath = path; view.image = NSImage(contentsOfFile: path); view.resetPan() }
        view.onScaleChange = { value in self.scale = value }
        view.onPressChange = { pressed in if self.isMotion { self.onPress(pressed) } }
        view.onSwipe = onSwipe
        if abs(view.scale - scale) > 0.01 { view.setZoom(scale) }
    }
}

private final class ZoomablePhotoSurface: NSView {
    var imagePath = ""
    var image: NSImage? { didSet { needsDisplay = true } }
    var scale = 1.0
    var onScaleChange: ((Double) -> Void)?
    var onPressChange: ((Bool) -> Void)?
    var onSwipe: ((Int) -> Void)?
    private var pan = CGPoint.zero
    private var mouseStart: CGPoint?
    private var panStart = CGPoint.zero
    private var swipeDelta = 0.0
    private var pressWorkItem: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The preview is a dedicated window. Make its image surface the responder
        // as soon as it is attached so the first trackpad pinch works immediately.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    func setZoom(_ value: Double) {
        scale = min(8, max(1, value))
        if scale <= 1 { resetPan() }
        else { clampPan() }
        onScaleChange?(scale); needsDisplay = true
    }
    func resetPan() { pan = .zero; needsDisplay = true }
    private func clampPan() {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let limitX = max(0, (image.size.width * fit * scale - bounds.width) / 2)
        let limitY = max(0, (image.size.height * fit * scale - bounds.height) / 2)
        pan.x = min(limitX, max(-limitX, pan.x)); pan.y = min(limitY, max(-limitY, pan.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            let message = tr("无法打开此影像") as NSString
            message.draw(at: NSPoint(x: 24, y: bounds.midY), withAttributes: [.foregroundColor: NSColor.white])
            return
        }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let width = image.size.width * fit, height = image.size.height * fit
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext.current?.cgContext else { NSGraphicsContext.restoreGraphicsState(); return }
        context.translateBy(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
        context.scaleBy(x: scale, y: scale)
        image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func magnify(with event: NSEvent) {
        let ratio = max(0.01, 1 + event.magnification)
        let nextScale = min(8, max(1, scale * ratio))
        guard nextScale != scale else { return }

        // Keep the point beneath the pinch centered under the fingers while
        // zooming, matching the expected macOS Photos trackpad behavior.
        let anchor = convert(event.locationInWindow, from: nil)
        let offset = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        let appliedRatio = nextScale / scale
        pan = CGPoint(
            x: offset.x - appliedRatio * (offset.x - pan.x),
            y: offset.y - appliedRatio * (offset.y - pan.y)
        )
        scale = nextScale
        clampPan()
        onScaleChange?(scale)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseStart = convert(event.locationInWindow, from: nil)
        panStart = pan
        pressWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onPressChange?(true) }
        pressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        if scale > 1 { pan = CGPoint(x: panStart.x + point.x - mouseStart.x, y: panStart.y + point.y - mouseStart.y); clampPan(); needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        defer { mouseStart = nil }
        pressWorkItem?.cancel(); pressWorkItem = nil; onPressChange?(false)
        guard let mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil), dx = point.x - mouseStart.x
        if event.clickCount == 2 { setZoom(scale > 1 ? 1 : 2) }
        else if scale <= 1, abs(dx) > 70 { onSwipe?(dx < 0 ? 1 : -1) }
    }
    override func scrollWheel(with event: NSEvent) {
        if scale > 1 {
            pan = CGPoint(x: pan.x - event.deltaX, y: pan.y + event.deltaY)
            clampPan()
            needsDisplay = true
        } else {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { swipeDelta += event.scrollingDeltaX }
            if event.phase == .ended || event.phase == .cancelled {
                if abs(swipeDelta) > 45 { onSwipe?(swipeDelta < 0 ? 1 : -1) }
                swipeDelta = 0
            } else if abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) { super.scrollWheel(with: event) }
        }
    }
}

@MainActor final class MediaBrowserWindowController: NSObject, NSWindowDelegate {
    static let shared = MediaBrowserWindowController()
    private var window: NSWindow?
    private var openedID: String?

    func show(store: LibraryStore, request: MediaItem, items: [MediaItem]) {
        if let window, let host = window.contentView as? NSHostingView<MediaPreview> {
            openedID = request.id
            window.title = request.name
            host.rootView = MediaPreview(store: store, items: items, initialItem: request, onClose: { [weak self] in self?.closeWindow() }, onToggleFullScreen: { [weak window] in window?.toggleFullScreen(nil) })
            window.makeKeyAndOrderFront(nil)
            return
        }
        closeWindow()
        openedID = request.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = request.name
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        let host = NSHostingView(rootView: MediaPreview(store: store, items: items, initialItem: request, onClose: { [weak self] in self?.closeWindow() }, onToggleFullScreen: { [weak window] in window?.toggleFullScreen(nil) }))
        window.contentView = host
        window.delegate = self
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        guard let window else { openedID = nil; return }
        self.window = nil
        openedID = nil
        window.delegate = nil
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        openedID = nil
    }
}
struct Thumbnail: View {
    let item: MediaItem
    var body: some View {
        GeometryReader { geo in
            if let image = NSImage(contentsOf: LibraryPaths.thumbnail(item.id)) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
            } else { ZStack { Color.gray.opacity(0.12); Image(systemName: item.isVideo ? "film" : "photo").font(.largeTitle).foregroundStyle(.secondary) }.frame(width: geo.size.width, height: geo.size.height) }
        }
    }
}
struct MotionPlayer: NSViewRepresentable {
    let path: String
    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface(); view.wantsLayer = true
        let player = AVPlayer(url: URL(fileURLWithPath: path)); view.player = player
        let layer = AVPlayerLayer(player: player); layer.videoGravity = .resizeAspect; view.layer?.backgroundColor = NSColor.black.cgColor; view.layer?.addSublayer(layer); view.videoLayer = layer
        player.play()
        return view
    }
    func updateNSView(_ nsView: PlayerSurface, context: Context) {}
    static func dismantleNSView(_ nsView: PlayerSurface, coordinator: ()) { nsView.player?.pause(); nsView.player = nil }
    final class PlayerSurface: NSView {
        var player: AVPlayer?
        var videoLayer: AVPlayerLayer?
        override func layout() { super.layout(); videoLayer?.frame = bounds }
    }
}
struct MovieView: View {
    let path: String
    var analysisError: String? = nil
    var start: Double = 0
    var seekRequest: UUID? = nil
    @StoredState private var player: AVPlayer?
    @StoredState private var playing = false
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let player { PlayerLayerView(player: player) }
            TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                let duration = player?.currentItem?.duration.seconds ?? 0
                let current = player?.currentTime().seconds ?? 0
                let playerItem = player?.currentItem
                let ready = playerItem?.status == .readyToPlay
                let failure = analysisError ?? (playerItem?.status == .failed ? playerItem?.error?.localizedDescription : nil)
                VStack(spacing: 6) {
                    if let failure, !failure.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(tr(failure)).font(.caption).lineLimit(3).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else if playerItem?.status == .unknown {
                        HStack(spacing: 7) { ProgressView().controlSize(.small); Text(tr("正在读取视频…")).font(.caption) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 12) {
                        Button {
                            guard let player else { return }
                            if playing { player.pause() } else { player.play() }
                            playing.toggle()
                        } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 24) }
                            .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel(tr(playing ? "暂停" : "播放回忆")).disabled(!ready)
                        Slider(value: Binding(get: { current.isFinite ? min(max(current, 0), max(duration, 0.1)) : 0 }, set: { player?.seek(to: CMTime(seconds: $0, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }), in: 0...max(duration.isFinite ? duration : 0, 0.1)).disabled(!ready)
                        Text(ready ? "\(playbackTime(current)) / \(playbackTime(duration))" : tr(failure == nil ? "正在读取视频…" : "视频无法播放"))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10).background(.ultraThinMaterial)
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: seekRequest) { _, _ in seek() }
        .onDisappear { player?.pause(); playing = false }
    }
    private func load() { player?.pause(); player = AVPlayer(url: URL(fileURLWithPath: path)); playing = false; if start > 0 || seekRequest != nil { seek() } }
    private func seek() { player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); player?.play(); playing = true }
    private func playbackTime(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerSurface {
        let view = PlayerLayerSurface(); view.wantsLayer = true; view.player = player; return view
    }
    func updateNSView(_ view: PlayerLayerSurface, context: Context) { view.player = player }
}

private final class PlayerLayerSurface: NSView {
    var player: AVPlayer? { didSet { (layer as? AVPlayerLayer)?.player = player } }
    override var wantsUpdateLayer: Bool { true }
    override func makeBackingLayer() -> CALayer {
        let video = AVPlayerLayer(); video.videoGravity = .resizeAspect; return video
    }
}
struct DetailView: View {
    @ObservedObject var store: LibraryStore
    let item: MediaItem
    var onClose: () -> Void = {}
    var showsPreview = true
    @StoredState private var second: Double = 0
    @StoredState private var held = false
    @StoredState private var showMotion = false
    @StoredState private var showRecognizedText = false
    @StoredState private var seekRequest: UUID?
    @StoredState private var locationEditor = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text(tr("影像详情")).font(.headline); Spacer(); Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help(tr("关闭影像详情")).accessibilityLabel(tr("关闭影像详情")) }
                if showsPreview && (item.isVideo || showMotion) {
                    MovieView(path: item.companion ?? item.path, analysisError: item.error, start: second, seekRequest: seekRequest).frame(height: 185).id(item.id)
                    if showMotion { Button(tr("返回照片封面")) { showMotion = false } }
                }
                else if showsPreview {
                    ZStack {
                        if let image = NSImage(contentsOfFile: item.path) { Image(nsImage: image).resizable().scaledToFit() }
                        if held, let companion = item.companion { MotionPlayer(path: companion) }
                    }.frame(height: 185).background(.black.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius: 10))
                        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 40, pressing: { held = $0 && item.isMotion }, perform: {})
                }
                Text(item.name).font(.headline).textSelection(.enabled)
                if item.isMotion { Label(tr("动态照片 · 按住画面播放"), systemImage: "livephoto").font(.caption).foregroundStyle(accent) }
                VStack(alignment: .leading, spacing: 8) {
                    info(tr("时间"), localizedDate(item.date, time: true))
                    info(tr("依据"), item.dateSource)
                    info(tr("尺寸"), "\(item.width) × \(item.height)")
                    info(item.isMotion ? tr("照片") : tr("文件"), ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    if let bytes = item.companionBytes { info(tr("动态"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if item.isVideo { info(tr("时长"), time(item.duration)); info(tr("音轨"), item.hasAudio ? tr("有") : tr("无")); info(tr("分析"), tr("已分析 \(item.analyzedFrames) 帧")) }
                    HStack(alignment: .top) {
                        Text(tr("定位")).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                        Text(tr(item.location)).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button(tr(item.latitude == nil ? "标记地点" : "更改地点")) {
                            store.selectedIDs = [item.id]
                            locationEditor = true
                        }.disabled(store.isReadOnly)
                    }.font(.caption)
                }
                if let lat = item.latitude, let lon = item.longitude {
                    // Use a local coordinate display; no map tiles or reverse-geocoding network requests.
                    Label(String(format: tr("纬度 %.5f\n经度 %.5f"), lat, lon), systemImage: "location").font(.caption).foregroundStyle(.secondary)
                }
                if let error = item.error { Text(tr(error)).font(.caption).foregroundStyle(.orange) }
                if let warning = item.warning { Text(tr(warning)).font(.caption).foregroundStyle(.orange) }
                Divider()
                Text(tr("画面关键词")).font(.subheadline.bold())
                Text(item.keywords.isEmpty ? tr("暂无识别结果") : item.keywords.prefix(24).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !item.caption.isEmpty { Text(tr("本机模型描述")).font(.subheadline.bold()); Text(item.caption).font(.caption).textSelection(.enabled) }
                VStack(alignment: .leading, spacing: 10) {
                    Button { showRecognizedText.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showRecognizedText ? "chevron.down" : "chevron.right").font(.caption.bold())
                            Text(tr("识别到的文字")).font(.body.weight(.medium))
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if showRecognizedText {
                        Text(item.recognizedText.isEmpty ? tr("没有识别到文字") : item.recognizedText)
                            .font(.caption).foregroundStyle(item.recognizedText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !store.state.rules.isEmpty {
                    Text(tr("所属任务")).font(.subheadline.bold())
                    ForEach(store.state.rules) { rule in
                        Toggle(rule.name, isOn: Binding(get: { item.tasks.contains(rule.name) }, set: { _ in store.toggleTask(rule.name, item: item) })).toggleStyle(.checkbox).disabled(store.isReadOnly)
                    }
                }
                if (item.isVideo || item.isMotion) && !item.frames.isEmpty {
                    Divider(); Text(tr("视频内容时间轴")).font(.subheadline.bold())
                    let q = SearchText.contentQuery(store.query)
                    let hits = q.isEmpty ? item.frames : item.frames.filter { SearchText.lexicalScore(query: q, document: $0.keywords.joined(separator: " ") + " " + $0.text) > 0 }
                    ForEach(hits.prefix(100)) { hit in
                        Button { second = hit.second; seekRequest = UUID(); if item.isMotion { showMotion = true } } label: {
                            HStack(alignment: .top) { Text(time(hit.second)).monospacedDigit().foregroundStyle(accent); Text(hit.keywords.prefix(5).joined(separator: " · ")).lineLimit(2).foregroundStyle(.secondary); Spacer() }.font(.caption)
                        }.buttonStyle(.plain)
                    }
                    if hits.count > 100 { Text(tr("显示前 100 段；输入关键词缩小范围")).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                Text(item.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                Button { store.reveal(item) } label: { Label(tr("在访达中显示"), systemImage: "folder") }
            }.padding(20)
        }.background(paper.opacity(0.65)).id(item.id)
            .sheet(isPresented: $locationEditor) { BulkLocationSheet(store: store).frame(minWidth: 420, minHeight: 280) }
    }
    private func info(_ key: String, _ value: String) -> some View { HStack(alignment: .top) { Text(key).foregroundStyle(.secondary).frame(width: 82, alignment: .leading); Text(tr(value)).textSelection(.enabled); Spacer() }.font(.caption) }
}
struct DuplicateView: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                HStack { Label(tr("只提供建议；不会自动移动或删除原文件"), systemImage: "checkmark.shield").font(.caption).foregroundStyle(accent); Spacer(); if !store.state.hiddenGroups.isEmpty { Button(tr("恢复已忽略"), action: store.restoreIgnored).font(.caption).disabled(store.isReadOnly) } }
                let groups = store.duplicates.filter { !store.state.hiddenGroups.contains($0.id) }
                if groups.isEmpty { ContentUnavailableView(tr("暂无重复建议"), systemImage: "square.on.square", description: Text(store.busy ? tr("正在分析，完成后将在这里展示结果。") : tr("扫描完成后，会比较文件内容和画面相似度。"))).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Label(group.exact ? tr("完全重复") : tr("画面相似 · 需要比较"), systemImage: group.exact ? "equal.square" : "square.stack").font(.headline); Text(tr("\(group.items.count) 项")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(tr("忽略这组")) { store.ignore(group) }.font(.caption).disabled(store.isReadOnly) }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(index == 0 ? (group.exact ? tr("优先路径") : tr("建议优先比较")) : tr("候选副本")).font(.caption.bold()).foregroundStyle(index == 0 ? accent : .secondary)
                                        MediaCard(item: item, selected: store.selectedID == item.id) { store.selectedID = item.id }
                                        Text("\(item.width)×\(item.height) · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                                        if item.isVideo { Text("\(time(item.duration)) · \(item.hasAudio ? tr("有音轨") : tr("无音轨"))").font(.caption2).foregroundStyle(.secondary) }
                                    }.frame(width: 190)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) { ForEach(group.reasons, id: \.self) { Text("• " + tr($0)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }
                    }.padding(20).background(paper).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }
                }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
struct TaskSheet: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StoredState private var name = ""
    @StoredState private var terms = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tr("创建任务相册")).font(.title2.bold())
            Text(tr("根据识别到的内容、文字和文件名推荐归类。也可以在详情中手动调整。")).foregroundStyle(.secondary)
            TextField(tr("任务名称，例如：装修记录"), text: $name)
            TextField(tr("关键词，例如：装修，房间，家具，floor plan"), text: $terms)
            Text(tr("多个关键词用逗号分隔，匹配任意一个即可。留空则只手动归类。")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(tr("取消")) { dismiss() }; Button(tr("创建")) { store.addRule(name: name, keywords: terms); if store.errorMessage == nil { dismiss() } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.textFieldStyle(.roundedBorder).padding(28).frame(width: 510)
    }
}
struct PreferencesView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage("timeimprint.language") private var language = AppLanguage.systemDefault.rawValue
    var body: some View {
        Form {
            Section(tr("语言与品牌")) {
                Picker(tr("显示语言"), selection: Binding(get: { UserDefaults.standard.string(forKey: "timeimprint.language") ?? AppLanguage.systemDefault.rawValue }, set: { UserDefaults.standard.set($0, forKey: "timeimprint.language"); store.objectWillChange.send() })) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Text(tr("LumaTrace · AI 相册")).font(.headline)
                Text(tr("发行方：Clover F")).foregroundStyle(.secondary)
            }
            Section(tr("时光穿梭")) {
                Toggle(tr("自动生成回忆"), isOn: $store.state.memoryPreferences.enabled).disabled(store.isReadOnly).onChange(of: store.state.memoryPreferences.enabled) { _, _ in store.syncMemorySchedule() }
                Picker(tr("重复频率"), selection: Binding(get: { store.state.memoryPreferences.repeatMode }, set: { store.state.memoryPreferences.repeatMode = $0; store.syncMemorySchedule() })) {
                    Text(tr("每天")).tag("daily")
                    Text(tr("每周")).tag("weekly")
                }.disabled(store.isReadOnly)
                if store.state.memoryPreferences.repeatMode == "weekly" {
                    Text(tr("选择每周生成的日期")).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(1...7, id: \.self) { weekday in
                            let chosen = store.state.memoryPreferences.weekdays.contains(weekday)
                            Button {
                                var days = store.state.memoryPreferences.weekdays
                                if chosen { if days.count > 1 { days.remove(weekday) } }
                                else { days.insert(weekday) }
                                store.state.memoryPreferences.weekdays = days
                                store.syncMemorySchedule()
                            } label: {
                                Text(tr(memoryWeekdayKey(weekday))).font(.caption.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(chosen ? accent.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? accent : .clear, lineWidth: 1))
                            }.buttonStyle(.plain).disabled(store.isReadOnly || (chosen && store.state.memoryPreferences.weekdays.count == 1))
                                .accessibilityLabel(tr(memoryWeekdayKey(weekday)))
                                .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
                DatePicker(tr("生成时间"), selection: Binding(get: { Calendar.current.date(bySettingHour: store.state.memoryPreferences.hour, minute: store.state.memoryPreferences.minute, second: 0, of: Date()) ?? Date() }, set: { date in
                    let p = Calendar.current.dateComponents([.hour, .minute], from: date)
                    store.state.memoryPreferences.hour = p.hour ?? 20; store.state.memoryPreferences.minute = p.minute ?? 30; store.syncMemorySchedule()
                }), displayedComponents: .hourAndMinute).disabled(store.isReadOnly)
                Text(tr("优先选择往年今日，其次是同月或其他历史影像，自动剪成无声回忆短片。开启后会注册本机定时任务，用户登录时即使退出应用也可生成；休眠或关机时不保证准点。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.state.memoryPreferences.notifications ? tr("回忆通知已允许") : tr("允许回忆生成通知")) { store.enableMemoryNotifications() }.disabled(store.isReadOnly)
                if store.state.memoryPreferences.notifications { Button(tr("关闭回忆通知")) { store.state.memoryPreferences.notifications = false; store.save() }.disabled(store.isReadOnly) }
                Text(tr(store.memoryStatus)).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("监测文件夹")) {
                Text(tr("已配置 \(store.state.roots.count) 个扫描位置")).font(.caption).foregroundStyle(.secondary)
                ForEach(store.state.roots, id: \.self) { root in
                    HStack(alignment: .top) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(FileManager.default.displayName(atPath: root))
                            Text(root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(tr("移除")) { store.removeRoot(root) }.disabled(store.isReadOnly)
                    }
                }
                Button(tr("添加扫描位置…"), action: store.addRoot).disabled(store.isReadOnly)
                Text(tr("可多选，也可分次添加；所有位置都会扫描，移除位置不会删除原文件。")).font(.caption).foregroundStyle(.secondary)
            }
            if store.configurationPending { Text(tr("正在应用设置，保留已完成结果…")).font(.caption).foregroundStyle(.secondary) }
            Section(tr("视频分析")) {
                Toggle(tr("逐帧深度分析"), isOn: Binding(get: { store.state.deepVideo }, set: store.setDeepVideo)).disabled(store.isReadOnly)
                Text(tr("默认每 3 秒分析一帧；深度模式解码并分析每一帧，关键词按 3 秒合并。长视频可能耗时较久，可随时暂停。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("本机视觉模型 · 可选")) {
                Toggle(tr("使用本机 Ollama 增强画面描述"), isOn: Binding(get: { store.state.useLocalModel }, set: store.setLocalModelEnabled)).disabled(store.isReadOnly)
                TextField(tr("已安装的视觉模型名称"), text: Binding(get: { store.state.model }, set: store.setModelName)).disabled(store.isReadOnly)
                HStack {
                    Button(tr("检测连接与模型")) { store.checkLocalModel() }.disabled(store.modelCheckBusy)
                    if store.modelCheckBusy { ProgressView().controlSize(.small) }
                    if !store.installedModels.isEmpty {
                        Menu(tr("选择已安装模型")) { ForEach(store.installedModels, id: \.self) { name in Button(name) { store.setModelName(name) } } }.disabled(store.isReadOnly)
                    }
                }
                if !store.modelStatus.isEmpty { Text(tr(store.modelStatus)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(tr("仅连接 127.0.0.1:11434。需自行安装 Ollama 并准备视觉模型。图片会在本机发送给该模型；未开启时使用系统分类、OCR 和可用的文本语义模型。视频增强描述仅分析封面，逐段关键词仍由 Vision 提取。")).font(.caption).foregroundStyle(.secondary)
            }
            Section(tr("资料库")) {
                Text(tr("索引、缩略图和拍摄内容：\(LibraryPaths.base.path)")).font(.caption).textSelection(.enabled)
                Text(tr("地点按原始 GPS 坐标浏览，暂不联网查询城市名称。原目录中的文件不会被移动或删除。")).font(.caption).foregroundStyle(.secondary)
                if !store.scanSummary.isEmpty { Text(tr(store.scanSummary)).font(.caption).foregroundStyle(.secondary) }
                ForEach(store.scanWarnings, id: \.self) { Text(tr($0)).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(tr("保存并重新分析全部")) { store.save(); store.scan(force: true) }.disabled(store.busy || store.isReadOnly)
                    Button(tr("检查新增内容")) { store.save(); store.scan() }.disabled(store.busy || store.isReadOnly)
                    Button(tr("查看分析失败项")) { store.selection = "errors" }
                }
            }
        }.formStyle(.grouped).padding(8).onDisappear { store.save() }
    }
}
func time(_ seconds: Double) -> String { let n = max(0, Int(seconds.isFinite ? seconds : 0)); return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n / 60 % 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60) }
func memoryWeekdayKey(_ weekday: Int) -> String {
    [1: "星期日", 2: "星期一", 3: "星期二", 4: "星期三", 5: "星期四", 6: "星期五", 7: "星期六"][weekday] ?? "星期日"
}

struct BulkLocationSheet: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StoredState private var query = ""
    @StoredState private var results: [MKMapItem] = []
    @StoredState private var searching = false
    @StoredState private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("为所选影像添加位置")).font(.title2.bold())
            Text(tr("输入城市、区县或具体地点，选择地图搜索结果后即可批量标记。已选影像：{0} 张。")
                .replacingOccurrences(of: "{0}", with: String(store.selectedIDs.count)))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(tr("例如：巴黎 / 上海市徐汇区 / 自由女神像"), text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit(search)
                Button { search() } label: { if searching { ProgressView().controlSize(.small) } else { Label(tr("搜索地点"), systemImage: "magnifyingglass") } }
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !error.isEmpty { Text(tr(error)).font(.caption).foregroundStyle(.red) }
            List(Array(results.enumerated()), id: \.offset) { _, result in
                Button {
                    let name = result.name ?? result.placemark.title ?? query
                    let detail = result.placemark.subtitle
                    let label = [name, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                    store.assignLocation(result.placemark.coordinate, label: label.isEmpty ? query : label, to: store.selectedIDs)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.name ?? tr("未命名地点")).font(.body.weight(.medium))
                        if let subtitle = result.placemark.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button(tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(minWidth: 480, minHeight: 340)
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true; error = ""; results = []
        Task {
            do {
                let request = MKLocalSearch.Request(); request.naturalLanguageQuery = term
                let response = try await MKLocalSearch(request: request).start()
                results = Array(response.mapItems.prefix(8))
                if results.isEmpty { error = "没有找到这个地点，请尝试更完整的名称。" }
            } catch { self.error = "地点搜索失败：\(error.localizedDescription)" }
            searching = false
        }
    }
}

struct BrandMark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
        else { Image(systemName: "photo.stack.fill").resizable().scaledToFit().foregroundStyle(accent).padding(6) }
    }
}
struct MemoriesView: View {
    @ObservedObject var store: LibraryStore
    @StoredState private var playing: MemoryReel?
    private var scheduledTime: String {
        let date = Calendar.current.date(bySettingHour: store.state.memoryPreferences.hour, minute: store.state.memoryPreferences.minute, second: 0, of: Date()) ?? Date()
        let formatter = DateFormatter(); formatter.locale = Localization.language.locale; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    private var scheduleDescription: String {
        if !store.state.memoryPreferences.enabled { return tr("自动回忆已关闭") }
        if store.state.memoryPreferences.repeatMode == "weekly" {
            let days = store.state.memoryPreferences.weekdays.sorted().map { tr(memoryWeekdayKey($0)) }.joined(separator: " · ")
            return tr("每周") + " " + days + " · " + scheduledTime
        }
        return tr("每天定时 · ") + scheduledTime
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("时光穿梭")).font(.title2.bold())
                        Text(tr(store.memoryStatus)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.generateMemoryIfDue(force: true) } label: { Label(store.memoryBusy ? tr("正在生成…") : tr("生成一段回忆"), systemImage: "sparkles") }.buttonStyle(.borderedProminent).disabled(store.memoryBusy || store.isReadOnly)
                }
                HStack { Image(systemName: "clock"); Text(scheduleDescription) }.font(.caption).foregroundStyle(accent)
                if store.state.memories.isEmpty {
                    ContentUnavailableView(tr("回忆将在这里相遇"), systemImage: "clock.arrow.circlepath", description: Text(tr("添加历史照片或视频后，生成第一段时光回忆。影片保存在本机，原始影像不受影响。")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                ForEach(store.state.memories) { reel in
                    VStack(alignment: .leading, spacing: 14) {
                        if let cover = reel.itemIDs.compactMap({ id in store.state.items.first { $0.id == id } }).first {
                            Button { playing = reel } label: {
                                ZStack(alignment: .bottomLeading) {
                                    Thumbnail(item: cover)
                                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
                                    HStack(spacing: 8) {
                                        Label(localizedDate(cover.date), systemImage: "calendar")
                                        if let place = cover.placeLabel, !place.isEmpty {
                                            Label(place, systemImage: "mappin.and.ellipse").lineLimit(1)
                                        } else if cover.latitude != nil {
                                            Label(cover.location, systemImage: "mappin.and.ellipse").lineLimit(1)
                                        }
                                    }.font(.caption.weight(.semibold)).foregroundStyle(.white).padding(12)
                                    Image(systemName: "play.circle.fill").font(.system(size: 44)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.35)).frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                    .frame(height: 220).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityLabel(tr("播放回忆"))
                        }
                        HStack { Image(systemName: "sparkles").foregroundStyle(accent); Text(reel.title).font(.title3.bold()); Spacer(); Text(localizedDate(reel.created, time: true)).font(.caption).foregroundStyle(.secondary) }
                        Text(tr("\(reel.itemIDs.count) 个瞬间 · \(localizedDate(reel.from)) — \(localizedDate(reel.to))")).font(.caption).foregroundStyle(.secondary)
                        HStack { Button { playing = reel } label: { Label(tr("播放回忆"), systemImage: "play.fill") }.buttonStyle(.borderedProminent); Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: reel.path)]) } label: { Label(tr("显示影片文件"), systemImage: "folder") } }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(paper).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                }
                }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).sheet(item: $playing) { reel in
            VStack { HStack { Text(reel.title).font(.headline); Spacer(); Button(tr("完成")) { playing = nil } }; MovieView(path: reel.path, seekRequest: UUID(uuidString: reel.id)).frame(width: 800, height: 450) }.padding(20)
        }
    }
}

struct AnalysisControls: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                control(store.analysisPhase == .paused ? "继续分析" : "开始分析", icon: "play.fill", enabled: store.canStartAnalysis, action: store.startAnalysis)
                control("暂停分析", icon: "pause.fill", enabled: store.canPauseAnalysis, action: store.pauseAnalysis)
                control("终止分析", icon: "stop.fill", enabled: store.canStopAnalysis, action: store.stop)
                Spacer(minLength: 0)
            }
            if store.busy, let update = store.scanUpdate {
                HStack {
                    Text(tr(update.stage.rawValue)).font(.caption)
                    Spacer(minLength: 4)
                    if let fraction = update.fraction { Text(fraction, format: .percent.precision(.fractionLength(1))).font(.caption).monospacedDigit() }
                }.foregroundStyle(.secondary)
                if let fraction = update.fraction { ProgressView(value: fraction) }
                else if store.analysisPhase != .paused { ProgressView().controlSize(.small) }
                if !update.detail.isEmpty { Text(tr(update.detail)).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                if let total = store.totalFiles, update.stage != .pairing {
                    Text(tr("文件完成 \(store.completedFiles) / \(total)")).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !store.scanLocation.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.busy ? tr("当前扫描位置") : tr("最近扫描位置")).font(.caption2).foregroundStyle(.secondary)
                    Text(store.scanLocation).font(.caption2).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(store.scanLocation)
                }
            }
            Text(tr(store.analysisStatus)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .help(tr(store.analysisStatus))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
    private func control(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.borderless).disabled(!enabled).help(tr(title)).accessibilityLabel(tr(title))
    }
}
