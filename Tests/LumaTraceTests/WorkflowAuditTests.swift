import Foundation
import Combine
import Testing
import CoreGraphics
import ImageIO
@testable import LumaTrace

// Run this suite separately from LibraryTests: both intentionally exercise the
// single-writer library and must not mutate its isolated test index concurrently.
@Suite(.serialized) struct WorkflowAuditTests {
    @MainActor @Test func changingWatchedFoldersAndSettingsDuringWorkPreservesUserControl() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else {
            Issue.record("Specify LUMATRACE_LIBRARY pointing to an isolated test directory"); return
        }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumatrace-audit-" + UUID().uuidString)
        let first = folder.appendingPathComponent("First"), second = folder.appendingPathComponent("Second")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer {
            try? FileManager.default.removeItem(at: folder)
            if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: LibraryPaths.index) }
        }
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        #expect(!store.isReadOnly)
        store.addRoots([first, second], startScan: false)
        var retained = MediaItem(id: "retained-audit-item", path: first.appendingPathComponent("original.jpg").path, modified: .distantPast, bytes: 8, kind: "image", date: .distantPast, dateSource: "文件修改时间")
        retained.tasks = ["Keep my collection"]
        store.state.items = [retained]
        try Data("original".utf8).write(to: URL(fileURLWithPath: retained.path))

        store.scan()
        #expect(store.busy)
        store.removeRoot(first.path)
        #expect(store.state.roots == [second.path])
        #expect(store.state.items.contains { $0.id == retained.id && $0.tasks == retained.tasks })
        try await waitUntilIdle(store)
        #expect(store.state.roots == [second.path])
        #expect(FileManager.default.fileExists(atPath: retained.path))

        store.addRoots([first], startScan: false)
        store.scan(); store.pauseAnalysis()
        #expect(store.analysisPhase == .paused)
        store.setDeepVideo(true)
        store.setLocalModelEnabled(true)
        store.removeRoot(first.path)
        try await waitUntilIdle(store)
        #expect(store.monitoringPaused)
        #expect(store.state.deepVideo && store.state.useLocalModel)
        #expect(store.canStartAnalysis)
        #expect(!store.busy)
        let persisted = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
        #expect(persisted.roots == [second.path])
        #expect(persisted.deepVideo && persisted.useLocalModel)

        store.startAnalysis()
        store.removeRoot(second.path)
        try await waitUntilIdle(store)
        #expect(store.state.roots.isEmpty)
        #expect(store.monitoringPaused)
        #expect(!store.canStartAnalysis)
        #expect(store.state.items.contains { $0.id == retained.id })
        #expect(FileManager.default.fileExists(atPath: retained.path))
        // Enabling the optional model starts an asynchronous connection check.
        // Let it release this store's writer before the next library fixture opens.
        let modelDeadline = Date().addingTimeInterval(10)
        while store.modelCheckBusy, Date() < modelDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.modelCheckBusy, "The optional model check must settle and release the test store")
    }

    @MainActor @Test func changingVideoModeInvalidatesACompletedCacheWithoutForceRescan() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else {
            Issue.record("Specify an isolated test library"); return
        }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumatrace-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("intentionally-invalid-video.mov")
        try Data("This fixture must fail only when actually decoded".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let analyzer = Analyzer(), id = analyzer.identifier(url.path)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: LibraryPaths.thumbnail(id))
            if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: LibraryPaths.index) }
        }
        var cached = MediaItem(id: id, path: url.path, modified: try #require(values.contentModificationDate), bytes: Int64(try #require(values.fileSize)), kind: "video", date: .distantPast, dateSource: "文件修改时间")
        cached.digest = "previously-verified-content"
        cached.analysisProfile = AnalysisProfile.key(video: true, deep: false, localModel: false, model: "")
        cached.analyzedFrames = 777
        try Data("existing-thumbnail-cache".utf8).write(to: LibraryPaths.thumbnail(id))
        var initial = LibraryState(); initial.roots = [folder.path]; initial.items = [cached]
        try JSONEncoder().encode(initial).write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        #expect(!store.isReadOnly)
        store.scan(); try await waitUntilIdle(store)
        #expect(store.state.items.first?.error == nil)
        #expect(store.state.items.first?.analyzedFrames == 777)
        store.setDeepVideo(true)
        store.scan(); try await waitUntilIdle(store)
        #expect(store.state.items.first?.error != nil, "A different video mode must decode the file instead of silently accepting the old sampled cache")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor @Test func completedAssetsAppearInSearchWhileTheRestOfScanIsPaused() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else { Issue.record("Use isolated library"); return }
        try LibraryPaths.prepare()
        let backup = try? Data(contentsOf: LibraryPaths.index)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            if let backup { try? backup.write(to: LibraryPaths.index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: LibraryPaths.index) }
        }
        let context = try #require(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        for name in ["a_beach.jpg", "z_second.jpg"] {
            let url = folder.appendingPathComponent(name)
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: url.path)
        }
        try JSONEncoder().encode(LibraryState()).write(to: LibraryPaths.index, options: .atomic)
        let store = LibraryStore(startMonitoring: false)
        store.addRoots([folder], startScan: false); store.query = "beach"
        let subscription = store.$state.sink { [weak store] snapshot in
            guard let store, store.analysisPhase == .running, snapshot.items.contains(where: { $0.name == "a_beach.jpg" }) else { return }
            store.pauseAnalysis()
        }
        defer { subscription.cancel() }
        store.startAnalysis()
        let deadline = Date().addingTimeInterval(10)
        while store.analysisPhase != .paused, store.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.busy && store.analysisPhase == .paused)
        while store.searching, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.visible.contains { $0.name == "a_beach.jpg" })
        #expect(store.state.items.count == 1)
        store.stop(); try await waitUntilIdle(store)
        subscription.cancel()
    }

    @Test func mapLocationsRejectInvalidCoordinatesAndKeepAllPhotosInACluster() {
        func image(_ id: String, _ latitude: Double?, _ longitude: Double?) -> MediaItem {
            var item = MediaItem(id: id, path: "/isolated/" + id + ".jpg", modified: .distantPast, bytes: 1, kind: "image", date: Date(timeIntervalSince1970: id == "newer" ? 20 : 10), dateSource: "拍摄时间")
            item.latitude = latitude; item.longitude = longitude
            return item
        }
        let valid = [image("older", 48.8566, 2.3522), image("newer", 48.8566, 2.3522), image("nearby", 48.8569, 2.3525), image("other", -33.8688, 151.2093), image("edge", -90, 180)]
        let invalid = [image("missing", nil, nil), image("missing-longitude", 20, nil), image("nan", .nan, 0), image("infinite", 0, .infinity), image("latitude", 90.01, 0), image("longitude", 0, -180.01)]
        #expect(valid.allSatisfy(PhotoLocations.valid))
        #expect(invalid.allSatisfy { !PhotoLocations.valid($0) })
        let grouped = PhotoLocations.groups(valid + invalid)
        #expect(grouped.count == 4)
        #expect(Set(grouped.flatMap { $0.items.map(\.id) }) == Set(valid.map(\.id)))
        let paris = grouped.first { $0.items.count == 2 }
        #expect(paris?.items.map(\.id) == ["newer", "older"])
        #expect(paris?.latitude == 48.8566 && paris?.longitude == 2.3522)
        let zoomedOut = PhotoLocations.groups(valid, zoomLevel: 6)
        let zoomedIn = PhotoLocations.groups(valid, zoomLevel: 18)
        #expect(zoomedOut.count < zoomedIn.count)
        #expect(zoomedOut.flatMap(\.items).count == zoomedIn.flatMap(\.items).count)
    }

    @Test func localModelDetectionParsesInstalledNamesAndRejectsTextOnlyAndCloudModels() throws {
        let tags = Data(#"{"models":[{"name":"vision-b:3b"},{"name":"vision-a:7b"}],"ignored":"compatible extra field"}"#.utf8)
        #expect(try LocalModelClient.modelNames(tags) == ["vision-a:7b", "vision-b:3b"])
        #expect(try LocalModelClient.modelNames(Data(#"{"models":[]}"#.utf8)).isEmpty)
        #expect(throws: (any Error).self) { try LocalModelClient.modelNames(Data("not JSON".utf8)) }
        try LocalModelClient.validate(.init(capabilities: ["completion", "vision"], remote_host: nil, remote_model: nil), model: "local-vision:3b")
        #expect(throws: (any Error).self) { try LocalModelClient.validate(.init(capabilities: ["completion"], remote_host: nil, remote_model: nil), model: "text:3b") }
        #expect(throws: (any Error).self) { try LocalModelClient.validate(.init(capabilities: nil, remote_host: nil, remote_model: nil), model: "unknown") }
        #expect(throws: (any Error).self) { try LocalModelClient.validate(.init(capabilities: ["vision"], remote_host: "https://remote.invalid", remote_model: nil), model: "vision") }
        #expect(throws: (any Error).self) { try LocalModelClient.validate(.init(capabilities: ["vision"], remote_host: nil, remote_model: "remote-vision"), model: "vision") }
        #expect(throws: (any Error).self) { try LocalModelClient.validate(.init(capabilities: ["vision"], remote_host: nil, remote_model: nil), model: "vision:cloud") }
    }

    @Test func analysisProfileDistinguishesVideoModesModelsAndLegacyRecords() throws {
        let base = AnalysisProfile.key(video: true, deep: false, localModel: false, model: "ignored")
        #expect(base == AnalysisProfile.legacy)
        #expect(base != AnalysisProfile.key(video: true, deep: true, localModel: false, model: "ignored"))
        #expect(base != AnalysisProfile.key(video: true, deep: false, localModel: true, model: "qwen2.5vl:3b"))
        #expect(AnalysisProfile.key(video: false, deep: false, localModel: true, model: "model-a") != AnalysisProfile.key(video: false, deep: false, localModel: true, model: "model-b"))
        // Changing video sampling should not wastefully reprocess ordinary stills.
        #expect(AnalysisProfile.key(video: false, deep: false, localModel: false, model: "a") == AnalysisProfile.key(video: false, deep: true, localModel: false, model: "b"))
        let image = MediaItem(id: "legacy", path: "/isolated/legacy.jpg", modified: .distantPast, bytes: 10, kind: "image", date: .distantPast, dateSource: "文件修改时间")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as! [String: Any]
        json.removeValue(forKey: "analysisProfile")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.analysisProfile == nil)
        #expect(decoded.path == image.path)
    }

    @Test func thumbnailPreviewArrivesBeforeAnalysisCompletesAndCancellationIsSafe() async throws {
        guard ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] != nil || ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] != nil else {
            Issue.record("Specify an isolated test library"); return
        }
        try LibraryPaths.prepare()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lumatrace-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.jpg")
        let context = try #require(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let file = ScanFile(url: url, modified: try #require(values.contentModificationDate), bytes: Int64(try #require(values.fileSize)))
        let analyzer = Analyzer(), latch = AuditPreviewLatch()
        let identifier = analyzer.identifier(url.path)
        defer { try? FileManager.default.removeItem(at: LibraryPaths.thumbnail(identifier)) }
        let task = Task {
            try await analyzer.analyze(file, companion: nil, deep: false, localModel: false, model: "", previous: nil, preview: { await latch.receive($0) })
        }
        defer { task.cancel(); Task { await latch.release() } }
        let deadline = Date().addingTimeInterval(10)
        while await latch.first == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let firstPreview = await latch.first
        let preview = try #require(firstPreview)
        #expect(preview.id == identifier)
        #expect(preview.width == 80 && preview.height == 60)
        #expect(preview.digest.isEmpty)
        #expect(FileManager.default.fileExists(atPath: LibraryPaths.thumbnail(identifier).path))
        task.cancel()
        await latch.release()
        do { _ = try await task.value; Issue.record("Cancelled analysis must not commit a completed asset") }
        catch is CancellationError {} catch { throw error }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor private func waitUntilIdle(_ store: LibraryStore) async throws {
        let deadline = Date().addingTimeInterval(10)
        while store.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!store.busy, "Scan cancellation or restart did not settle within ten seconds")
    }
}

private actor AuditPreviewLatch {
    private(set) var first: MediaItem?
    private var released = false
    func receive(_ item: MediaItem) async {
        if first == nil { first = item }
        while !released { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func release() { released = true }
}
