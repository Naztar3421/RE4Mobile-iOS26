import SwiftUI
import Metal
import MetalKit
import CryptoKit

@main
struct RE4MCTPreviewApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var mctData = SyntheticMCTFixture.makeCheckerboard()
    @State private var sourceName = "內建合成樣本"
    @State private var showingImporter = false
    @State private var status = "等待貼圖解碼結果……"
    @State private var details = "啟動時先顯示內建合成測試，尚未匯入原版遊戲貼圖。"

    var body: some View {
        VStack(spacing: 14) {
            Text("RE4 MCT / Metal Preview")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("MCT decoder → RGBA8 → native Metal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            MCTMetalPreview(data: mctData) { info, error in
                if let info {
                    status = "成功：\(sourceName) 已解碼並交給 Metal 顯示。"
                    details = "來源：\(sourceName)\n尺寸：\(info.width) × \(info.height)\n格式：\(info.format)／壓縮：\(info.compression)\nMCT：\(info.sourceBytes) bytes；RGBA8：\(info.rgbaBytes) bytes\nSHA-256：\(info.sha256)"
                } else {
                    status = "載入失敗"
                    details = error ?? "未知錯誤"
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(status)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(details)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button("重新載入合成樣本") {
                    sourceName = "內建合成樣本"
                    mctData = SyntheticMCTFixture.makeCheckerboard()
                }
                .buttonStyle(.bordered)

                Button("匯入 .mct") { showingImporter = true }
                    .buttonStyle(.borderedProminent)
            }
            .font(.footnote)

            Text("本版本驗證 MCT 貼圖解碼與 Metal 顯示，不會執行 RE4 遊戲引擎。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .sheet(isPresented: $showingImporter) {
            MCTDocumentPicker { result in
                showingImporter = false
                switch result {
                case .picked(let url):
                    guard url.pathExtension.lowercased() == "mct" else {
                        status = "選到的不是 .mct 檔案"
                        details = "選到：\(url.lastPathComponent)\n請選取副檔名為 .mct 的貼圖檔。"
                        return
                    }
                    do {
                        let imported = try Data(contentsOf: url)
                        sourceName = url.lastPathComponent
                        status = "已匯入 \(url.lastPathComponent)，正在解碼……"
                        details = "檔案已複製到 App 暫存空間，正在解析 MCT 標頭與貼圖資料。"
                        mctData = imported
                    } catch {
                        status = "讀取 MCT 失敗"
                        details = error.localizedDescription
                    }
                case .failed(let message):
                    status = "匯入失敗"
                    details = message
                case .cancelled:
                    status = "已取消選取"
                    details = "尚未匯入新的 MCT；目前仍顯示：\(sourceName)"
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct MCTPreviewInfo {
    let width: Int
    let height: Int
    let format: UInt16
    let compression: UInt16
    let sourceBytes: Int
    let rgbaBytes: Int
    let sha256: String
}

private struct MCTMetalPreview: UIViewRepresentable {
    let data: Data
    let onResult: (MCTPreviewInfo?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.onResult = onResult
        context.coordinator.load(data, into: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.load(data, into: uiView)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onResult: (MCTPreviewInfo?, String?) -> Void
        private var renderer: RE4MetalTexturePreviewRenderer?
        private var loadedHash: String?
        private var loadedInfo: MCTPreviewInfo?

        init(onResult: @escaping (MCTPreviewInfo?, String?) -> Void) {
            self.onResult = onResult
        }

        func load(_ data: Data, into view: MTKView) {
            let sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if loadedHash == sourceHash, let loadedInfo {
                // An imported file can be byte-identical to the built-in fixture.
                // Still report success after its display name/source changes.
                DispatchQueue.main.async { [weak self] in
                    self?.onResult(loadedInfo, nil)
                }
                return
            }
            do {
                let decoded = try RE4MCTTextureDecoder.decode(data)
                guard let device = view.device ?? MTLCreateSystemDefaultDevice() else {
                    throw NSError(domain: "RE4MCTPreview", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "此裝置沒有可用的 Metal device。"])
                }
                view.device = device
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba8Unorm,
                    width: decoded.width,
                    height: decoded.height,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw NSError(domain: "RE4MCTPreview", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "無法建立 MTLTexture。"])
                }
                texture.label = "MCTPreview/\(decoded.width)x\(decoded.height)"
                decoded.rgba8.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        texture.replace(
                            region: MTLRegionMake2D(0, 0, decoded.width, decoded.height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: decoded.bytesPerRow
                        )
                    }
                }
                if let renderer {
                    renderer.setTexture(texture)
                } else {
                    renderer = try RE4MetalTexturePreviewRenderer(view: view, texture: texture, device: device)
                }
                loadedHash = sourceHash
                let info = MCTPreviewInfo(
                    width: decoded.width,
                    height: decoded.height,
                    format: decoded.sourcePixelFormat,
                    compression: decoded.sourceCompression,
                    sourceBytes: data.count,
                    rgbaBytes: decoded.rgba8.count,
                    sha256: sourceHash
                )
                loadedInfo = info
                // Deferring this callback avoids mutating SwiftUI @State while
                // UIViewRepresentable is in makeUIView/updateUIView.
                DispatchQueue.main.async { [weak self] in
                    self?.onResult(info, nil)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.onResult(nil, message)
                }
            }
        }
    }
}

/// Creates an 8×8 MCT format-2 texture so the decoder and GPU path can be tested
/// without bundling copyrighted game resources.
private enum SyntheticMCTFixture {
    static func makeCheckerboard() -> Data {
        let width = 8, height = 8
        var bytes = [UInt8](repeating: 0, count: 42 + width * height * 4)
        bytes[0] = 0x4D; bytes[1] = 0x43; bytes[2] = 0x54; bytes[3] = 0x5F
        put16(1, at: 8, in: &bytes)
        put16(0, at: 30, in: &bytes)
        put16(0, at: 32, in: &bytes)
        put16(UInt16(width), at: 34, in: &bytes)
        put16(UInt16(height), at: 36, in: &bytes)
        put16(0, at: 38, in: &bytes)
        put16(2, at: 40, in: &bytes)
        var p = 42
        for y in 0..<height {
            for x in 0..<width {
                let color: [UInt8] = (((x / 2) + (y / 2)) % 2 == 0)
                    ? [220, 75, 25, 255] : [25, 75, 120, 255]
                bytes[p] = color[0]; bytes[p + 1] = color[1]
                bytes[p + 2] = color[2]; bytes[p + 3] = color[3]
                p += 4
            }
        }
        put32(UInt32(bytes.count - 10), at: 10, in: &bytes)
        return Data(bytes)
    }

    private static func put16(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
