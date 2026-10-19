import Foundation
import Darwin
import AppKit
import AVFoundation
import ImageIO
import CoreText
import UserNotifications

private final class AssetExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

struct MemoryPreferences: Codable, Sendable {
    var enabled = true
    var hour = 20
    var minute = 30
    var repeatMode = "daily"
    // Calendar weekday numbering: Sunday = 1 through Saturday = 7.
    var weekdays = Set(1...7)
    var notifications = false
    var lastDay: String?

    private enum CodingKeys: String, CodingKey { case enabled, hour, minute, repeatMode, weekdays, notifications, lastDay }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hour = min(23, max(0, try values.decodeIfPresent(Int.self, forKey: .hour) ?? 20))
        minute = min(59, max(0, try values.decodeIfPresent(Int.self, forKey: .minute) ?? 30))
        repeatMode = try values.decodeIfPresent(String.self, forKey: .repeatMode) == "weekly" ? "weekly" : "daily"
        let decodedDays = Set((try values.decodeIfPresent([Int].self, forKey: .weekdays) ?? Array(1...7)).filter { (1...7).contains($0) })
        weekdays = decodedDays.isEmpty ? Set(1...7) : decodedDays
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? false
        lastDay = try values.decodeIfPresent(String.self, forKey: .lastDay)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(hour, forKey: .hour)
        try values.encode(minute, forKey: .minute)
        try values.encode(repeatMode, forKey: .repeatMode)
        try values.encode(weekdays.sorted(), forKey: .weekdays)
        try values.encode(notifications, forKey: .notifications)
        try values.encodeIfPresent(lastDay, forKey: .lastDay)
    }
}
struct MemoryReel: Codable, Identifiable, Sendable {
    var id: String
    var created: Date
    var kind: String
    var itemIDs: [String]
    var path: String
    var from: Date
    var to: Date
    var customTitle: String? = nil
    var title: String { customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? customTitle! : tr(kind == "anniversary" ? "往年今日" : kind == "month" ? "这个月的记忆" : "时光片段") }
}
enum MemorySelection {
    static func custom(_ items: [MediaItem], selectedIDs: Set<String>) -> [MediaItem] {
        items.filter { $0.isCurrentOnDisk && selectedIDs.contains($0.id) }.sorted { $0.date < $1.date }
    }
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    static func due(_ settings: MemoryPreferences, now: Date, calendar: Calendar = .current) -> Bool {
        guard settings.enabled, settings.lastDay != dayKey(now, calendar: calendar) else { return false }
        if settings.repeatMode == "weekly", !settings.weekdays.contains(calendar.component(.weekday, from: now)) { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= settings.hour * 60 + settings.minute
    }
    static func select(_ items: [MediaItem], now: Date, calendar: Calendar = .current) -> (String, [MediaItem]) {
        let today = calendar.startOfDay(for: now)
        let parts = calendar.dateComponents([.month, .day], from: now)
        let past = items.filter { $0.error == nil && $0.date < today }
        var choices = past.filter {
            let p = calendar.dateComponents([.month, .day], from: $0.date)
            return p.month == parts.month && p.day == parts.day
        }
        var kind = "anniversary"
        if choices.isEmpty { kind = "month"; choices = past.filter { calendar.component(.month, from: $0.date) == parts.month } }
        if choices.isEmpty { kind = "timeline"; choices = past }
        // Prefer quality within each exact-content group, then spread the selection across time.
        var seen = Set<String>()
        choices = choices.sorted { DuplicatePolicy.rank($0) > DuplicatePolicy.rank($1) }.filter {
            seen.insert(DuplicatePolicy.exactKey($0) ?? $0.id).inserted
        }.sorted { $0.date < $1.date }
        if choices.count > 8 {
            let shift = (calendar.ordinality(of: .day, in: .year, for: now) ?? 0) % choices.count
            let rotated = Array(choices[shift...]) + Array(choices[..<shift])
            choices = (0..<8).map { rotated[$0 * rotated.count / 8] }.sorted { $0.date < $1.date }
        }
        return (kind, choices)
    }
}
actor MemoryBuilder {
    func build(items: [MediaItem], selectedIDs: Set<String>? = nil, title: String? = nil, now: Date = Date(), language: AppLanguage = Localization.language, directory: URL = LibraryPaths.memories) async throws -> MemoryReel? {
        let available = items.filter(\.isCurrentOnDisk)
        let kind: String
        let chosen: [MediaItem]
        if let selectedIDs {
            kind = "custom"
            chosen = MemorySelection.custom(available, selectedIDs: selectedIDs)
        } else {
            (kind, chosen) = MemorySelection.select(available, now: now)
        }
        guard !chosen.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let target = directory.appendingPathComponent("LumaTrace-Memory-\(MemorySelection.dayKey(now))-\(id).mp4")
        let temporary = directory.appendingPathComponent(".\(id).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let width = 1280, height = 720, fps: Int32 = 12, framesPerItem = 36
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw failure("无法创建回忆影片") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? failure("无法创建回忆影片") }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var frameIndex: Int64 = 0
        let formatter = DateFormatter(); formatter.locale = language.locale; formatter.dateStyle = .long
        for item in chosen {
            try Task.checkCancellation()
            let videoPath = item.companion ?? (item.isVideo ? item.path : nil)
            var generator: AVAssetImageGenerator?
            var duration: Double = 0
            if let videoPath {
                let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
                duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw failure("回忆素材的视频无法读取") }
                let g = AVAssetImageGenerator(asset: asset); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: width, height: height)
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero; generator = g
            }
            let still: CGImage?
            if generator == nil {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { throw failure("回忆素材的图片无法读取") }
                still = image
            } else { still = nil }
            for offset in 0..<framesPerItem {
                try Task.checkCancellation()
                let deadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing, Date() < deadline else { throw writer.error ?? failure("回忆影片编码超时") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try autoreleasepool {
                    let image: CGImage
                    if let generator {
                        let second = min(max(0, duration - 1 / Double(fps)), max(0, duration / 2 - 1.5) + Double(offset) / Double(fps))
                        image = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
                    } else if let still { image = still } else { throw failure("回忆素材的图片无法读取") }
                    var buffer: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw failure("无法创建回忆影片画面") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw failure("无法创建回忆影片画面") }
                    context.setFillColor(CGColor(red: 0.96, green: 0.98, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    let available = CGRect(x: 40, y: 72, width: 1200, height: 608)
                    let scale = min(available.width / Double(image.width), available.height / Double(image.height))
                    let rect = CGRect(x: available.midX - Double(image.width) * scale / 2, y: available.midY - Double(image.height) * scale / 2, width: Double(image.width) * scale, height: Double(image.height) * scale)
                    context.interpolationQuality = .high; context.draw(image, in: rect)
                    let dateLine = CTLineCreateWithAttributedString(NSAttributedString(string: formatter.string(from: item.date), attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor(red: 0.14, green: 0.42, blue: 0.99, alpha: 1)]))
                    context.textPosition = CGPoint(x: 40, y: 30); CTLineDraw(dateLine, context)
                    let brand = CTLineCreateWithAttributedString(NSAttributedString(string: "LUNA ULTRA", attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.82)]))
                    let brandWidth = CTLineGetTypographicBounds(brand, nil, nil, nil)
                    let badge = CGRect(x: 1230 - brandWidth, y: 20, width: brandWidth + 22, height: 32)
                    context.setFillColor(NSColor(white: 0.05, alpha: 0.56).cgColor)
                    context.addPath(CGPath(roundedRect: badge, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.fillPath()
                    context.textPosition = CGPoint(x: badge.minX + 11, y: 30); CTLineDraw(brand, context)
                    guard adaptor.append(buffer, withPresentationTime: CMTime(value: frameIndex, timescale: fps)) else { throw writer.error ?? failure("回忆影片写入失败") }
                }
                frameIndex += 1
                await Task.yield()
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: frameIndex, timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? failure("回忆影片写入失败") }
        do {
            try await MemoryMusic.mux(video: temporary, to: target, seed: chosen.map(\.searchableText).joined(separator: " ").hashValue)
        } catch {
            // Keep a usable silent memory if this Mac cannot export the optional soundtrack.
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("music-fallback.log"), options: .atomic)
        }
        return MemoryReel(id: id, created: now, kind: kind, itemIDs: chosen.map(\.id), path: target.path, from: chosen.first!.date, to: chosen.last!.date, customTitle: title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title?.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "TimeImprint", code: 5, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private enum MemoryMusic {
    private static let sampleRate = 22_050
    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func soundtrack(seconds: Double, seed: Int) -> Data {
        let frames = max(1, Int(seconds * Double(sampleRate)))
        var pcm = Data(capacity: frames * 2)
        let progressions: [[Int]] = [[0, 4, 7, 11], [9, 0, 4, 7], [5, 9, 0, 4], [7, 11, 2, 5]]
        let progression = abs(seed % 4)
        for frame in 0..<frames {
            let t = Double(frame) / Double(sampleRate)
            let bar = Int(t / 3) % 4
            let chord = progressions[(bar + progression) % progressions.count]
            var sample = 0.0
            for (index, semitone) in chord.enumerated() {
                let frequency = 130.81 * pow(2, Double(semitone) / 12)
                sample += sin(2 * .pi * frequency * t + Double(index) * 0.12) * 0.045
                sample += sin(2 * .pi * frequency * 2 * t) * 0.009
            }
            let beat = t.truncatingRemainder(dividingBy: 1.5)
            let noteIndex = (Int(t / 1.5) + progression) % 4
            let melodyFrequency = 261.63 * pow(2, Double(chord[noteIndex]) / 12)
            let pluck = exp(-beat * 2.8) * sin(2 * .pi * melodyFrequency * beat)
            sample += pluck * 0.075
            let fade = min(1.0, min(t / 1.2, max(0, (seconds - t) / 1.5)))
            let value = Int16(max(-1, min(1, sample * fade)) * 32767)
            appendLE(value, to: &pcm)
        }
        var wav = Data(); wav.append(contentsOf: Array("RIFF".utf8)); appendLE(UInt32(36 + pcm.count), to: &wav)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); appendLE(UInt32(16), to: &wav); appendLE(UInt16(1), to: &wav)
        appendLE(UInt16(1), to: &wav); appendLE(UInt32(sampleRate), to: &wav); appendLE(UInt32(sampleRate * 2), to: &wav)
        appendLE(UInt16(2), to: &wav); appendLE(UInt16(16), to: &wav); wav.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(pcm.count), to: &wav); wav.append(pcm); return wav
    }
    static func mux(video: URL, to output: URL, seed: Int) async throws {
        let source = AVURLAsset(url: video)
        let duration = try await source.load(.duration)
        let sourceAudio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let compressedAudio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: sourceAudio); try? FileManager.default.removeItem(at: compressedAudio) }
        let music = soundtrack(seconds: max(2, duration.seconds), seed: seed)
        try music.write(to: sourceAudio, options: .atomic)
        try await exportAudio(source: sourceAudio, destination: compressedAudio)
        let composition = AVMutableComposition()
        guard let videoIn = try await source.loadTracks(withMediaType: .video).first,
              let videoOut = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let musicIn = try await AVURLAsset(url: compressedAudio).loadTracks(withMediaType: .audio).first,
              let musicOut = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "TimeImprintMusic", code: 1)
        }
        try videoOut.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoIn, at: .zero)
        let musicAsset = AVURLAsset(url: compressedAudio)
        let musicDuration = try await musicAsset.load(.duration)
        let musicRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, musicDuration))
        try musicOut.insertTimeRange(musicRange, of: musicIn, at: .zero)
        if let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) {
            exporter.outputURL = output; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
            let sessionBox = AssetExportSessionBox(exporter)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionBox.session.exportAsynchronously {
                    if sessionBox.session.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: sessionBox.session.error ?? NSError(domain: "TimeImprintMusic", code: Int(sessionBox.session.status.rawValue))) }
                }
            }
        } else { throw NSError(domain: "TimeImprintMusic", code: 2) }
    }
    private static func exportAudio(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "TimeImprintMusic", code: 3)
        }
        exporter.outputURL = destination; exporter.outputFileType = .m4a
        let sessionBox = AssetExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionBox.session.exportAsynchronously {
                if sessionBox.session.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: sessionBox.session.error ?? NSError(domain: "TimeImprintMusic", code: 4)) }
            }
        }
    }
}

enum DailyMemorySchedule {
    static let label = "local.shiguang.memories"
    static func configuration(executable: String, settings: MemoryPreferences) -> [String: Any] {
        let hour = min(23, max(0, settings.hour)), minute = min(59, max(0, settings.minute))
        let schedule: Any
        if settings.repeatMode == "weekly" {
            let days = settings.weekdays.isEmpty ? Set(1...7) : settings.weekdays
            schedule = days.sorted().map { ["Weekday": $0 - 1, "Hour": hour, "Minute": minute] }
        } else {
            schedule = ["Hour": hour, "Minute": minute]
        }
        return ["Label": label, "ProgramArguments": [executable, "--generate-memories"], "StartCalendarInterval": schedule, "ProcessType": "Background", "LimitLoadToSessionType": "Aqua"]
    }
    static func sync(_ settings: MemoryPreferences) throws {
        guard let executable = Bundle.main.executableURL?.path, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plist = directory.appendingPathComponent(label + ".plist")
        let domain = "gui/\(getuid())"
        func launchctl(_ args: [String]) throws -> Int32 {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        _ = try launchctl(["bootout", domain + "/" + label])
        if settings.enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: configuration(executable: executable, settings: settings), format: .xml, options: 0).write(to: plist, options: .atomic)
            let result = try launchctl(["bootstrap", domain, plist.path])
            guard result == 0 else { throw NSError(domain: "TimeImprint", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "定时任务注册失败；应用打开期间仍会按设置生成回忆。"] ) }
        } else if FileManager.default.fileExists(atPath: plist.path) { try FileManager.default.removeItem(at: plist) }
    }
}

enum MemoryNotification {
    static func notificationContent(for reel: MemoryReel) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = AppBrand.name
        content.subtitle = tr("时光穿梭")
        content.body = reel.title + " · " + tr("新的回忆影片已准备好")
        return content
    }
    static func deliver(_ reel: MemoryReel) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        try? await center.add(UNNotificationRequest(identifier: reel.id, content: notificationContent(for: reel), trigger: nil))
    }
}
@MainActor enum MemoryBackground {
    static func run() async {
        do {
            try LibraryPaths.prepare()
            let lock = try LibraryAccessLock(directory: LibraryPaths.base)
            var state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: LibraryPaths.index))
            guard MemorySelection.due(state.memoryPreferences, now: Date()) else { return }
            let reel = try await MemoryBuilder().build(items: state.items)
            if let reel { state.memories.insert(reel, at: 0) }
            state.memoryPreferences.lastDay = MemorySelection.dayKey(Date())
            try JSONEncoder().encode(state).write(to: LibraryPaths.index, options: .atomic)
            if let reel, state.memoryPreferences.notifications { await MemoryNotification.deliver(reel) }
            withExtendedLifetime(lock) {}
        } catch { try? Data(error.localizedDescription.utf8).write(to: LibraryPaths.base.appendingPathComponent("memory-error.log"), options: .atomic) }
    }
}

actor MemoryScheduleCoordinator {
    static let shared = MemoryScheduleCoordinator()
    func sync(_ preferences: MemoryPreferences) throws { try DailyMemorySchedule.sync(preferences) }
}
