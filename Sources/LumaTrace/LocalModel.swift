import Foundation

enum LocalModelClient {
    struct Tags: Decodable { var models: [Model] }
    struct Model: Decodable { var name: String }
    struct Info: Decodable { var capabilities: [String]?; var remote_host: String?; var remote_model: String? }
    static func problem(_ text: String) -> NSError { NSError(domain: "LumaTrace.LocalModel", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func request(_ endpoint: String, model: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/" + endpoint)!)
        request.timeoutInterval = 8
        if let model { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model]) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw problem("模型不存在或 Ollama 返回错误，请检查已安装的模型名称。") }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is URLError { throw problem("无法连接本机 Ollama，请启动 Ollama 后重试。") }
    }
    static func modelNames(_ data: Data) throws -> [String] { try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted() }
    static func validate(_ info: Info, model: String) throws {
        guard info.remote_host?.isEmpty != false, info.remote_model?.isEmpty != false, !model.hasSuffix(":cloud") else { throw problem("仅支持本机模型，请选择已下载的本地视觉模型。") }
        guard info.capabilities?.contains("vision") == true else { throw problem("该模型未报告视觉能力，请选择支持图片的模型或更新 Ollama。") }
    }
    static func validateModel(_ name: String) async throws {
        let data = try await request("show", model: name)
        let info = try JSONDecoder().decode(Info.self, from: data)
        try validate(info, model: name)
    }
}
extension LibraryStore {
    func checkLocalModel() {
        guard !modelCheckBusy else { return }
        modelCheckBusy = true; modelStatus = "正在检测本机 Ollama…"
        let name = state.model.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { modelCheckBusy = false }
            do {
                let data = try await LocalModelClient.request("tags")
                installedModels = try LocalModelClient.modelNames(data)
                guard !name.isEmpty else { modelStatus = "请选择或输入视觉模型名称"; return }
                try await LocalModelClient.validateModel(name)
                guard name == state.model.trimmingCharacters(in: .whitespacesAndNewlines) else { modelStatus = "模型名称已改变，请重新检测"; return }
                modelStatus = "已连接，所选模型支持视觉分析"
                retryFailedModelDescriptions()
            } catch { modelStatus = error.localizedDescription }
        }
    }
}
