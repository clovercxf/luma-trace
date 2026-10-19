import Testing
import AppKit
import AVFoundation
import Vision
import ImageIO
@testable import LumaTrace

private actor ScanUpdates {
    var updates: [ScanUpdate] = []
    func append(_ update: ScanUpdate) { updates.append(update) }
    func snapshot() -> [ScanUpdate] { updates }
}
@Suite(.serialized) struct LibraryTests {
    @MainActor @Test func testFileBrowserSupportsHiddenFoldersFullPathsAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pictures = root.appendingPathComponent("Pictures")
        let hidden = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("photo.jpg"))
        let entries = try FolderBrowserModel.list(root, hidden: false)
        #expect(entries.contains { $0.url.lastPathComponent == "Pictures" && $0.directory })
        #expect(entries.contains { $0.url.lastPathComponent == "photo.jpg" && !$0.directory })
        #expect(!entries.contains { $0.url.lastPathComponent == ".hidden" })
        let includingHidden = try FolderBrowserModel.list(root, hidden: true)
        #expect(includingHidden.map { $0.url.lastPathComponent }.contains(".hidden"))
        expectEqual(FolderBrowserModel.resolve("~/Pictures")?.path, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path)
        expectNil(FolderBrowserModel.resolve("relative/path"))
        let model = FolderBrowserModel(location: root)
        model.go(pictures); expectEqual(model.location.path, pictures.path)
        model.goBack(); expectEqual(model.location.path, root.path)
        model.goForward(); expectEqual(model.location.path, pictures.path)
        model.go(root.appendingPathComponent("missing")); expectEqual(model.location.path, pictures.path)
        expectTrue(model.error != nil)
    }
    @MainActor @Test func testMultipleScanRootsPersistAndDiscoverEachLocation() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use an isolated test library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: LibraryPaths.index) }
        }
        let a = root.appendingPathComponent("Pictures"), b = root.appendingPathComponent("Another disk")
        for folder in [a, b] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let photo = folder.appendingPathComponent("sample.jpg")
            try Data("fixture".utf8).write(to: photo)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: photo.path)
        }
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        store.addRoots([a, b, a, root.appendingPathComponent("missing"), a.appendingPathComponent("sample.jpg")], startScan: false)
        expectEqual(store.state.roots, [a.path, b.path])
        let persisted = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
        expectEqual(persisted.roots, [a.path, b.path])
        let updates = ScanUpdates()
        let listing = try await store.analyzer.discover(roots: store.state.roots, report: { await updates.append($0) })
        expectEqual(listing.files.count, 2)
        let events = await updates.snapshot()
        expectTrue(events.contains { $0.path == a.path && $0.stage == .discovering && $0.fraction == nil })
        expectTrue(events.contains { $0.path == b.path && $0.stage == .discovering })
        store.removeRoot(a.path)
        expectEqual(store.state.roots, [b.path])
        expectTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent("sample.jpg").path))
        store.addRoots([a], startScan: false)
        let indexed = item("retained-index")
        store.state.items = [indexed]
        store.removeRoots([a.path, b.path, "/not-configured"])
        expectTrue(store.state.roots.isEmpty)
        expectEqual(store.state.items.first?.id, indexed.id)
        let removed = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
        expectTrue(removed.roots.isEmpty)
        expectEqual(removed.items.first?.id, indexed.id)
        expectTrue(FileManager.default.fileExists(atPath: b.appendingPathComponent("sample.jpg").path))
    }

    @Test func testBrandMetadataAndNotificationNameAreConsistent() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: package.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
        expectEqual(info["CFBundleName"] as? String, AppBrand.name)
        expectEqual(info["CFBundleDisplayName"] as? String, AppBrand.name)
        expectEqual(info["CFBundleExecutable"] as? String, AppBrand.name)
        // Preserve the system identity so existing library/notification permissions remain associated.
        expectEqual(info["CFBundleIdentifier"] as? String, "local.shiguang.library")
        for language in AppLanguage.allCases {
            let strings = try String(contentsOf: package.appendingPathComponent("BrandAssets/" + language.rawValue + ".lproj/InfoPlist.strings"), encoding: .utf8)
            expectTrue(strings.contains("\"CFBundleDisplayName\" = \"LumaTrace\";"))
            expectTrue(strings.contains("\"CFBundleName\" = \"LumaTrace\";"))
        }
        let reel = MemoryReel(id: "brand-test", created: Date(), kind: "anniversary", itemIDs: [], path: "/fixture.mp4", from: Date(), to: Date())
        let content = MemoryNotification.notificationContent(for: reel)
        expectEqual(content.title, AppBrand.name)
        expectEqual(content.subtitle, tr("时光穿梭"))
        expectTrue(content.body.contains(tr("新的回忆影片已准备好")))
    }

    @Test func testPausedCheckpointCanBeCancelledWithoutResume() async throws {
        let gate = AnalysisGate(); gate.setPaused(true)
        let task = Task { try await gate.checkpoint() }
        task.cancel()
        do { try await task.value; Issue.record("A cancelled pause must throw") }
        catch is CancellationError {} catch { throw error }
        gate.setPaused(false)
        try await gate.checkpoint()
    }
    @MainActor @Test func testAnalysisPauseResumeStopAndRestart() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use an isolated test library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: LibraryPaths.index) }
        }
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        expectTrue(!store.canStartAnalysis); expectTrue(!store.canStopAnalysis)
        store.state.roots = [folder.path]
        let existing = item("keep-completed")
        store.state.items = [existing]
        store.startAnalysis()
        expectEqual(store.analysisPhase, .running); expectTrue(store.canPauseAnalysis)
        store.pauseAnalysis()
        expectEqual(store.analysisPhase, .paused); expectTrue(store.canStartAnalysis)
        expectTrue(!store.canPauseAnalysis); expectTrue(store.canStopAnalysis)
        try await Task.sleep(for: .milliseconds(120))
        expectTrue(store.busy); expectEqual(store.progress, 0)
        // Pausing only affects analysis, not browsing/searching on the analyzer actor.
        let results = try await store.analyzer.search([existing], query: "keep")
        expectTrue(results[existing.id] != nil)
        store.startAnalysis()
        expectEqual(store.analysisPhase, .running)
        for _ in 0..<100 { if !store.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        expectTrue(!store.busy); expectEqual(store.analysisPhase, .idle)
        expectEqual(store.progress, 1); expectEqual(store.state.items.first?.id, existing.id)
        // Stop while paused must cancel the waiting task and suppress timer restarts.
        store.startAnalysis(); store.pauseAnalysis(); store.stop()
        expectEqual(store.analysisPhase, .stopping); expectTrue(!store.canStartAnalysis)
        for _ in 0..<100 { if !store.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        expectTrue(!store.busy); expectEqual(store.analysisPhase, .stopped)
        expectTrue(store.monitoringPaused); expectEqual(store.progress, 0)
        expectEqual(store.state.items.first?.id, existing.id)
        store.startAnalysis()
        for _ in 0..<100 { if !store.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        expectEqual(store.analysisPhase, .idle); expectTrue(!store.monitoringPaused)
    }

    @Test func testLanguagePreservesChosenRegion() {
        expectEqual(AppLanguage.en.regionalLocale(region: "GB").region?.identifier, "GB")
        expectEqual(AppLanguage.en.regionalLocale(region: "US").language.languageCode?.identifier, "en")
        expectEqual(AppLanguage.zh.regionalLocale(region: "US").language.languageCode?.identifier, "zh")
        expectEqual(AppLanguage.zh.regionalLocale(region: "US").region?.identifier, "US")
        expectEqual(AppLanguage.es.regionalLocale(region: "MX").region?.identifier, "MX")
        expectEqual(AppLanguage.es.regionalLocale(region: nil).language.languageCode?.identifier, "es")
    }

    func item(_ id: String = "a", kind: String = "image") -> MediaItem {
        MediaItem(id: id, path: "/fixtures/\(id).jpg", modified: Date(), bytes: 100, kind: kind, date: Date(), dateSource: "拍摄时间")
    }
    @Test func testLivePhotoExactKeyIncludesBothResources() {
        var a = item(); a.digest = "same-photo"; a.companion = "/a.mov"; a.companionHash = "motion-a"
        var b = a; b.companionHash = "motion-b"
        expectNotEqual(DuplicatePolicy.exactKey(a), DuplicatePolicy.exactKey(b))
        b.companionHash = nil
        expectNil(DuplicatePolicy.exactKey(b))
        b.companion = nil
        expectNotEqual(DuplicatePolicy.exactKey(a), DuplicatePolicy.exactKey(b))
    }
    @Test func testFailedOrUnhashedItemsAreNeverExactDuplicates() {
        var a = item()
        expectNil(DuplicatePolicy.exactKey(a))
        a.digest = "abc"; a.error = "unreadable"
        expectNil(DuplicatePolicy.exactKey(a))
    }
    @Test func testChineseQueriesAndDateFiltering() {
        expectGreater(SearchText.lexicalScore(query: "海边", document: "beach ocean"), 0)
        expectGreater(SearchText.lexicalScore(query: "白色小狗", document: "white dog"), 0.5)
        expectEqual(SearchText.lexicalScore(query: "cat", document: "ocean"), 0)
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        expectEqual(SearchText.matchingYear("去年 海边", now: date), 2025)
        expectEqual(SearchText.matchingYear("2024 年海边", now: date), 2024)
        expectEqual(SearchText.contentQuery("去年 海边"), "海边")
    }
    @Test func testVideoAdviceDoesNotEquateLongerWithBetter() {
        var a = item(kind: "video"), b = item("b", kind: "video")
        a.duration = 20; b.duration = 10; a.hasAudio = true
        let reasons = DuplicatePolicy.reasons(best: a, other: b).joined()
        expectTrue(reasons.contains("独有片段"))
        expectTrue(reasons.contains("音轨不同"))
    }
    @Test func testAtomicCodableRoundTripPreservesTasksAndFrames() throws {
        var a = item(); a.tasks = ["旅行"]; a.frames = [FrameHit(second: 3, keywords: ["海边"], text: "测试")]
        let library = LibraryState(roots: ["/fixtures"], items: [a], rules: [TaskRule(name: "旅行", keywords: "海边，沙滩")])
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(library))
        expectEqual(restored.items[0].frames[0].second, 3)
        expectEqual(restored.items[0].tasks, ["旅行"])
        expectEqual(restored.rules[0].terms, ["海边", "沙滩"])
    }
    @Test func testContentHashAndExactGrouping() async throws {
        let analyzer = Analyzer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.jpg")
        try Data("identical bytes".utf8).write(to: file)
        let hash = try await analyzer.hash(file)
        expectEqual(hash.count, 64)
        var a = item(), b = item("b"), c = item("c")
        a.digest = hash; b.digest = hash; c.digest = "different"
        let groups = try await analyzer.duplicates([a, b, c])
        expectEqual(groups.count, 1)
        expectTrue(groups[0].exact)
        expectEqual(groups[0].items.count, 2)
    }
    @Test func testExplicitCameraSidecarPairingAndNoFilenameGuessing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("capture.jpg"), movie = folder.appendingPathComponent("capture.mov")
        try Data().write(to: photo); try Data().write(to: movie)
        let files = [ScanFile(url: photo, modified: .distantPast, bytes: 0), ScanFile(url: movie, modified: .distantPast, bytes: 0)]
        let analyzer = Analyzer()
        let unpaired = try await analyzer.pairing(files)
        expectTrue(unpaired.isEmpty)
        try JSONSerialization.data(withJSONObject: ["video": "capture.mov"]).write(to: folder.appendingPathComponent("capture.shiguang.json"))
        let paired = try await analyzer.pairing(files)
        expectEqual(paired[photo.path], movie.path)
        try JSONSerialization.data(withJSONObject: ["video": "../capture.mov"]).write(to: folder.appendingPathComponent("capture.shiguang.json"))
        let escaped = try await analyzer.pairing(files)
        expectTrue(escaped.isEmpty)
    }
    @MainActor @Test func testReadOnlyLibraryStillSupportsEverySidebarRoute() throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use an isolated test library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        defer { if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) } else { try? FileManager.default.removeItem(at: LibraryPaths.index) } }
        var photo = item(); photo.tasks = ["旅行"]
        let snapshot = LibraryState(roots: ["/fixtures"], items: [photo], rules: [TaskRule(name: "旅行", keywords: "beach")])
        let bytes = try JSONEncoder().encode(snapshot)
        try bytes.write(to: LibraryPaths.index, options: .atomic)
        let writer = try LibraryAccessLock(directory: LibraryPaths.base)
        let reader = LibraryStore(startMonitoring: false)
        expectTrue(reader.isReadOnly)
        expectEqual(reader.state.items.count, 1)
        for route in ["all", "images", "videos", "motion", "places", "memories", "duplicates", "task:旅行"] {
            reader.selectedID = photo.id
            reader.selectSection(route)
            expectEqual(reader.selection, route)
            expectNil(reader.selectedID)
        }
        reader.addRule(name: "Should not save", keywords: "cat")
        reader.removeRoot("/fixtures")
        reader.toggleTask("旅行", item: photo)
        reader.restoreIgnored()
        reader.save()
        expectEqual(try Data(contentsOf: LibraryPaths.index), bytes)
        expectEqual(reader.state.rules.count, 1)
        expectEqual(reader.state.roots, ["/fixtures"])
        expectEqual(reader.state.items[0].tasks, ["旅行"])
        withExtendedLifetime(writer) {}
    }
    @MainActor @Test func testReconnectLoadsLatestSnapshotAfterWriterExits() throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use an isolated test library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        defer { if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) } else { try? FileManager.default.removeItem(at: LibraryPaths.index) } }
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        var writer: LibraryAccessLock? = try LibraryAccessLock(directory: LibraryPaths.base)
        let reader = LibraryStore(startMonitoring: false)
        expectTrue(reader.isReadOnly)
        try JSONEncoder().encode(LibraryState(items: [item("latest")])).write(to: LibraryPaths.index, options: .atomic)
        withExtendedLifetime(writer) {}
        writer = nil
        reader.retryLibraryAccess()
        expectTrue(!reader.isReadOnly)
        expectNil(reader.accessMessage)
        expectEqual(reader.state.items.first?.id, "latest")
        reader.selectSection("memories")
        expectEqual(reader.selection, "memories")
    }
    @MainActor @Test func testCorruptIndexRemainsNavigableAndReleasesFailedLock() throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use an isolated test library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        defer { if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) } else { try? FileManager.default.removeItem(at: LibraryPaths.index) } }
        let invalid = Data("{broken index".utf8)
        try invalid.write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        expectTrue(store.isReadOnly)
        store.selectSection("videos"); expectEqual(store.selection, "videos")
        store.save(); expectEqual(try Data(contentsOf: LibraryPaths.index), invalid)
        // Failed decoding must not monopolize the lock needed to recover the library.
        var repairWriter: LibraryAccessLock? = try LibraryAccessLock(directory: LibraryPaths.base)
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        withExtendedLifetime(repairWriter) {}
        repairWriter = nil
        store.retryLibraryAccess()
        expectTrue(!store.isReadOnly)
    }
    @Test func testThreeLanguageCatalogAndDynamicValues() {
        expectEqual(tr("LumaTrace", language: .en), "LumaTrace")
        expectEqual(tr("LumaTrace", language: .es), "LumaTrace")
        expectEqual(tr("LumaTrace", language: .zh), "LumaTrace")
        expectEqual(tr("已收录 12 项 · 3 组重复或相似内容", language: .en), "12 items indexed · 3 duplicate or similar groups")
        expectEqual(tr("已分析 24 帧", language: .es), "24 fotogramas analizados")
        expectEqual(tr("增强描述失败：无法读取图片", language: .en), "Enhanced description failed: Cannot read image")
        for (key, pair) in Localization.catalog {
            expectTrue(!pair.0.isEmpty && !pair.1.isEmpty)
            for index in 0..<5 where key.contains("{\(index)}") { expectTrue(pair.0.contains("{\(index)}") && pair.1.contains("{\(index)}")) }
        }
    }
    @Test func testSpanishQueriesAndThreeLanguageYears() {
        expectGreater(SearchText.lexicalScore(query: "perro blanco", document: "white dog"), 0.5)
        expectGreater(SearchText.lexicalScore(query: "playa", document: "beach ocean"), 0)
        expectEqual(SearchText.englishQuery("amarillo"), "amarillo")
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        expectEqual(SearchText.matchingYear("el año pasado playa", now: now), 2025)
        expectEqual(SearchText.matchingYear("this year beach", now: now), 2026)
        expectEqual(SearchText.contentQuery("el año pasado playa"), "playa")
    }
    @Test func testMemorySelectionPrefersAnniversariesAndSkipsFuture() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21))!
        var a = item("anniversary"); a.date = calendar.date(from: DateComponents(year: 2024, month: 10, day: 18))!; a.digest = "same"
        var copy = a; copy.id = "copy"; copy.path = "/copy.jpg"
        var month = item("month"); month.date = calendar.date(from: DateComponents(year: 2025, month: 10, day: 2))!
        var future = item("future"); future.date = calendar.date(from: DateComponents(year: 2027, month: 10, day: 18))!
        let (kind, chosen) = MemorySelection.select([a, copy, month, future], now: now)
        expectEqual(kind, "anniversary"); expectEqual(chosen.count, 1); expectEqual(chosen[0].digest, "same")
        let fallback = MemorySelection.select([month, future], now: now)
        expectEqual(fallback.0, "month"); expectEqual(fallback.1.map(\.id), ["month"])
    }
    @Test func testDailyMemoryScheduleAndOncePerDayPolicy() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 20, minute: 29))!
        let due = before.addingTimeInterval(60)
        var prefs = MemoryPreferences()
        expectTrue(!MemorySelection.due(prefs, now: before, calendar: calendar))
        expectTrue(MemorySelection.due(prefs, now: due, calendar: calendar))
        prefs.lastDay = MemorySelection.dayKey(due, calendar: calendar)
        expectTrue(!MemorySelection.due(prefs, now: due.addingTimeInterval(600), calendar: calendar))
        prefs.lastDay = nil; prefs.enabled = false
        expectTrue(!MemorySelection.due(prefs, now: due, calendar: calendar))
        let config = DailyMemorySchedule.configuration(executable: "/Applications/LumaTrace.app/Contents/MacOS/LumaTrace", settings: prefs)
        expectEqual(config["ProgramArguments"] as? [String], ["/Applications/LumaTrace.app/Contents/MacOS/LumaTrace", "--generate-memories"])
        expectEqual((config["StartCalendarInterval"] as? [String: Int])?["Hour"], 20)
        expectEqual((config["StartCalendarInterval"] as? [String: Int])?["Minute"], 30)
        expectNil(config["RunAtLoad"])
    }
    @Test func testWeeklyMemoryScheduleOnlyRunsOnSelectedDaysAndPreservesLegacyDefaults() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var prefs = MemoryPreferences(); prefs.repeatMode = "weekly"; prefs.weekdays = [2, 4] // Monday and Wednesday
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 20, minute: 30))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 21))!
        let wednesdayBefore = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 20, minute: 29))!
        let wednesday = wednesdayBefore.addingTimeInterval(60)
        expectTrue(MemorySelection.due(prefs, now: monday, calendar: calendar))
        expectTrue(!MemorySelection.due(prefs, now: tuesday, calendar: calendar))
        expectTrue(!MemorySelection.due(prefs, now: wednesdayBefore, calendar: calendar))
        expectTrue(MemorySelection.due(prefs, now: wednesday, calendar: calendar))
        let config = DailyMemorySchedule.configuration(executable: "/tmp/LumaTrace", settings: prefs)
        let intervals = config["StartCalendarInterval"] as? [[String: Int]]
        expectEqual(intervals?.map { $0["Weekday"] ?? -1 }, [1, 3]) // launchd: Sunday = 0
        expectTrue(intervals?.allSatisfy { $0["Hour"] == 20 && $0["Minute"] == 30 } == true)
        let legacy = try JSONDecoder().decode(MemoryPreferences.self, from: Data(#"{"enabled":true,"hour":18,"minute":15,"notifications":false}"#.utf8))
        expectEqual(legacy.repeatMode, "daily"); expectEqual(legacy.weekdays, Set(1...7))
    }
    @Test func testExistingLibraryGainsMemoryDefaultsWithoutLosingContent() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LibraryState(items: [item()]))) as! [String: Any]
        json.removeValue(forKey: "memories"); json.removeValue(forKey: "memoryPreferences")
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONSerialization.data(withJSONObject: json))
        expectEqual(restored.items.count, 1); expectTrue(restored.memoryPreferences.enabled); expectEqual(restored.memoryPreferences.hour, 20); expectEqual(restored.memoryPreferences.minute, 30)
    }
    @Test func testMemoryFilmActuallyEncodesPlayableVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var media: [MediaItem] = []
        for index in 0..<2 {
            let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: Double(index) * 0.5, green: 0.4, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            let photo = dir.appendingPathComponent("source-\(index).jpg")
            let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, context.makeImage()!, nil); expectTrue(CGImageDestinationFinalize(dest))
            let values = try photo.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            var image = item("memory-\(index)"); image.path = photo.path; image.modified = values.contentModificationDate!; image.bytes = Int64(values.fileSize!)
            image.date = Calendar.current.date(from: DateComponents(year: 2024 + index, month: 10, day: 18))!
            media.append(image)
        }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21))!
        let built = try await MemoryBuilder().build(items: media, now: now, language: .es, directory: dir.appendingPathComponent("films"))
        let reel = try #require(built)
        expectEqual(reel.kind, "anniversary"); expectEqual(reel.itemIDs.count, 2)
        let asset = AVURLAsset(url: URL(fileURLWithPath: reel.path))
        let duration = try await asset.load(.duration).seconds
        expectTrue(abs(duration - 6) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        expectEqual(size.width, 1280); expectEqual(size.height, 720)
        expectTrue(media.allSatisfy(\.isCurrentOnDisk))
    }
    @Test func testManuallyAssignedPlaceLabelSurvivesLibraryRoundTrip() throws {
        var media = item("place-label")
        media.latitude = 48.8566; media.longitude = 2.3522; media.placeLabel = "Paris, France"
        let data = try JSONEncoder().encode(media)
        let restored = try JSONDecoder().decode(MediaItem.self, from: data)
        expectEqual(restored.placeLabel, "Paris, France")
        expectEqual(restored.latitude, 48.8566)
        expectEqual(restored.longitude, 2.3522)
    }
    @Test func testOnlyOneWriterCanOpenLibraryAndLockReleases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var first: LibraryAccessLock? = try LibraryAccessLock(directory: dir)
        expectTrue(first != nil)
        var rejected = false
        do { _ = try LibraryAccessLock(directory: dir) } catch { rejected = true }
        expectTrue(rejected)
        first = nil
        let reopened = try LibraryAccessLock(directory: dir)
        withExtendedLifetime(reopened) { expectTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("writer.lock").path)) }
    }
    @Test func testEnglishWordsDoNotMatchUnrelatedSubstrings() {
        expectEqual(SearchText.lexicalScore(query: "cat", document: "education catalog"), 0)
        expectEqual(SearchText.lexicalScore(query: "sea", document: "season research"), 0)
        expectEqual(SearchText.lexicalScore(query: "cat", document: "domestic_cat"), 1)
        expectTrue(!SearchText.expanded(["education", "season"]).contains("猫"))
        expectTrue(!SearchText.expanded(["education", "season"]).contains("海"))
        expectTrue(SearchText.expanded(["domestic_cat"]).contains("猫"))
        expectEqual(SearchText.englishQuery("大海"), " ocean ")
    }
    @Test func testIndexMigrationKeepsOlderItems() throws {
        let old = item()
        let data = try JSONEncoder().encode(old)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["analyzedFrames", "companionBytes", "excludedTasks", "caption", "features"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        expectEqual(restored.path, old.path); expectEqual(restored.date, old.date)
        expectEqual(restored.analyzedFrames, 0); expectEqual(restored.excludedTasks, [])
    }
    @Test func testDisconnectedRootDoesNotBlockHealthyRoot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("ready.jpg")
        try Data("test".utf8).write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: photo.path)
        let analyzer = Analyzer()
        let result = try await analyzer.discover(roots: [dir.appendingPathComponent("missing-disk").path, dir.path])
        expectEqual(result.files.count, 1); expectEqual(result.warnings.count, 1)
        expectEqual(result.files.first?.url.path, photo.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86400)], ofItemAtPath: photo.path)
        let future = try await analyzer.discover(roots: [dir.path])
        expectEqual(future.files.count, 1)
    }
    @Test func testCameraPermissionResultCannotOutliveWindow() {
        var state = CameraLifecycle()
        let pendingPermission = state.begin()
        state.end()
        expectTrue(!state.accepts(pendingPermission))
        let reopened = state.begin()
        expectTrue(!state.accepts(pendingPermission))
        expectTrue(state.accepts(reopened))
    }
    @MainActor @Test func testManualTaskRemovalSurvivesReclassification() throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("测试必须指定独立资料库"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        defer { if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) } else { try? FileManager.default.removeItem(at: LibraryPaths.index) } }
        let store = LibraryStore(startMonitoring: false)
        var image = item(); image.keywords = ["cat"]
        store.state = LibraryState(items: [image])
        store.addRule(name: "宠物", keywords: "cat")
        expectTrue(store.state.items[0].tasks.contains("宠物"))
        store.toggleTask("宠物", item: store.state.items[0])
        store.addRule(name: "海边", keywords: "beach")
        expectTrue(!store.state.items[0].tasks.contains("宠物"))
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
        expectTrue(saved.items[0].excludedTasks.contains("宠物"))
    }
    @Test func testSidecarCannotFoldVideoStillBeingWritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("a.jpg"), movie = dir.appendingPathComponent("a.mov")
        try Data().write(to: photo); try Data().write(to: movie)
        try JSONSerialization.data(withJSONObject: ["video": "a.mov"]).write(to: dir.appendingPathComponent("a.shiguang.json"))
        let result = try await Analyzer().pairing([ScanFile(url: photo, modified: .distantPast, bytes: 0)])
        expectTrue(result.isEmpty)
    }
    @Test func testMissingOrModifiedFilesCannotReceiveKeepRecommendations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("file.jpg")
        try Data("original".utf8).write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        var image = item(); image.path = url.path; image.modified = values.contentModificationDate!; image.bytes = Int64(values.fileSize!)
        expectTrue(image.isCurrentOnDisk)
        try Data("changed-content".utf8).write(to: url)
        expectTrue(!image.isCurrentOnDisk)
        try FileManager.default.removeItem(at: url)
        expectTrue(!image.isCurrentOnDisk)
    }
    @Test func testVideoSamplingAndEveryFrameModes() async throws {
        try LibraryPaths.prepare()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<6 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)); if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) } }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 20 + index * 15, y: 50, width: 80, height: 80))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            expectTrue(adapter.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 3)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        await writer.finishWriting()
        expectEqual(writer.status, .completed)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let file = ScanFile(url: url, modified: values.contentModificationDate!, bytes: Int64(values.fileSize!))
        let analyzer = Analyzer()
        let sampled = try await analyzer.analyze(file, companion: nil, deep: false, localModel: false, model: "", previous: nil)
        expectEqual(sampled.kind, "video"); expectEqual(sampled.analyzedFrames, 1)
        expectEqual(sampled.width, 240); expectEqual(sampled.height, 320)
        let updates = ScanUpdates()
        let deep = try await analyzer.analyze(file, companion: nil, deep: true, localModel: false, model: "", previous: nil, report: { await updates.append($0) })
        let events = await updates.snapshot()
        expectTrue(events.contains { $0.stage == .hashing && $0.path == file.url.path })
        let videoEvents = events.filter { $0.stage == .video && $0.fraction != nil }
        expectTrue(videoEvents.contains { ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1 })
        expectEqual(videoEvents.last?.fraction, 1)
        expectTrue(videoEvents.allSatisfy { $0.path == file.url.path })
        expectTrue(videoEvents.last?.detail.contains("6") == true)
        expectEqual(deep.analyzedFrames, 6)
        expectEqual(deep.frames.count, 1)
        expectEqual(deep.frames.first?.second, 0)
        expectTrue(!deep.features.isEmpty)
        // Pair a still with this real synthetic movie and verify the video remains searchable after folding.
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let photo = folder.appendingPathComponent("live.jpg")
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil); expectTrue(CGImageDestinationFinalize(dest))
        let photoValues = try photo.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let live = try await analyzer.analyze(ScanFile(url: photo, modified: photoValues.contentModificationDate!, bytes: Int64(photoValues.fileSize!)), companion: url.path, deep: false, localModel: false, model: "", previous: nil)
        expectTrue(live.isMotion); expectTrue(!live.frames.isEmpty); expectGreater(live.duration, 0)
        expectTrue(live.companionHash != nil); expectEqual(live.companionBytes, file.bytes)
        try? FileManager.default.removeItem(at: LibraryPaths.thumbnail(live.id))
        try? FileManager.default.removeItem(at: LibraryPaths.thumbnail(deep.id))
    }
    @Test func testOfflineVisionImagePipeline() async throws {
        try LibraryPaths.prepare()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 640, height: 480))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 480)).fill()
        NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: NSRect(x: 40, y: 40, width: 150, height: 150)).fill()
        ("SUMMER 2026" as NSString).draw(at: NSPoint(x: 100, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let url = folder.appendingPathComponent("test.jpg")
        try rep.representation(using: .jpeg, properties: [:])!.write(to: url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let analyzer = Analyzer()
        let result = try await analyzer.analyze(ScanFile(url: url, modified: values.contentModificationDate!, bytes: Int64(values.fileSize!)), companion: nil, deep: false, localModel: false, model: "", previous: nil)
        expectEqual(result.width, rep.pixelsWide); expectEqual(result.height, rep.pixelsHigh)
        expectEqual(result.features.count, 1)
        expectTrue(result.recognizedText.contains("2026"))
        expectTrue(FileManager.default.fileExists(atPath: LibraryPaths.thumbnail(result.id).path))
        var copy = result; copy.id = "copy"; copy.path = "/fixtures/copy.jpg"
        var recompressed = result; recompressed.id = "compressed"; recompressed.path = "/fixtures/compressed.jpg"; recompressed.digest = "another-encoding"
        let groups = try await analyzer.duplicates([result, copy, recompressed])
        expectEqual(groups.filter(\.exact).count, 1)
        expectEqual(groups.filter { !$0.exact }.count, 1)
        expectTrue(groups.contains { !$0.exact && $0.items.contains { $0.id == "compressed" } })
        try? FileManager.default.removeItem(at: LibraryPaths.thumbnail(result.id))
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a == b) }
private func expectNotEqual<T: Equatable>(_ a: T, _ b: T) { #expect(a != b) }
private func expectGreater<T: Comparable>(_ a: T, _ b: T) { #expect(a > b) }
private func expectTrue(_ value: Bool) { #expect(value) }
private func expectNil<T>(_ value: T?) { #expect(value == nil) }
