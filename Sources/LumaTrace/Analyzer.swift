import Foundation
import AppKit
import AVFoundation
import Vision
import ImageIO
import CryptoKit
import NaturalLanguage

enum ScanStage: String, Sendable {
    case discovering = "查找文件", pairing = "识别动态照片配对", hashing = "计算文件指纹", image = "识别照片内容", video = "分析视频", model = "生成增强描述", duplicates = "比较重复内容"
}
struct ScanUpdate: Sendable {
    var stage: ScanStage
    var path: String
    var fraction: Double? = nil
    var detail: String = ""
}
typealias ScanPreviewReporter = @Sendable (MediaItem) async -> Void
typealias ScanReporter = @Sendable (ScanUpdate) async -> Void

struct ScanFile {
    var url: URL
    var modified: Date
    var bytes: Int64
}
struct ScanListing {
    var files: [ScanFile]
    var warnings: [String]
}
struct VisualResult {
    var labels: [String]
    var text: String
    var feature: String?
    var sharpness: Double
}
// Shared scan gate pauses at safe boundaries without blocking search or the UI.
final class AnalysisGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    private func isPaused() -> Bool { lock.lock(); defer { lock.unlock() }; return paused }
    func checkpoint() async throws {
        try Task.checkCancellation()
        while isPaused() { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
    }
}
actor Analyzer {
    nonisolated let gate = AnalysisGate()
    private var englishEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    private var spanishEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .spanish)
    private var chineseEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
    private var searchVectors: [String: [Double]] = [:]
    static let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"])
    static let videoExtensions = Set(["mov", "mp4", "m4v", "avi", "mkv"])

    func discover(roots: [String], report: ScanReporter? = nil) async throws -> ScanListing {
        var found: [String: ScanFile] = [:], warnings: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        for root in roots {
            try await gate.checkpoint()
            await report?(ScanUpdate(stage: .discovering, path: root, detail: "已找到 \(found.count) 项影像"))
            var lastReport = Date.distantPast
            let rootURL = URL(fileURLWithPath: root)
            if rootURL.pathExtension.lowercased() == "photoslibrary" {
                warnings.append("系统照片资料库需先从照片 App 导出原片，再添加导出文件夹。"); continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                warnings.append("目录不可访问：\(root)。请检查磁盘和文件夹权限。")
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                if warnings.count < 50 { warnings.append("\(url.path)：\(error.localizedDescription)") }
                return true
            }) else { warnings.append("无法扫描目录：\(root)"); continue }
            while let entry = enumerator.nextObject() {
                guard let url = entry as? URL else { continue }
                try await gate.checkpoint()
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    await report?(ScanUpdate(stage: .discovering, path: url.deletingLastPathComponent().path, detail: "已找到 \(found.count) 项影像")); lastReport = Date()
                }
                if [LibraryPaths.cache.path, LibraryPaths.memories.path].contains(url.standardizedFileURL.path) { enumerator.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                if ext == "photoslibrary" { warnings.append("系统照片资料库需先从照片 App 导出原片，再添加导出文件夹。"); enumerator.skipDescendants(); continue }
                guard Self.imageExtensions.contains(ext) || Self.videoExtensions.contains(ext) else { continue }
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    guard values.isRegularFile == true else { continue }
                    let modified = values.contentModificationDate ?? .distantPast
                    let age = Date().timeIntervalSince(modified)
                    guard age < 0 || age > 3 else { continue }
                    found[url.standardizedFileURL.path] = ScanFile(url: url.standardizedFileURL, modified: modified, bytes: Int64(values.fileSize ?? 0))
                } catch { if warnings.count < 50 { warnings.append("\(url.path)：\(error.localizedDescription)") } }
            }
        }
        return ScanListing(files: found.values.sorted { $0.url.path < $1.url.path }, warnings: warnings)
    }
    nonisolated func identifier(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func userFacingError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain && ns.code == -11821 {
            return "HEVC 视频帧无法解码（AVFoundation -11821）。文件可读取，但系统无法提取画面；请检查源文件，必要时转换为 H.264 后再重试。"
        }
        return error.localizedDescription
    }
    func hash(_ url: URL, report: ScanReporter? = nil) async throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        let total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var read: Int64 = 0, lastReport = Date.distantPast
        await report?(ScanUpdate(stage: .hashing, path: url.path, fraction: 0))
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try await gate.checkpoint()
            digest.update(data: chunk); read += Int64(chunk.count)
            if Date().timeIntervalSince(lastReport) > 0.25 || read >= total {
                await report?(ScanUpdate(stage: .hashing, path: url.path, fraction: total > 0 ? min(1, Double(read) / Double(total)) : nil)); lastReport = Date()
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func imageContentID(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any], let maker = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] else { return nil }
        return maker["17"] as? String
    }
    func videoContentID(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for meta in metadata where meta.identifier?.rawValue.contains("content.identifier") == true {
            if let id = try? await meta.load(.stringValue) { return id }
        }
        return nil
    }
    func pairing(_ files: [ScanFile], report: ScanReporter? = nil) async throws -> [String: String] {
        var videos: [String: [String]] = [:]
        var lastReport = Date.distantPast
        var photoIDs: [String: String] = [:]
        for file in files where Self.imageExtensions.contains(file.url.pathExtension.lowercased()) {
            try await gate.checkpoint()
            if Date().timeIntervalSince(lastReport) > 0.25 {
                await report?(ScanUpdate(stage: .pairing, path: file.url.path)); lastReport = Date()
            }
            if let id = imageContentID(file.url) { photoIDs[file.url.path] = id }
        }
        // A Live Photo can only pair with a video beside its still image.
        // Ordinary video folders need no QuickTime metadata pass at all.
        let parents = Set(photoIDs.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
        for file in files where Self.videoExtensions.contains(file.url.pathExtension.lowercased()) && parents.contains(file.url.deletingLastPathComponent().path) {
            try await gate.checkpoint()
            if Date().timeIntervalSince(lastReport) > 0.25 {
                await report?(ScanUpdate(stage: .pairing, path: file.url.path)); lastReport = Date()
            }
            if let id = await videoContentID(file.url) { videos[id, default: []].append(file.url.path) }
        }
        let availableVideos = Set(files.filter { Self.videoExtensions.contains($0.url.pathExtension.lowercased()) }.map { $0.url.path })
        var result: [String: String] = [:]
        for file in files where Self.imageExtensions.contains(file.url.pathExtension.lowercased()) {
            try await gate.checkpoint()
            if Date().timeIntervalSince(lastReport) > 0.25 {
                await report?(ScanUpdate(stage: .pairing, path: file.url.path)); lastReport = Date()
            }
            if let id = photoIDs[file.url.path], let matches = videos[id] {
                // Prefer the video alongside this image; duplicate copies can share an identifier.
                let parent = file.url.deletingLastPathComponent().path
                let local = matches.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == parent }
                let stem = file.url.deletingPathExtension().lastPathComponent
                if let sameName = local.first(where: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent == stem }) { result[file.url.path] = sameName }
                else if local.count == 1 { result[file.url.path] = local[0] }
            }
            // Our camera captures use an explicit sidecar; do not pair arbitrary same-name files.
            let sidecar = file.url.deletingPathExtension().appendingPathExtension("shiguang.json")
            if let data = try? Data(contentsOf: sidecar), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String], let name = value["video"], name == URL(fileURLWithPath: name).lastPathComponent {
                let video = file.url.deletingLastPathComponent().appendingPathComponent(name)
                if availableVideos.contains(video.path) { result[file.url.path] = video.path }
            }
        }
        return result
    }
    func analyze(_ file: ScanFile, companion: String?, deep: Bool, localModel: Bool, model: String, previous: MediaItem?, report: ScanReporter? = nil, preview: ScanPreviewReporter? = nil) async throws -> MediaItem {
        try await gate.checkpoint()
        let video = Self.videoExtensions.contains(file.url.pathExtension.lowercased())
        var item = MediaItem(id: identifier(file.url.path), path: file.url.path, modified: file.modified, bytes: file.bytes, kind: video ? "video" : "image", date: file.modified, dateSource: "文件修改时间", tasks: previous?.tasks ?? [], excludedTasks: previous?.excludedTasks ?? [])
        item.placeLabel = previous?.placeLabel
        if previous?.placeLabel != nil {
            item.latitude = previous?.latitude
            item.longitude = previous?.longitude
        }
        item.companion = companion
        if let companion {
            let values = try URL(fileURLWithPath: companion).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            item.companionModified = values.contentModificationDate
            item.companionBytes = Int64(values.fileSize ?? 0)
        }
        if video {
            try await analyzeVideo(&item, deep: deep, localModel: localModel, model: model, report: report, preview: preview)
        } else {
            guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { throw failure("无法读取图片") }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
            item.width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
            item.height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
            if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any], let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let offset = exif["OffsetTimeOriginal"] as? String { formatter.timeZone = TimeZone(abbreviation: "GMT\(offset)") }
                if let date = formatter.date(from: dateString) { item.date = date; item.dateSource = "拍摄时间" }
            }
            if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any], let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double, let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
                item.latitude = lat * ((gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1 : 1)
                item.longitude = lon * ((gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1 : 1)
            }
            if previous?.placeLabel != nil {
                item.latitude = previous?.latitude
                item.longitude = previous?.longitude
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw failure("无法解码图片") }
            try saveThumbnail(image, id: item.id)
            await preview?(item)
            try await gate.checkpoint()
            await report?(ScanUpdate(stage: .image, path: file.url.path))
            let result = try vision(image)
            item.analyzedFrames = 1
            item.keywords = SearchText.expanded(result.labels); item.recognizedText = result.text; item.sharpness = result.sharpness
            item.features = [result.feature].compactMap { $0 }
            await preview?(item)
            if localModel {
                await report?(ScanUpdate(stage: .model, path: file.url.path))
                do { item.caption = try await caption(image, model: model) }
                catch is CancellationError { throw CancellationError() }
                catch { item.warning = "增强描述失败：" + error.localizedDescription }
            }
        }
        if !video, let companion {
            var motion = MediaItem(id: item.id, path: companion, modified: item.companionModified ?? item.modified, bytes: item.companionBytes ?? 0, kind: "video", date: item.date, dateSource: item.dateSource)
            do {
                try await analyzeVideo(&motion, deep: deep, localModel: false, model: model, writeThumbnail: false, report: report)
                item.keywords = Array(Set(item.keywords + motion.keywords)).sorted()
                item.recognizedText = [item.recognizedText, motion.recognizedText].filter { !$0.isEmpty }.joined(separator: "\n")
                item.frames = motion.frames; item.duration = motion.duration; item.hasAudio = motion.hasAudio
                item.analyzedFrames += motion.analyzedFrames
            } catch is CancellationError { throw CancellationError() }
            catch { item.warning = [item.warning, "动态视频分析失败：" + error.localizedDescription].compactMap { $0 }.joined(separator: "\n") }
        }
        try await gate.checkpoint()
        item.digest = try await hash(file.url, report: report)
        if let companion { item.companionHash = try await hash(URL(fileURLWithPath: companion), report: report) }
        item.analysisProfile = AnalysisProfile.key(video: item.isVideo || item.isMotion, deep: deep, localModel: localModel, model: model)
        let after = try file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard after.contentModificationDate == file.modified, Int64(after.fileSize ?? 0) == file.bytes else { throw failure("文件在分析时发生变化，将在下次扫描重试") }
        if let companion {
            let after = try URL(fileURLWithPath: companion).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard after.contentModificationDate == item.companionModified, Int64(after.fileSize ?? 0) == item.companionBytes else { throw failure("动态视频在分析时发生变化，将在下次扫描重试") }
        }
        if let previous, let placeLabel = previous.placeLabel {
            item.placeLabel = placeLabel
            item.latitude = previous.latitude
            item.longitude = previous.longitude
        }
        return item
    }
    private func analyzeVideo(_ item: inout MediaItem, deep: Bool, localModel: Bool, model: String, writeThumbnail: Bool = true, report: ScanReporter? = nil, preview: ScanPreviewReporter? = nil) async throws {
        await report?(ScanUpdate(stage: .video, path: item.path))
        let asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw failure("无法读取视频时长或编码不受支持") }
        item.duration = duration
        item.hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            item.width = Int(abs(rect.width).rounded()); item.height = Int(abs(rect.height).rounded())
        }
        if let created = try await asset.load(.creationDate), let date = try? await created.load(.dateValue) { item.date = date; item.dateSource = "拍摄时间" }
        let metadata = try await asset.load(.metadata)
        for meta in metadata where meta.identifier?.rawValue.contains("location.ISO6709") == true {
            if let location = try? await meta.load(.stringValue) {
                let pattern = #"([+-]\d+\.\d+)([+-]\d+\.\d+)"#
                if let re = try? NSRegularExpression(pattern: pattern), let match = re.firstMatch(in: location, range: NSRange(location.startIndex..., in: location)), let a = Range(match.range(at: 1), in: location), let b = Range(match.range(at: 2), in: location) { item.latitude = Double(location[a]); item.longitude = Double(location[b]) }
            }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1024, height: 1024)
        let first = try generator.copyCGImage(at: CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600), actualTime: nil)
        if writeThumbnail { try saveThumbnail(first, id: item.id); await preview?(item); try await gate.checkpoint() }
        if localModel {
            await report?(ScanUpdate(stage: .model, path: item.path))
            do { item.caption = try await caption(first, model: model) }
            catch is CancellationError { throw CancellationError() }
            catch { item.warning = "增强描述失败：" + error.localizedDescription }
        }
        var labels = Set<String>(), texts = Set<String>()
        var buckets: [Int: FrameHit] = [:]
        var featureSlots = Set<Int>()
        let featureSpacing = max(3, duration / 60)
        func consume(_ image: CGImage, second: Double) throws {
            let result = try vision(image)
            item.analyzedFrames += 1
            labels.formUnion(result.labels)
            if !result.text.isEmpty { texts.insert(result.text) }
            let bucket = Int(second / 3)
            let old = buckets[bucket]
            buckets[bucket] = FrameHit(second: Double(bucket) * 3, keywords: Array(Set((old?.keywords ?? []) + SearchText.expanded(result.labels))).sorted(), text: Array(Set(((old?.text.components(separatedBy: "\n") ?? []) + result.text.components(separatedBy: "\n")).filter { !$0.isEmpty })).sorted().joined(separator: "\n"))
            let slot = Int(second / featureSpacing)
            if featureSlots.insert(slot).inserted, let feature = result.feature { item.features.append(feature) }
        }
        var lastReport = Date.distantPast
        if deep {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("没有视频轨道") }
            let transform = try await track.load(.preferredTransform)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw failure("视频轨道不支持逐帧解码") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? failure("无法开始逐帧解码") }
            defer { reader.cancelReading() }
            let context = CIContext()
            while let sample = output.copyNextSampleBuffer() {
                try await gate.checkpoint()
                guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
                let second = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard second.isFinite else { continue }
                try autoreleasepool {
                    let ci = CIImage(cvPixelBuffer: pixel).transformed(by: transform)
                    let factor = min(1, 1024 / max(ci.extent.width, ci.extent.height))
                    let scaled = ci.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    guard let image = context.createCGImage(scaled, from: scaled.extent) else { throw failure("视频帧转换失败") }
                    try consume(image, second: max(0, second))
                }
                let frameDuration = CMSampleBufferGetDuration(sample).seconds
                let reached = min(duration, max(0, second) + (frameDuration.isFinite && frameDuration > 0 ? frameDuration : 0))
                if Date().timeIntervalSince(lastReport) > 0.25 || reached >= duration {
                    await report?(ScanUpdate(stage: .video, path: item.path, fraction: reached / duration, detail: "已分析 \(item.analyzedFrames) 帧 · \(time(reached)) / \(time(duration))")); lastReport = Date()
                }
                await Task.yield()
            }
            if reader.status == .failed { throw reader.error ?? failure("逐帧解码失败") }
        } else {
            var second: Double = 0
            while second < duration {
                try await gate.checkpoint()
                try autoreleasepool {
                    let frame = try generator.copyCGImage(at: CMTime(seconds: second, preferredTimescale: 600), actualTime: nil)
                    try consume(frame, second: second)
                }
                second += 3
                let reached = min(second, duration)
                if Date().timeIntervalSince(lastReport) > 0.25 || reached >= duration {
                    await report?(ScanUpdate(stage: .video, path: item.path, fraction: reached / duration, detail: "已分析 \(item.analyzedFrames) 帧 · \(time(reached)) / \(time(duration))")); lastReport = Date()
                }
                await Task.yield()
            }
        }
        await report?(ScanUpdate(stage: .video, path: item.path, fraction: 1, detail: "已分析 \(item.analyzedFrames) 帧"))
        item.keywords = SearchText.expanded(Array(labels)); item.recognizedText = texts.sorted().joined(separator: "\n")
        item.frames = buckets.values.sorted { $0.second < $1.second }
    }
    private func vision(_ image: CGImage) throws -> VisualResult {
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest(); text.recognitionLevel = .accurate; text.recognitionLanguages = ["zh-Hans", "en-US", "es-ES"]; text.usesLanguageCorrection = true
        let feature = VNGenerateImageFeaturePrintRequest(); feature.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image).perform([classify, text, feature])
        let labels = Array((classify.results ?? []).filter { $0.confidence > 0.12 }.prefix(12)).map(\.identifier)
        let recognized = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let archived = try feature.results?.first.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true).base64EncodedString() }
        return VisualResult(labels: labels, text: recognized, feature: archived, sharpness: sharpness(image))
    }
    private func sharpness(_ image: CGImage) -> Double {
        let size = 128
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var sum = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(size - 1) { for x in 1..<(size - 1) {
            let i = y * size + x
            let v = Double(4 * Int(pixels[i]) - Int(pixels[i-1]) - Int(pixels[i+1]) - Int(pixels[i-size]) - Int(pixels[i+size]))
            sum += v; squares += v * v; count += 1
        }}
        return max(0, squares / count - pow(sum / count, 2))
    }
    private func saveThumbnail(_ image: CGImage, id: String) throws {
        guard let dest = CGImageDestinationCreateWithURL(LibraryPaths.thumbnail(id) as CFURL, "public.jpeg" as CFString, 1, nil) else { throw failure("无法创建缩略图") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw failure("缩略图写入失败") }
    }
    private func caption(_ image: CGImage, model: String) async throws -> String {
        try await LocalModelClient.validateModel(model)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return "" }
        // Fixed loopback address: image data never goes to an external service.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": "Describe this image concisely in Chinese, English and Spanish, including visible subjects, colors, setting, actions and text. Do not guess identities, exact locations or dates.", "images": [jpeg.base64EncodedString()], "stream": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let caption = json["response"] as? String else { throw failure("本机视觉模型不可用。请检查 Ollama 和模型名称，或关闭增强分析后重试。") }
        return caption
    }
    func search(_ items: [MediaItem], query: String) throws -> [String: Double] {
        let query = SearchText.contentQuery(query)
        guard !query.isEmpty else { return Dictionary(uniqueKeysWithValues: items.map { ($0.id, 1) }) }
        let lang = NLLanguageRecognizer.dominantLanguage(for: query)
        let embedding = lang == .simplifiedChinese || lang == .traditionalChinese ? chineseEmbedding : lang == .spanish ? spanishEmbedding : englishEmbedding
        let semanticQuery = lang == .english ? SearchText.englishQuery(query) : query
        let vector = embedding?.vector(for: semanticQuery)
        if searchVectors.count > 10_000 { searchVectors.removeAll(keepingCapacity: true) }
        var results: [String: Double] = [:]
        for item in items {
            try Task.checkCancellation()
            let lexical = SearchText.lexicalScore(query: query, document: item.searchableText)
            var score = lexical
            if let vector, let embedding {
                let fingerprint = SHA256.hash(data: Data(item.searchableText.utf8)).map { String(format: "%02x", $0) }.joined()
                let key = item.id + "|" + (lang?.rawValue ?? "en") + "|" + fingerprint
                let docVector = searchVectors[key] ?? embedding.vector(for: String(item.searchableText.prefix(1800)))
                if let docVector {
                    searchVectors[key] = docVector
                    let dot = zip(vector, docVector).reduce(0) { $0 + $1.0 * $1.1 }
                    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 } * docVector.reduce(0) { $0 + $1 * $1 })
                    if norm > 0 { let similarity = dot / norm; if similarity > 0.52 { score = max(score, similarity * 0.8) } }
                }
            }
            if score >= 0.3 { results[item.id] = score }
        }
        return results
    }
    func duplicates(_ items: [MediaItem], report: ScanReporter? = nil) async throws -> [DuplicateGroup] {
        await report?(ScanUpdate(stage: .duplicates, path: ""))
        var lastReport = Date.distantPast
        let eligible = items.filter { $0.error == nil && !$0.digest.isEmpty }
        let exact = Dictionary(grouping: eligible.compactMap { item in DuplicatePolicy.exactKey(item).map { ($0, item) } }, by: { $0.0 })
        var groups: [DuplicateGroup] = [], exactIDs = Set<String>(), representatives: [MediaItem] = []
        for (key, pairs) in exact where pairs.count > 1 {
            let sorted = pairs.map(\.1).sorted { $0.path < $1.path }
            exactIDs.formUnion(sorted.map(\.id))
            representatives.append(sorted[0])
            groups.append(DuplicateGroup(id: key, items: sorted, exact: true, reasons: ["SHA-256 文件内容一致。动态照片已同时核对照片与配套视频。", "任选一个完整副本保留；可结合所在文件夹决定。建议不等于已清理。 "]))
        }
        let candidates = (eligible.filter { !exactIDs.contains($0.id) } + representatives).sorted { $0.path < $1.path }
        var observations: [String: [VNFeaturePrintObservation]] = [:]
        for item in candidates {
            try await gate.checkpoint()
            if Date().timeIntervalSince(lastReport) > 0.25 {
                await report?(ScanUpdate(stage: .duplicates, path: item.path)); lastReport = Date()
            }
            observations[item.id] = item.features.compactMap { encoded in
                guard let data = Data(base64Encoded: encoded) else { return nil }
                return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
            }
        }
        var used = Set<String>()
        for (i, item) in candidates.enumerated() {
            await Task.yield()
            try await gate.checkpoint()
            if Date().timeIntervalSince(lastReport) > 0.25 {
                await report?(ScanUpdate(stage: .duplicates, path: item.path, fraction: Double(i) / Double(max(1, candidates.count)), detail: "已比较 \(i) / \(candidates.count) 项")); lastReport = Date()
            }
            guard !used.contains(item.id), let features = observations[item.id], !features.isEmpty else { continue }
            var group = [item]
            for other in candidates.dropFirst(i + 1) where !used.contains(other.id) && item.kind == other.kind {
                try await gate.checkpoint()
                guard let otherFeatures = observations[other.id], !otherFeatures.isEmpty else { continue }
                let threshold: Float = item.isVideo ? 0.16 : 0.20
                func close(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Bool {
                    var distance: Float = 10
                    do { try a.computeDistance(&distance, to: b); return distance < threshold } catch { return false }
                }
                let similar: Bool
                if item.isVideo {
                    // Require broad coverage in both directions, not a single matching frame.
                    let a = features.filter { f in otherFeatures.contains { close(f, $0) } }.count
                    let b = otherFeatures.filter { f in features.contains { close(f, $0) } }.count
                    similar = Double(a) / Double(features.count) >= 0.8 && Double(b) / Double(otherFeatures.count) >= 0.8
                } else { similar = close(features[0], otherFeatures[0]) }
                if similar { group.append(other); used.insert(other.id) }
            }
            guard group.count > 1 else { continue }
            used.insert(item.id)
            group.sort { DuplicatePolicy.rank($0) > DuplicatePolicy.rank($1) }
            var reasons = Array(Set(group.dropFirst().flatMap { DuplicatePolicy.reasons(best: group[0], other: $0) })).sorted()
            reasons.append(item.isVideo ? "相似度来自抽样画面，未核对音频内容，不能认定视频完全重复。" : "画面相似，表情、构图或动态内容可能不同，请比较后决定。")
            groups.append(DuplicateGroup(id: "similar:" + group.map(\.id).sorted().joined(separator: ":"), items: group, exact: false, reasons: reasons))
        }
        await report?(ScanUpdate(stage: .duplicates, path: "", fraction: 1))
        return groups.sorted { $0.exact && !$1.exact }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "LumaTrace", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
}
