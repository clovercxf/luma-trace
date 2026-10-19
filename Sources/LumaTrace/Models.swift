import Foundation

struct FrameHit: Codable, Identifiable, Hashable, Sendable {
    var second: Double
    var keywords: [String]
    var text: String
    var id: Double { second }
}
struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var path: String
    var modified: Date
    var bytes: Int64
    var kind: String
    var date: Date
    var dateSource: String
    var latitude: Double?
    var longitude: Double?
    var placeLabel: String?
    var width = 0
    var height = 0
    var duration: Double = 0
    var hasAudio = false
    var analyzedFrames = 0
    var analysisProfile: String?
    var companion: String?
    var companionHash: String?
    var companionModified: Date?
    var companionBytes: Int64?
    var contentID: String?
    var digest = ""
    var keywords: [String] = []
    var recognizedText = ""
    var caption = ""
    var frames: [FrameHit] = []
    var features: [String] = []
    var sharpness: Double = 0
    var tasks: [String] = []
    var excludedTasks: [String] = []
    var error: String?
    var warning: String?
    var isCurrentOnDisk: Bool {
        func matches(_ path: String, _ modified: Date, _ bytes: Int64) -> Bool {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.contentModificationDate == modified && Int64(values.fileSize ?? -1) == bytes
        }
        guard matches(path, modified, bytes) else { return false }
        if let companion {
            guard let companionModified, let companionBytes else { return false }
            return matches(companion, companionModified, companionBytes)
        }
        return true
    }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var isMotion: Bool { companion != nil }
    var isVideo: Bool { kind == "video" }
    var searchableText: String { ([name, caption, recognizedText, placeLabel ?? ""] + keywords + tasks).joined(separator: " ") }
    var location: String {
        if let placeLabel, !placeLabel.isEmpty { return placeLabel }
        guard let latitude, let longitude else { return "无定位" }
        return String(format: "%.3f, %.3f", latitude, longitude)
    }
}
struct TaskRule: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var keywords: String
    var terms: [String] { keywords.components(separatedBy: CharacterSet(charactersIn: ",，;；\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}
struct LibraryState: Codable {
    var roots: [String] = []
    var items: [MediaItem] = []
    var rules: [TaskRule] = []
    var deepVideo = false
    var useLocalModel = false
    var model = "qwen2.5vl:3b"
    var hiddenGroups: [String] = []
    var memories: [MemoryReel] = []
    var memoryPreferences = MemoryPreferences()
}
struct DuplicateGroup: Identifiable {
    var id: String
    var items: [MediaItem]
    var exact: Bool
    var reasons: [String]
}

enum LibraryPaths {
    static let base: URL = {
        if let path = ProcessInfo.processInfo.environment["LUMATRACE_LIBRARY"] ?? ProcessInfo.processInfo.environment["SHIGUANG_LIBRARY"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shiguang", isDirectory: true)
    }()
    static let index = base.appendingPathComponent("library.json")
    static let cache = base.appendingPathComponent("Cache", isDirectory: true)
    static let memories = base.appendingPathComponent("Memories", isDirectory: true)
    static let captures = base.appendingPathComponent("Captures", isDirectory: true)
    static func prepare() throws {
        for dir in [base, cache, captures, memories] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
    static func thumbnail(_ id: String) -> URL { cache.appendingPathComponent(id + ".jpg") }
}

enum SearchText {
    // System classifier emits English labels. These aliases also make common Chinese searches work offline.
    static let aliases: [String: [String]] = [
        "dog": ["狗", "小狗", "犬", "perro", "perros"], "cat": ["猫", "小猫", "gato", "gatos"], "beach": ["海边", "沙滩", "海滩", "playa"],
        "ocean": ["海", "大海", "海洋", "océano", "mar"], "sea": ["海"], "sunset": ["日落", "夕阳", "晚霞", "atardecer"],
        "sunrise": ["日出"], "mountain": ["山", "登山", "montaña"], "snow": ["雪", "下雪", "nieve"], "tree": ["树", "树林"],
        "forest": ["森林"], "flower": ["花", "鲜花", "flor", "flores"], "food": ["食物", "美食", "吃饭", "comida"],
        "restaurant": ["餐厅", "饭店"], "cake": ["蛋糕", "生日"], "car": ["汽车", "车"],
        "building": ["建筑", "楼", "装修"], "room": ["房间", "室内", "装修"], "furniture": ["家具", "装修"],
        "person": ["人", "人物"], "people": ["人", "聚会"], "baby": ["婴儿", "宝宝"], "child": ["孩子", "儿童"],
        "document": ["文档", "文件"], "screen": ["屏幕", "截图"], "receipt": ["收据", "发票"],
        "water": ["水"], "sky": ["天空"], "bird": ["鸟"], "city": ["城市"], "night": ["夜晚", "夜景"],
        "wedding": ["婚礼"], "travel": ["旅行", "旅游", "viaje"], "white": ["白色", "blanco", "blanca"], "black": ["黑色", "negro", "negra"], "red": ["红色", "rojo", "roja"]
    ]
    static func expanded(_ words: [String]) -> [String] {
        var result = Set(words)
        for word in words {
            for (key, values) in aliases where contains(key, in: word.lowercased()) { result.formUnion(values) }
        }
        return result.sorted()
    }
    static func englishQuery(_ text: String) -> String {
        var value = text.lowercased()
        let pairs = aliases.flatMap { key, words in words.map { ($0, key) } }.sorted {
            if $0.0.count != $1.0.count { return $0.0.count > $1.0.count }
            return ($0.0, $0.1) < ($1.0, $1.1)
        }
        var handled = Set<String>()
        for (alias, key) in pairs where handled.insert(alias).inserted {
            let isCJK = alias.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil
            let pattern = isCJK ? NSRegularExpression.escapedPattern(for: alias) : #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: alias) + #"(?![\p{L}\p{N}])"#
            value = value.replacingOccurrences(of: pattern, with: " \(key) ", options: .regularExpression)
        }
        return value
    }
    static func contains(_ term: String, in document: String) -> Bool {
        let term = term.lowercased()
        guard !term.isEmpty else { return false }
        if term.unicodeScalars.allSatisfy({ $0.isASCII }) && term.contains(where: { $0.isLetter }) {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}])"#
            return document.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return document.localizedCaseInsensitiveContains(term)
    }
    static func lexicalScore(query: String, document: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return 1 }
        let d = document.lowercased()
        if contains(q, in: d) { return 1 }
        let translated = englishQuery(q)
        let terms = translated.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let hits = terms.filter { contains($0, in: d) }.count
        return terms.isEmpty ? 0 : Double(hits) / Double(terms.count)
    }
    static func matchingYear(_ query: String, now: Date = Date()) -> Int? {
        let current = Calendar.current.component(.year, from: now)
        if query.contains("去年") || query.lowercased().contains("last year") || query.lowercased().contains("el año pasado") { return current - 1 }
        if query.contains("今年") || query.lowercased().contains("this year") || query.lowercased().contains("este año") { return current }
        let pattern = #"(?<!\d)(?:19|20)\d{2}(?!\d)"#
        guard let range = query.range(of: pattern, options: .regularExpression) else { return nil }
        return Int(query[range])
    }
    static func contentQuery(_ query: String) -> String {
        query.replacingOccurrences(of: #"(?i)(?<!\d)(?:19|20)\d{2}年?(?!\d)|去年|今年|last year|this year|el año pasado|este año"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DuplicatePolicy {
    static func rank(_ item: MediaItem) -> Double {
        let pixels = Double(item.width) * Double(item.height)
        return log2(max(1, pixels)) * 2 + log2(max(1, item.sharpness)) + (item.latitude != nil ? 1 : 0) + (item.dateSource == "拍摄时间" ? 1 : 0) + (item.isMotion ? 3 : 0)
    }
    static func exactKey(_ item: MediaItem) -> String? {
        guard !item.digest.isEmpty, item.error == nil else { return nil }
        if item.isMotion {
            guard let companionHash = item.companionHash else { return nil }
            return "live:" + item.digest + ":" + companionHash
        }
        return item.kind + ":" + item.digest
    }
    static func reasons(best: MediaItem, other: MediaItem) -> [String] {
        var reasons: [String] = []
        if best.width * best.height > other.width * other.height { reasons.append("像素更高：\(best.width)×\(best.height)") }
        if !best.isVideo && best.sharpness > other.sharpness * 1.15 { reasons.append("边缘清晰度评分更高（仅供参考）") }
        if best.latitude != nil && other.latitude == nil { reasons.append("保留了 GPS 定位") }
        if best.dateSource == "拍摄时间" && other.dateSource != "拍摄时间" { reasons.append("保留了原始拍摄时间") }
        if best.isMotion && !other.isMotion { reasons.append("包含动态视频") }
        if best.isVideo {
            if abs(best.duration - other.duration) > 0.5 { reasons.append("视频时长不同，可能包含独有片段，建议都保留") }
            if best.hasAudio != other.hasAudio { reasons.append("音轨不同，建议试听后决定") }
        }
        if reasons.isEmpty { reasons.append("质量指标接近；优先展示原路径，建议人工比较构图与内容") }
        return reasons
    }
}

extension MediaItem {
    enum CodingKeys: String, CodingKey {
        case id, path, modified, bytes, kind, date, dateSource, latitude, longitude, placeLabel, width, height, duration, hasAudio, analyzedFrames, analysisProfile, companion, companionHash, companionModified, companionBytes, contentID, digest, keywords, recognizedText, caption, frames, features, sharpness, tasks, excludedTasks, error, warning
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        modified = try c.decode(Date.self, forKey: .modified)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "image"
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? modified
        dateSource = try c.decodeIfPresent(String.self, forKey: .dateSource) ?? "文件修改时间"
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        placeLabel = try c.decodeIfPresent(String.self, forKey: .placeLabel)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        analyzedFrames = try c.decodeIfPresent(Int.self, forKey: .analyzedFrames) ?? 0
        analysisProfile = try c.decodeIfPresent(String.self, forKey: .analysisProfile)
        companion = try c.decodeIfPresent(String.self, forKey: .companion)
        companionHash = try c.decodeIfPresent(String.self, forKey: .companionHash)
        companionModified = try c.decodeIfPresent(Date.self, forKey: .companionModified)
        companionBytes = try c.decodeIfPresent(Int64.self, forKey: .companionBytes)
        contentID = try c.decodeIfPresent(String.self, forKey: .contentID)
        digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        frames = try c.decodeIfPresent([FrameHit].self, forKey: .frames) ?? []
        features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks) ?? []
        excludedTasks = try c.decodeIfPresent([String].self, forKey: .excludedTasks) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

extension LibraryState {
    enum CodingKeys: String, CodingKey { case roots, items, rules, deepVideo, useLocalModel, model, hiddenGroups, memories, memoryPreferences }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? []
        items = try c.decodeIfPresent([MediaItem].self, forKey: .items) ?? []
        rules = try c.decodeIfPresent([TaskRule].self, forKey: .rules) ?? []
        deepVideo = try c.decodeIfPresent(Bool.self, forKey: .deepVideo) ?? false
        useLocalModel = try c.decodeIfPresent(Bool.self, forKey: .useLocalModel) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "qwen2.5vl:3b"
        hiddenGroups = try c.decodeIfPresent([String].self, forKey: .hiddenGroups) ?? []
        memories = try c.decodeIfPresent([MemoryReel].self, forKey: .memories) ?? []
        memoryPreferences = try c.decodeIfPresent(MemoryPreferences.self, forKey: .memoryPreferences) ?? MemoryPreferences()
    }
}

enum AnalysisProfile {
    static let legacy = key(video: false, deep: false, localModel: false, model: "")
    static func key(video: Bool, deep: Bool, localModel: Bool, model: String) -> String {
        "v1|" + (video && deep ? "every-frame" : "sampled") + "|" + (localModel ? model.trimmingCharacters(in: .whitespacesAndNewlines) : "system")
    }
}
