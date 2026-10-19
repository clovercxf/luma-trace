import SwiftUI
import AppKit
import AVFoundation
import ImageIO

// All lifecycle transitions and AVCaptureSession mutations run on the engine queue.
// The preview layer is the only external reader of the session.
struct CameraLifecycle {
    private(set) var generation = 0
    private(set) var active = false
    mutating func begin() -> Int { generation += 1; active = true; return generation }
    mutating func end() { generation += 1; active = false }
    func accepts(_ ticket: Int) -> Bool { active && ticket == generation }
}
private enum CameraEvent: Sendable { case ready(Bool), failure(String), saved(URL) }
private final class CameraEngine: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "LumaTrace.Camera")
    private var lifecycle = CameraLifecycle()
    private var configured = false
    let onEvent: @Sendable (CameraEvent) -> Void
    init(onEvent: @escaping @Sendable (CameraEvent) -> Void) { self.onEvent = onEvent }
    func start() {
        queue.async { [self] in
            let ticket = self.lifecycle.begin()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                self.queue.async {
                    guard self.lifecycle.accepts(ticket) else { return }
                    guard allowed else {
                        self.onEvent(.failure("摄像头权限未开启，请在系统设置 → 隐私与安全性 → 摄像头中允许LumaTrace访问。")); return
                    }
                    do {
                        if !self.configured {
                            guard let camera = AVCaptureDevice.default(for: .video) else { throw self.failure("未找到摄像头") }
                            let input = try AVCaptureDeviceInput(device: camera)
                            self.session.beginConfiguration()
                            do {
                                if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                                guard self.session.canAddInput(input) else { throw self.failure("无法连接摄像头") }
                                self.session.addInput(input)
                                guard self.session.canAddOutput(self.output) else { self.session.removeInput(input); throw self.failure("摄像头不支持视频输出") }
                                self.session.addOutput(self.output)
                                self.session.commitConfiguration()
                            } catch { self.session.commitConfiguration(); throw error }
                            self.configured = true
                        }
                        self.session.startRunning()
                        guard self.session.isRunning else { throw self.failure("摄像头启动失败，请检查设备是否被其他程序占用") }
                        self.onEvent(.ready(true))
                    } catch { self.onEvent(.failure(error.localizedDescription)) }
                }
            }
        }
    }
    func shoot() {
        queue.async {
            guard self.lifecycle.active, self.session.isRunning, !self.output.isRecording else {
                self.onEvent(.failure("摄像头未准备好，请重新打开拍摄窗口")); return
            }
            do {
                try LibraryPaths.prepare()
                let name = "动态照片-" + UUID().uuidString
                let url = LibraryPaths.captures.appendingPathComponent(name + ".mov")
                self.output.maxRecordedDuration = CMTime(seconds: 3, preferredTimescale: 600)
                self.output.startRecording(to: url, recordingDelegate: self)
            } catch { self.onEvent(.failure(error.localizedDescription)) }
        }
    }
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
            onEvent(.failure(error.localizedDescription)); return
        }
        Task {
            do {
                let asset = AVURLAsset(url: outputFileURL)
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw failure("录制结果为空") }
                let image = try generator.copyCGImage(at: CMTime(seconds: duration / 2, preferredTimescale: 600), actualTime: nil)
                let photo = outputFileURL.deletingPathExtension().appendingPathExtension("jpg")
                guard let dest = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: Date())]] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
                let sidecar = outputFileURL.deletingPathExtension().appendingPathExtension("shiguang.json")
                try JSONSerialization.data(withJSONObject: ["video": outputFileURL.lastPathComponent, "format": "shiguang-motion-v1"]).write(to: sidecar, options: .atomic)
                onEvent(.saved(photo))
            } catch { onEvent(.failure("封面生成失败，视频仍在拍摄目录：\(error.localizedDescription)")) }
        }
    }
    func stop() {
        queue.async {
            self.lifecycle.end()
            if self.output.isRecording { self.output.stopRecording() }
            self.session.stopRunning()
            self.onEvent(.ready(false))
        }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "LumaTrace", code: 3, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@MainActor final class CameraController: ObservableObject {
    @Published var ready = false
    @Published var recording = false
    @Published var message = "打开摄像头后，点击拍摄记录接下来约 3 秒的动态照片"
    var completion: ((URL) -> Void)?
    private lazy var engine = CameraEngine { [weak self] event in
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .ready(let value): self.ready = value
            case .failure(let text): self.recording = false; self.message = text
            case .saved(let photo):
                self.recording = false; self.message = "已保存动态照片，将自动加入资料库"; self.completion?(photo)
            }
        }
    }
    var session: AVCaptureSession { engine.session }
    func start() { engine.start() }
    func shoot() {
        guard ready, !recording else { return }
        recording = true; message = "正在记录约 3 秒…（无音频）"
        engine.shoot()
    }
    func stop() { ready = false; engine.stop() }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = PreviewView(); view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspect
        view.layer?.addSublayer(layer); view.preview = layer
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class PreviewView: NSView {
        var preview: AVCaptureVideoPreviewLayer?
        override func layout() { super.layout(); preview?.frame = bounds }
    }
}
struct CameraSheet: View {
    @StateObject private var camera = CameraController()
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LibraryStore
    var body: some View {
        VStack(spacing: 18) {
            HStack { Text(tr("拍摄动态照片")).font(.title2.bold()); Spacer(); Button(tr("完成")) { dismiss() }.disabled(camera.recording) }
            CameraPreview(session: camera.session).frame(width: 620, height: 350).background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(tr(camera.message)).foregroundStyle(.secondary)
            Button(action: camera.shoot) { Label(camera.recording ? tr("正在拍摄…") : tr("拍摄 3 秒"), systemImage: "camera.aperture") }.buttonStyle(.borderedProminent).disabled(!camera.ready || camera.recording)
            Text(tr("保存为LumaTrace动态照片（JPG + MOV + 配对文件），可在本应用长按播放；暂不导出苹果标准 Live Photo。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).interactiveDismissDisabled(camera.recording).onAppear { camera.completion = { store.captureImported($0) }; camera.start() }.onDisappear { camera.stop() }
    }
}
