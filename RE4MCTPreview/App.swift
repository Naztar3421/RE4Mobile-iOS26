import SwiftUI
import UIKit
import Metal
import MetalKit
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct RE4MCTPreviewApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var mctData = SyntheticMCTFixture.makeCheckerboard()
    @State private var sourceName = "內建合成樣本"
    @State private var activeSheet: PreviewSheet?
    @State private var blackAsTransparentPreview = false
    @State private var uploadBridgeSmokeTest = false
    @State private var capturedLoadObjReplay = false
    @State private var status = "等待貼圖解碼結果……"
    @State private var details = "啟動時先顯示內建合成測試，尚未匯入原版遊戲貼圖。"
    @State private var exportMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
            Text("RE4 MCT / Metal Preview")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("MCT decoder → RGBA8 → native Metal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            MCTMetalPreview(
                data: mctData,
                blackAsTransparent: blackAsTransparentPreview,
                uploadBridgeSmokeTest: uploadBridgeSmokeTest,
                capturedLoadObjReplay: capturedLoadObjReplay
            ) { info, error in
                if let info {
                    status = "成功：\(sourceName) 已解碼並交給 Metal 顯示。"
                    details = "來源：\(sourceName)\n尺寸：\(info.width) × \(info.height)\n格式：\(info.format)／壓縮：\(info.compression)\nMCT：\(info.sourceBytes) bytes；RGBA8：\(info.rgbaBytes) bytes\nRGBA透明像素：\(info.transparentPixels)\n純黑不透明像素：\(info.blackPixels)\nSHA-256：\(info.sha256)\n\(info.uploadPathNote)"
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Button {
                blackAsTransparentPreview.toggle()
            } label: {
                Label(
                    blackAsTransparentPreview ? "黑色透明預覽：開" : "黑色透明預覽：關",
                    systemImage: blackAsTransparentPreview ? "checkerboard.rectangle" : "circle.lefthalf.filled"
                )
            }
            .buttonStyle(.borderedProminent)

            Text("診斷模式：開啟後會把純黑像素以棋盤底色顯示，便於判斷黑區是否可能是色鍵背景；這不是對遊戲透明規則的定論。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                uploadBridgeSmokeTest.toggle()
                if uploadBridgeSmokeTest { capturedLoadObjReplay = false }
            } label: {
                Label(
                    uploadBridgeSmokeTest ? "上傳路徑：Bridge Smoke Test" : "上傳路徑：直接 Metal",
                    systemImage: uploadBridgeSmokeTest ? "point.3.connected.trianglepath.dotted" : "arrow.right"
                )
            }
            .buttonStyle(.bordered)

            Text("Bridge 測試使用合成 guest 位址與由 MCT 標頭模擬的 metadata；只驗證 host registry／upload bridge，不代表原始 guest runtime 已接通。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                capturedLoadObjReplay.toggle()
                if capturedLoadObjReplay { uploadBridgeSmokeTest = false }
            } label: {
                Label(
                    capturedLoadObjReplay ? "MVP-18 Load_Obj 回放：開" : "測試 MVP-18 Load_Obj 回放",
                    systemImage: capturedLoadObjReplay ? "memorychip.fill" : "memorychip"
                )
            }
            .buttonStyle(.bordered)

            Text("回放模式只接受已記錄的 2d_fnt_00.mct（17,450 bytes、固定 SHA-256），會依 MVP-18 實測位址重建 guest memory 欄位；這不是即時 ARMv6 執行。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                exportDecodedPNG()
            } label: {
                Label("匯出解碼後 RGBA8 PNG", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)

            if !exportMessage.isEmpty {
                Text(exportMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("重新載入合成樣本") {
                    sourceName = "內建合成樣本"
                    mctData = SyntheticMCTFixture.makeCheckerboard()
                    uploadBridgeSmokeTest = false
                    capturedLoadObjReplay = false
                    exportMessage = ""
                }
                .buttonStyle(.bordered)

                Button("匯入 .mct") { activeSheet = .importer }
                    .buttonStyle(.borderedProminent)
            }
            .font(.footnote)

            Text("本版本驗證 MCT 貼圖解碼與 Metal 顯示，不會執行 RE4 遊戲引擎。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .importer:
                MCTDocumentPicker { result in
                    activeSheet = nil
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
                            uploadBridgeSmokeTest = false
                            capturedLoadObjReplay = false
                            exportMessage = ""
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
            case .sharePNG(let url):
                PreviewActivityView(activityItems: [url])
            }
        }
    }

    private func exportDecodedPNG() {
        do {
            let decoded = try RE4MCTTextureDecoder.decode(mctData)
            let pngData = try MCTPNGExporter.makePNG(from: decoded)
            let baseName = URL(fileURLWithPath: sourceName)
                .deletingPathExtension()
                .lastPathComponent
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(baseName)_decoded_rgba.png")
            try pngData.write(to: outputURL, options: .atomic)
            exportMessage = "已產生 \(decoded.width) × \(decoded.height) PNG（\(pngData.count) bytes）。可在分享面板選擇「儲存到檔案」。"
            activeSheet = .sharePNG(outputURL)
        } catch {
            exportMessage = "PNG 匯出失敗：\(error.localizedDescription)"
        }
    }
}

private enum PreviewSheet: Identifiable {
    case importer
    case sharePNG(URL)

    var id: String {
        switch self {
        case .importer: return "importer"
        case .sharePNG(let url): return "share-\(url.lastPathComponent)"
        }
    }
}

private struct PreviewActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private enum MCTPNGExporter {
    static func makePNG(from texture: RE4MCTTextureData) throws -> Data {
        let expectedBytes = texture.width * texture.height * 4
        guard texture.rgba8.count == expectedBytes else {
            throw NSError(
                domain: "RE4MCTPNGExporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "RGBA8 長度不符：\(texture.rgba8.count)，預期 \(expectedBytes) bytes。"]
            )
        }

        guard let provider = CGDataProvider(data: texture.rgba8 as CFData) else {
            throw NSError(domain: "RE4MCTPNGExporter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立 PNG 像素資料提供者。"])
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            .union(.byteOrder32Big)
        guard let image = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: texture.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw NSError(domain: "RE4MCTPNGExporter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "無法從 RGBA8 建立 CGImage。"])
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "RE4MCTPNGExporter", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "無法建立 PNG 編碼器。"])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "RE4MCTPNGExporter", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "PNG 編碼未能完成。"])
        }
        return output as Data
    }
}

private struct MCTPreviewInfo {
    let width: Int
    let height: Int
    let format: UInt16
    let compression: UInt16
    let sourceBytes: Int
    let rgbaBytes: Int
    let transparentPixels: Int
    let blackPixels: Int
    let sha256: String
    let uploadPathNote: String
}

private struct MCTMetalPreview: UIViewRepresentable {
    let data: Data
    let blackAsTransparent: Bool
    let uploadBridgeSmokeTest: Bool
    let capturedLoadObjReplay: Bool
    let onResult: (MCTPreviewInfo?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        context.coordinator.onResult = onResult
        context.coordinator.load(
            data,
            blackAsTransparent: blackAsTransparent,
            uploadBridgeSmokeTest: uploadBridgeSmokeTest,
            capturedLoadObjReplay: capturedLoadObjReplay,
            into: view
        )
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onResult = onResult
        context.coordinator.load(
            data,
            blackAsTransparent: blackAsTransparent,
            uploadBridgeSmokeTest: uploadBridgeSmokeTest,
            capturedLoadObjReplay: capturedLoadObjReplay,
            into: uiView
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var onResult: (MCTPreviewInfo?, String?) -> Void
        private var renderer: RE4MetalTexturePreviewRenderer?
        private var loadedHash: String?
        private var loadedUploadBridgeSmokeTest: Bool?
        private var loadedCapturedLoadObjReplay: Bool?
        private var loadedInfo: MCTPreviewInfo?
        private var textureRegistry: RE4GuestTextureMetalRegistry?
        private var uploadBridge: RE4GuestTextureUploadBridge?
        private var nextMockGuestAddress: UInt32 = 0xF000_1000

        init(onResult: @escaping (MCTPreviewInfo?, String?) -> Void) {
            self.onResult = onResult
        }

        func load(
            _ data: Data,
            blackAsTransparent: Bool,
            uploadBridgeSmokeTest: Bool,
            capturedLoadObjReplay: Bool,
            into view: MTKView
        ) {
            let sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            renderer?.setBlackAsTransparentPreview(blackAsTransparent)
            if loadedHash == sourceHash,
               loadedUploadBridgeSmokeTest == uploadBridgeSmokeTest,
               loadedCapturedLoadObjReplay == capturedLoadObjReplay,
               let loadedInfo {
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

                let texture: MTLTexture
                let pathNote: String
                if capturedLoadObjReplay {
                    let registry: RE4GuestTextureMetalRegistry
                    if let existingRegistry = textureRegistry {
                        registry = existingRegistry
                    } else {
                        let newRegistry = RE4GuestTextureMetalRegistry(device: device)
                        textureRegistry = newRegistry
                        registry = newRegistry
                    }
                    let bridge: RE4GuestTextureUploadBridge
                    if let existingBridge = uploadBridge {
                        bridge = existingBridge
                    } else {
                        let newBridge = RE4GuestTextureUploadBridge(registry: registry)
                        uploadBridge = newBridge
                        bridge = newBridge
                    }
                    let replay = try RE4CapturedMVP18LoadObjReplay.make(sourceMCT: data)
                    let adapter = RE4GuestTextureLoadAdapter(bridge: bridge)
                    let uploaded = try adapter.didReturnFromNativeLoadObj(replay.context, guestMemory: replay.memory)
                    guard let byObject = registry.texture(forGuestObject: replay.context.guestObjectAddress),
                          byObject === uploaded,
                          let byMCE = bridge.texture(forNativeMCETexture: RE4CapturedMVP18LoadObjReplay.mceTexture),
                          byMCE === uploaded else {
                        throw NSError(domain: "RE4MCTPreview", code: 12,
                                      userInfo: [NSLocalizedDescriptionKey: "Captured Load_Obj replay failed: registry lookup mismatch."])
                    }
                    adapter.guestObjectDestroyed(replay.context.guestObjectAddress)
                    guard registry.texture(forGuestObject: replay.context.guestObjectAddress) == nil,
                          bridge.texture(forNativeMCETexture: RE4CapturedMVP18LoadObjReplay.mceTexture) == nil else {
                        throw NSError(domain: "RE4MCTPreview", code: 13,
                                      userInfo: [NSLocalizedDescriptionKey: "Captured Load_Obj replay failed: cleanup left a registry binding."])
                    }
                    texture = uploaded
                    pathNote = "MVP-18 Load_Obj adapter replay PASS；依記錄的 guest memory／MCE metadata 上傳，非即時 ARMv6 runtime。"
                } else if uploadBridgeSmokeTest {
                    let registry: RE4GuestTextureMetalRegistry
                    if let existingRegistry = textureRegistry {
                        registry = existingRegistry
                    } else {
                        let newRegistry = RE4GuestTextureMetalRegistry(device: device)
                        textureRegistry = newRegistry
                        registry = newRegistry
                    }

                    let bridge: RE4GuestTextureUploadBridge
                    if let existingBridge = uploadBridge {
                        bridge = existingBridge
                    } else {
                        let newBridge = RE4GuestTextureUploadBridge(registry: registry)
                        uploadBridge = newBridge
                        bridge = newBridge
                    }

                    // Synthetic tokens only: the public preview app has no original guest
                    // ARMv6 runtime or live native MCE table connected.
                    let guestObjectAddress = nextMockGuestAddress
                    let guestMceTextureAddress = nextMockGuestAddress &+ 1
                    nextMockGuestAddress &+= 2
                    let snapshot = RE4NativeGuestTextureSnapshot(
                        guestObjectAddress: guestObjectAddress,
                        guestMceTextureAddress: guestMceTextureAddress,
                        name: "BridgeSmokeTest",
                        sourceMCTBytes: data,
                        nativeWidth: decoded.width,
                        nativeHeight: decoded.height,
                        nativePixelFormat: UInt32(decoded.sourcePixelFormat)
                    )
                    let uploaded = try bridge.registerCompletedNativeLoad(snapshot)

                    guard let byObject = registry.texture(forGuestObject: guestObjectAddress),
                          byObject === uploaded,
                          let byMCE = bridge.texture(forNativeMCETexture: guestMceTextureAddress),
                          byMCE === uploaded else {
                        throw NSError(domain: "RE4MCTPreview", code: 10,
                                      userInfo: [NSLocalizedDescriptionKey: "Bridge smoke test failed: registry lookup did not return the uploaded texture."])
                    }

                    // The renderer retains this local MTLTexture after the registry binding
                    // is cleared, so this also verifies cleanup without blanking the preview.
                    bridge.guestObjectDestroyed(guestObjectAddress)
                    guard registry.texture(forGuestObject: guestObjectAddress) == nil,
                          bridge.texture(forNativeMCETexture: guestMceTextureAddress) == nil else {
                        throw NSError(domain: "RE4MCTPreview", code: 11,
                                      userInfo: [NSLocalizedDescriptionKey: "Bridge smoke test failed: guest-object cleanup left a registry binding."])
                    }

                    texture = uploaded
                    pathNote = "Upload Bridge／Registry PASS；使用合成 guest token，metadata 由 MCT 標頭模擬（非原始 guest runtime）。"
                } else {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba8Unorm,
                        width: decoded.width,
                        height: decoded.height,
                        mipmapped: false
                    )
                    descriptor.usage = [.shaderRead]
                    descriptor.storageMode = .shared
                    guard let directTexture = device.makeTexture(descriptor: descriptor) else {
                        throw NSError(domain: "RE4MCTPreview", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "無法建立 MTLTexture。"])
                    }
                    directTexture.label = "MCTPreview/\(decoded.width)x\(decoded.height)"
                    let copied = decoded.rgba8.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        directTexture.replace(
                            region: MTLRegionMake2D(0, 0, decoded.width, decoded.height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: decoded.bytesPerRow
                        )
                        return true
                    }
                    guard copied else {
                        throw NSError(domain: "RE4MCTPreview", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "RGBA8 buffer has no base address."])
                    }
                    texture = directTexture
                    pathNote = "直接 decoder → MTLTexture"
                }

                if let renderer {
                    renderer.setTexture(texture)
                    renderer.setBlackAsTransparentPreview(blackAsTransparent)
                } else {
                    let newRenderer = try RE4MetalTexturePreviewRenderer(view: view, texture: texture, device: device)
                    newRenderer.setBlackAsTransparentPreview(blackAsTransparent)
                    renderer = newRenderer
                }

                loadedHash = sourceHash
                loadedUploadBridgeSmokeTest = uploadBridgeSmokeTest
                loadedCapturedLoadObjReplay = capturedLoadObjReplay
                let rgba = [UInt8](decoded.rgba8)
                var transparentPixels = 0
                var blackPixels = 0
                for offset in stride(from: 0, to: rgba.count, by: 4) {
                    if rgba[offset + 3] < 255 { transparentPixels += 1 }
                    if rgba[offset] <= 1 && rgba[offset + 1] <= 1 &&
                       rgba[offset + 2] <= 1 && rgba[offset + 3] == 255 {
                        blackPixels += 1
                    }
                }
                let info = MCTPreviewInfo(
                    width: decoded.width,
                    height: decoded.height,
                    format: decoded.sourcePixelFormat,
                    compression: decoded.sourceCompression,
                    sourceBytes: data.count,
                    rgbaBytes: decoded.rgba8.count,
                    transparentPixels: transparentPixels,
                    blackPixels: blackPixels,
                    sha256: sourceHash,
                    uploadPathNote: pathNote
                )
                loadedInfo = info
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
