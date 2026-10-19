import AppKit
import SwiftUI
import UserNotifications
import CoreLocation

enum AnalysisPhase { case idle, running, paused, stopping, stopped }

@MainActor final class LibraryStore: ObservableObject {
    @Published var state = LibraryState()
    @Published private(set) var analysisPhase: AnalysisPhase = .idle
    private var resumeStatus = ""
    private var restartAfterScan = false
    private var modelChangeTask: Task<Void, Never>?
    @Published private(set) var configurationPending = false
    @Published private(set) var previewItems: [String: MediaItem] = [:]
    var displayItems: [MediaItem] {
        let pending = Set(previewItems.keys)
        return state.items.filter { !pending.contains($0.id) } + Array(previewItems.values)
    }
    private func receivePreview(_ item: MediaItem) {
        guard busy, analysisPhase != .stopping, isWatched(item.path) else { return }
        var updated = item
        let current = state.items.first { $0.id == item.id }
        let pending = previewItems[item.id]
        let manual = [current, pending].compactMap { $0 }.first { $0.placeLabel != nil }
        if let manual { updated.placeLabel = manual.placeLabel; updated.latitude = manual.latitude; updated.longitude = manual.longitude }
        previewItems[item.id] = updated; scheduleSearch()
    }
    func isWatched(_ path: String) -> Bool { state.roots.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } }
    private func applyConfiguration() {
        save()
        guard !isReadOnly else { return }
        if busy {
            restartAfterScan = !monitoringPaused && !state.roots.isEmpty
            configurationPending = true; analysisPhase = .stopping
            scanTask?.cancel(); analyzer.gate.setPaused(false)
            if state.roots.isEmpty { monitoringPaused = true }
        } else if monitoringEnabled && !monitoringPaused { scan() }
    }
    func setDeepVideo(_ value: Bool) {
        guard !isReadOnly, value != state.deepVideo else { return }
        state.deepVideo = value; applyConfiguration()
    }
    func setLocalModelEnabled(_ value: Bool) {
        guard !isReadOnly, value != state.useLocalModel else { return }
        state.useLocalModel = value; modelStatus = ""; applyConfiguration()
        if value { checkLocalModel() }
    }
    func retryFailedModelDescriptions() {
        guard !isReadOnly, state.useLocalModel else { return }
        var retry = false
        for index in state.items.indices where state.items[index].warning?.contains("增强描述失败") == true {
            state.items[index].analysisProfile = nil; retry = true
        }
        if retry { applyConfiguration() }
    }
    func setModelName(_ value: String) {
        guard !isReadOnly, value != state.model else { return }
        state.model = value; modelStatus = ""; save()
        modelChangeTask?.cancel()
        modelChangeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)); try Task.checkCancellation(); self?.applyConfiguration() } catch {}
        }
    }
    @Published var modelStatus = ""
    @Published var modelCheckBusy = false
    @Published var installedModels: [String] = []
    var canStartAnalysis: Bool { !isReadOnly && !state.roots.isEmpty && (analysisPhase == .paused || !busy) }
    var canPauseAnalysis: Bool { !isReadOnly && busy && analysisPhase == .running }
    var canStopAnalysis: Bool { !isReadOnly && !state.roots.isEmpty && (busy || !monitoringPaused) && analysisPhase != .stopping }
    var analysisStatus: String {
        switch analysisPhase {
        case .paused: return "已暂停分析"
        case .stopping: return configurationPending ? "正在应用设置，保留已完成结果…" : "正在终止分析…"
        case .stopped: return "已终止分析"
        default: return status
        }
    }
    @Published var busy = false
    @Published var monitoringPaused = false
    @Published var status = "添加一个文件夹，开始整理你的影像"
    @Published var progress = 0.0
    @Published private(set) var scanUpdate: ScanUpdate?
    @Published private(set) var scanLocation = ""
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles: Int?
    private var folderBrowserWindow: NSWindow?
    private func receiveScanUpdate(_ update: ScanUpdate) {
        guard busy, analysisPhase != .stopping else { return }
        scanUpdate = update
        if !update.path.isEmpty { scanLocation = update.path }
    }
    @Published var errorMessage: String?
    @Published var duplicates: [DuplicateGroup] = []
    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var scores: [String: Double] = [:]
    @Published var searching = false
    @Published var selection = "all"
    @Published var selectedID: String?
    @Published var selectedIDs = Set<String>()
    @Published var scanSummary = ""
    @Published var scanWarnings: [String] = []
    @Published private(set) var retryQueued = false
    let analyzer = Analyzer()
    @Published var memoryBusy = false
    @Published var memoryStatus = "往年今日，让记忆再次发生"
    private let memoryBuilder = MemoryBuilder()
    private var memoryLastAttempt = Date.distantPast
    private var scanTask: Task<Void, Never>?
    private var pendingRetryRoots = Set<String>()
    private var searchTask: Task<Void, Never>?
    private var timer: Timer?
    private var duplicateFingerprint = ""
    private var suppressed: Set<String> = []
    @Published private(set) var accessMessage: String?
    private let monitoringEnabled: Bool
    private var accessLock: LibraryAccessLock?
    var isReadOnly: Bool { !suppressed.isEmpty }

    init(startMonitoring: Bool = true) {
        monitoringEnabled = startMonitoring
        connectLibrary(showAlert: true)
        if startMonitoring {
            timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.isReadOnly { self.retryLibraryAccess(showAlert: false) }
                    else {
                        if !self.monitoringPaused { self.scan() }
                        self.generateMemoryIfDue()
                    }
                }
            }
            if !state.roots.isEmpty { scan() }
            syncMemorySchedule(); generateMemoryIfDue()
        }
    }
    private func readLibrarySnapshot() throws -> LibraryState {
        guard FileManager.default.fileExists(atPath: LibraryPaths.index.path) else { return LibraryState() }
        return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
    }
    @discardableResult private func connectLibrary(showAlert: Bool) -> Bool {
        do {
            try LibraryPaths.prepare()
            // Retain the writer only after decoding succeeds; failed decoding must not leave the lock held.
            let writer = try LibraryAccessLock(directory: LibraryPaths.base)
            let snapshot = try readLibrarySnapshot()
            state = snapshot
            accessLock = writer
            suppressed.removeAll(); accessMessage = nil; errorMessage = nil
            status = state.roots.isEmpty ? "添加一个文件夹，开始整理你的影像" : "资料库已连接"
            scheduleSearch()
            return true
        } catch {
            accessLock = nil
            suppressed.insert("load-failed")
            // Another process may own the writer; atomic snapshots are still safe to browse.
            if let snapshot = try? readLibrarySnapshot() { state = snapshot; scheduleSearch() }
            accessMessage = error.localizedDescription
            status = "当前为只读浏览，导航和搜索仍可使用"
            if showAlert { errorMessage = "资料库暂不可写：\(error.localizedDescription)" }
            return false
        }
    }
    func retryLibraryAccess(showAlert: Bool = true) {
        guard isReadOnly, !busy, !memoryBusy else { return }
        if connectLibrary(showAlert: showAlert), monitoringEnabled {
            scan(); syncMemorySchedule(); generateMemoryIfDue()
        }
    }
    func selectSection(_ key: String) {
        selection = key
        selectedID = nil
        selectedIDs.removeAll()
    }

    func assignLocation(_ coordinate: CLLocationCoordinate2D, label: String, to ids: Set<String>) {
        guard !isReadOnly else { return }
        for id in ids {
            if let index = state.items.firstIndex(where: { $0.id == id }) {
                state.items[index].latitude = coordinate.latitude
                state.items[index].longitude = coordinate.longitude
                state.items[index].placeLabel = label
            } else if var pending = previewItems[id] {
                pending.latitude = coordinate.latitude
                pending.longitude = coordinate.longitude
                pending.placeLabel = label
                previewItems[id] = pending
                state.items.append(pending)
            }
        }
        save()
        scheduleSearch()
        selectedIDs.subtract(ids)
    }
    var selected: MediaItem? { displayItems.first { $0.id == selectedID } }
    var visible: [MediaItem] {
        var items = displayItems
        switch selection {
        case "images": items = items.filter { !$0.isVideo }
        case "videos": items = items.filter(\.isVideo)
        case "motion": items = items.filter(\.isMotion)
        case "places": items = items.filter { $0.latitude != nil }
        case "errors": items = items.filter { $0.error != nil }
        default:
            if selection.hasPrefix("task:") { let name = String(selection.dropFirst(5)); items = items.filter { $0.tasks.contains(name) } }
        }
        if let year = SearchText.matchingYear(query) { items = items.filter { Calendar.current.component(.year, from: $0.date) == year } }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items = items.filter { scores[$0.id] != nil }
            return items.sorted { (scores[$0.id] ?? 0) > (scores[$1.id] ?? 0) }
        }
        return items.sorted { $0.date > $1.date }
    }
    var sections: [(String, [MediaItem])] {
        let formatter = DateFormatter(); formatter.locale = Localization.language.locale; formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        let grouped = Dictionary(grouping: visible) { selection == "places" ? $0.location : formatter.string(from: $0.date) }
        return grouped.map { ($0.key, $0.value) }.sorted { ($0.1.first?.date ?? .distantPast) > ($1.1.first?.date ?? .distantPast) }
    }
    func save() {
        guard !isReadOnly else { return }
        do { try JSONEncoder().encode(state).write(to: LibraryPaths.index, options: .atomic) }
        catch { errorMessage = "资料库保存失败：\(error.localizedDescription)" }
    }
    func addRoot() {
        guard !isReadOnly else { return }
        if let window = folderBrowserWindow, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("添加扫描位置")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FolderBrowserView(store: self, close: { [weak window] in window?.close() }))
        window.minSize = NSSize(width: 700, height: 460)
        folderBrowserWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func addRoots(_ urls: [URL], startScan: Bool = true) {
        guard !isReadOnly else { return }
        for url in urls {
            let path = url.standardizedFileURL.path
            if url.pathExtension.lowercased() == "photoslibrary" { errorMessage = "系统照片资料库需先从照片 App 导出原片，再添加导出文件夹。"; continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { continue }
            if !state.roots.contains(path) { state.roots.append(path) }
        }
        save()
        if startScan { scan() }
    }
    func removeRoot(_ root: String) { removeRoots([root]) }
    func removeRoots(_ roots: Set<String>) {
        guard !isReadOnly, !roots.isEmpty, state.roots.contains(where: { roots.contains($0) }) else { return }
        state.roots.removeAll { roots.contains($0) }; applyConfiguration()
        status = "已停止监测该目录，已有索引仍可浏览"
    }
    func scan(force: Bool = false, roots selectedRoots: [String]? = nil) {
        let roots = selectedRoots ?? state.roots
        guard !busy, !roots.isEmpty, !isReadOnly else { return }
        monitoringPaused = false
        analysisPhase = .running; analyzer.gate.setPaused(false)
        configurationPending = false; previewItems = [:]
        busy = true; progress = 0; completedFiles = 0; totalFiles = nil
        scanUpdate = ScanUpdate(stage: .discovering, path: roots.first ?? "")
        scanLocation = roots.first ?? ""
        let report: ScanReporter = { [weak self] update in await self?.receiveScanUpdate(update) }
        let preview: ScanPreviewReporter = { [weak self] item in await self?.receivePreview(item) }
        let deep = state.deepVideo, modelEnabled = state.useLocalModel, model = state.model
        scanTask = Task {
            defer {
                busy = false; scanTask = nil; previewItems = [:]
                if analysisPhase == .stopping { analysisPhase = .stopped; progress = 0 }
                else { analysisPhase = .idle }
                scheduleSearch()
                let restart = restartAfterScan && !monitoringPaused && !state.roots.isEmpty && !isReadOnly
                restartAfterScan = false; configurationPending = false
                let retryRoots = pendingRetryRoots
                pendingRetryRoots.removeAll(); retryQueued = false
                if !retryRoots.isEmpty { scan(force: true, roots: retryRoots.sorted()) }
                else if restart { scan() }
            }
            do {
                status = "正在检查文件夹…"
                let listing = try await analyzer.discover(roots: roots, report: report)
                try await analyzer.gate.checkpoint()
                let files = listing.files
                if Set(roots) == Set(state.roots) { scanWarnings = listing.warnings }
                else {
                    scanWarnings.removeAll { warning in roots.contains(where: { warning.contains($0) }) }
                    scanWarnings = Array(Set(scanWarnings + listing.warnings)).sorted()
                }
                status = "正在识别动态照片配对…"
                let pairs = try await analyzer.pairing(files, report: report)
                try await analyzer.gate.checkpoint()
                let companions = Set(pairs.values)
                let inputs = files.filter { !companions.contains($0.url.path) }
                totalFiles = inputs.count
                var completed = 0, failures = 0
                for (index, file) in inputs.enumerated() {
                    try await analyzer.gate.checkpoint()
                    let old = state.items.first { $0.path == file.url.path }
                    let companion = pairs[file.url.path]
                    let companionFile = companion.flatMap { p in files.first { $0.url.path == p } }
                    let companionDate = companionFile?.modified
                    if !force, let old, !old.digest.isEmpty, old.error == nil, (old.analysisProfile ?? AnalysisProfile.legacy) == AnalysisProfile.key(video: old.isVideo || companion != nil, deep: deep, localModel: modelEnabled, model: model), old.modified == file.modified, old.bytes == file.bytes, old.companion == companion, old.companionModified == companionDate, old.companionBytes == companionFile?.bytes, FileManager.default.fileExists(atPath: LibraryPaths.thumbnail(old.id).path) {
                        completedFiles = index + 1; progress = Double(index + 1) / Double(max(1, inputs.count)); continue
                    }
                    status = "\(index + 1)/\(inputs.count) · \(file.url.lastPathComponent)\(deep ? " · 逐帧分析" : "")"
                    do {
                        var item = try await analyzer.analyze(file, companion: companion, deep: deep, localModel: modelEnabled, model: model, previous: old, report: report, preview: preview)
                        try await analyzer.gate.checkpoint()
                        let unchanged = try file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == file.modified
                        guard unchanged, isWatched(file.url.path) else { previewItems.removeValue(forKey: item.id); continue }
                        // Preserve a manual location assigned while analysis was suspended.
                        if let current = state.items.first(where: { $0.id == item.id }), current.placeLabel != nil {
                            item.placeLabel = current.placeLabel
                            item.latitude = current.latitude
                            item.longitude = current.longitude
                        }
                        applyRules(to: &item)
                        state.items.removeAll { $0.path == file.url.path }; state.items.append(item); previewItems.removeValue(forKey: item.id); completed += 1
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        failures += 1
                        var failed = old ?? MediaItem(id: analyzer.identifier(file.url.path), path: file.url.path, modified: file.modified, bytes: file.bytes, kind: Analyzer.videoExtensions.contains(file.url.pathExtension.lowercased()) ? "video" : "image", date: file.modified, dateSource: "文件修改时间")
                        failed.error = Analyzer.userFacingError(error)
                        if let current = state.items.first(where: { $0.id == failed.id }), current.placeLabel != nil {
                            failed.placeLabel = current.placeLabel
                            failed.latitude = current.latitude
                            failed.longitude = current.longitude
                        }
                        state.items.removeAll { $0.path == file.url.path }; state.items.append(failed)
                    }
                    // Save each completed asset so a canceled long video scan never loses earlier work.
                    save(); scheduleSearch(); completedFiles = index + 1; progress = Double(index + 1) / Double(max(1, inputs.count))
                }
                try await analyzer.gate.checkpoint()
                // Hide paired videos as separate items, but retain missing files for disconnected disks.
                state.items.removeAll { companions.contains($0.path) }
                save()
                status = "正在比较重复与相似内容…"
                let currentItems = state.items.filter(\.isCurrentOnDisk)
                let fingerprint = currentItems.map { $0.id + $0.digest + ($0.companionHash ?? "") + ($0.error ?? "") }.sorted().joined(separator: "|")
                if force || fingerprint != duplicateFingerprint {
                    let foundDuplicates = try await analyzer.duplicates(currentItems, report: report)
                    try await analyzer.gate.checkpoint()
                    duplicates = foundDuplicates
                    duplicateFingerprint = fingerprint
                }
                try await analyzer.gate.checkpoint()
                scanSummary = "本次分析 \(completed) 项 · 失败 \(failures) 项 · 目录提醒 \(scanWarnings.count) 项 · 每 20 秒检查新增内容"
                status = "已收录 \(state.items.count) 项 · \(duplicates.count) 组重复或相似内容"
                progress = 1
            } catch is CancellationError { status = "已终止分析；已完成的结果已保存" }
            catch { status = "扫描未完成"; errorMessage = error.localizedDescription }
        }
    }
    func retryFolder(_ path: String) {
        guard state.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            errorMessage = "此位置不在监测文件夹中，请先在设置里添加该文件夹。"
            return
        }
        refreshFolders([path], queuedMessage: "当前扫描完成后重试该文件夹")
    }
    func refreshFolders(_ roots: [String], queuedMessage: String = "当前扫描完成后刷新文件夹") {
        let targets = Set(roots.filter { root in state.roots.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) })
        guard !targets.isEmpty, !isReadOnly else { return }
        if busy {
            pendingRetryRoots.formUnion(targets); retryQueued = true
            status = queuedMessage
        } else { scan(force: true, roots: targets.sorted()) }
    }
    func retryFailedItems() {
        var roots = Set(state.items.filter { $0.error != nil }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
        if !scanWarnings.isEmpty { roots.formUnion(state.roots) }
        if roots.isEmpty { roots.formUnion(state.roots) }
        guard !roots.isEmpty else { return }
        refreshFolders(roots.sorted(), queuedMessage: "当前扫描完成后开始重试失败项")
    }
    func startAnalysis() {
        guard canStartAnalysis else { return }
        if analysisPhase == .paused {
            monitoringPaused = false; analysisPhase = .running
            status = resumeStatus; analyzer.gate.setPaused(false)
        } else { scan() }
    }
    func pauseAnalysis() {
        guard canPauseAnalysis else { return }
        resumeStatus = status; monitoringPaused = true
        analysisPhase = .paused; analyzer.gate.setPaused(true)
    }
    func stop() {
        guard canStopAnalysis else { return }
        restartAfterScan = false; configurationPending = false
        monitoringPaused = true
        analysisPhase = busy ? .stopping : .stopped
        scanTask?.cancel(); analyzer.gate.setPaused(false)
        if !busy { progress = 0 }
    }
    func addRule(name: String, keywords: String) {
        guard !isReadOnly else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !state.rules.contains(where: { $0.name == name }) else { errorMessage = "请输入未使用的任务名称"; return }
        state.rules.append(TaskRule(name: name, keywords: keywords))
        for index in state.items.indices { applyRules(to: &state.items[index]) }
        save(); scheduleSearch()
    }
    private func applyRules(to item: inout MediaItem) {
        let document = item.searchableText
        for rule in state.rules where !item.excludedTasks.contains(rule.name) && rule.terms.contains(where: { SearchText.lexicalScore(query: $0, document: document) > 0 }) {
            if !item.tasks.contains(rule.name) { item.tasks.append(rule.name) }
        }
    }
    func toggleTask(_ name: String, item: MediaItem) {
        guard !isReadOnly else { return }
        guard let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        if state.items[index].tasks.contains(name) {
            state.items[index].tasks.removeAll { $0 == name }
            if !state.items[index].excludedTasks.contains(name) { state.items[index].excludedTasks.append(name) }
        } else {
            state.items[index].excludedTasks.removeAll { $0 == name }
            state.items[index].tasks.append(name)
        }
        save(); scheduleSearch()
    }
    func ignore(_ group: DuplicateGroup) { guard !isReadOnly else { return }; state.hiddenGroups.append(group.id); save() }
    func restoreIgnored() { guard !isReadOnly else { return }; state.hiddenGroups = []; save() }
    func scheduleSearch() {
        searchTask?.cancel()
        let query = query, items = displayItems
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { scores = [:]; searching = false; return }
        searching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(220))
                let found = try await analyzer.search(items, query: query)
                try Task.checkCancellation()
                scores = found; searching = false
            } catch { if !Task.isCancelled { searching = false } }
        }
    }
    func captureImported(_ imageURL: URL) {
        guard !isReadOnly else { return }
        let root = imageURL.deletingLastPathComponent().path
        if !state.roots.contains(root) { state.roots.append(root) }
        save()
        // Let the capture finish writing before scanning; the periodic monitor also picks it up.
        Task { try? await Task.sleep(for: .seconds(4)); if !monitoringPaused { scan() } }
    }
    func reveal(_ item: MediaItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
}

extension LibraryStore {
    func generateMemoryIfDue(force: Bool = false) {
        guard !isReadOnly, !memoryBusy else { return }
        if !force {
            guard MemorySelection.due(state.memoryPreferences, now: Date()), Date().timeIntervalSince(memoryLastAttempt) > 600 else { return }
            guard state.items.contains(where: { $0.error == nil && $0.date < Calendar.current.startOfDay(for: Date()) }) else { return }
        }
        memoryLastAttempt = Date(); memoryBusy = true; memoryStatus = "正在编织你的回忆影片…"
        let snapshot = state.items
        Task {
            defer { memoryBusy = false }
            do {
                if let reel = try await memoryBuilder.build(items: snapshot) {
                    state.memories.insert(reel, at: 0)
                    state.memoryPreferences.lastDay = MemorySelection.dayKey(Date())
                    save(); memoryStatus = "新的回忆影片已准备好"
                    if state.memoryPreferences.notifications { await MemoryNotification.deliver(reel) }
                } else { memoryStatus = "还没有可用的历史影像，请先添加往日照片或视频" }
            } catch { memoryStatus = "回忆生成失败：\(error.localizedDescription)" }
        }
    }
    func syncMemorySchedule() {
        guard !isReadOnly else { return }
        save()
        let settings = state.memoryPreferences
        Task {
            do { try await MemoryScheduleCoordinator.shared.sync(settings) }
            catch { memoryStatus = error.localizedDescription }
        }
    }
    func enableMemoryNotifications() {
        guard !isReadOnly else { return }
        Task {
            do {
                state.memoryPreferences.notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                save()
            } catch { memoryStatus = error.localizedDescription }
        }
    }
}
