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
    @State private var armv6SelfTestMessage = ""
    @State private var machOTestMessage = ""
    @State private var machOMapTestMessage = ""
    @State private var machOReportMessage = ""
    @State private var machOMapReportMessage = ""
    @State private var machOImportPlanTestMessage = ""
    @State private var machOImportPlanReportMessage = ""
    @State private var machOHLEBindingReportMessage = ""
    @State private var machOEntryPreflightMessage = ""
    @State private var machOCallTargetAuditMessage = ""
    @State private var machODirectCallAuditMessage = ""
    @State private var machOStubTargetAuditMessage = ""
    @State private var machOStubSlotAuditMessage = ""
    @State private var machOLegacyDyldAuditMessage = ""
    @State private var machOLegacyRelocationAuditMessage = ""
    @State private var machOLegacyRelocationExportMessage = ""
    @State private var machOLegacyRelocationRecordLines: [String] = []
    @State private var machOLegacyRelocationPage = 0
    @State private var machOPointerFixupAuditMessage = ""
    @State private var loadedHLEBindingResult: RE4MachO32HLEBindingResult?
    @State private var loadedHLEDispatcher: RE4GuestARMv6HLEDispatcher?
    @State private var loadedMachOImage: RE4MachO32Image?
    @State private var mappedMachOMemory: RE4GuestARMv6Memory?
    @State private var sparseMemorySelfTestMessage = ""
    @State private var isMountingSharedCache = false
    @State private var sharedCacheMountReportMessage = ""
    @State private var sharedCacheBackingData: Data?
    @State private var sharedCacheSecurityScopedURL: URL?
    @State private var isApplyingExternalRelocations = false
    @State private var externalRelocationApplyMessage = ""
    @State private var externalRelocationApplyCSV = ""
    @State private var stagedRelocatedMemory: RE4GuestARMv6Memory?
    @State private var stageGRelocationTargetAddresses: [UInt32] = []
    @State private var isApplyingStageHImports = false
    @State private var stageHImportApplyMessage = ""
    @State private var stageHImportApplyCSV = ""
    @State private var stagedImportBindingMemory: RE4GuestARMv6Memory?
    @State private var isApplyingStageILazyPointers = false
    @State private var stageILazyPointerApplyMessage = ""
    @State private var stageILazyPointerApplyCSV = ""
    @State private var stageILazyPointerImageData: Data?
    @State private var stagedLazyPointerMemory: RE4GuestARMv6Memory?

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
                do {
                    sparseMemorySelfTestMessage = try RE4GuestARMv6Memory.runSparseRegionSelfTest()
                } catch {
                    sparseMemorySelfTestMessage = "Sparse Guest Memory self-test FAIL\n\(error.localizedDescription)"
                }
            } label: {
                Label("Sparse Guest Memory／R-W-X 權限自測", systemImage: "memorychip")
            }
            .buttonStyle(.borderedProminent)

            if !sparseMemorySelfTestMessage.isEmpty {
                Text(sparseMemorySelfTestMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(sparseMemorySelfTestMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                activeSheet = .sharedCacheImporter
            } label: {
                Label(
                    isMountingSharedCache ? "正在驗證／掛載 shared cache…" : "掛載 iOS 4.2.1 ARMv6 shared cache（slide=0）",
                    systemImage: isMountingSharedCache ? "hourglass" : "externaldrive.badge.plus"
                )
            }
            .buttonStyle(.bordered)
            .disabled(isMountingSharedCache || isApplyingExternalRelocations)

            if isMountingSharedCache {
                ProgressView("正在讀取 166.7 MB cache、計算 SHA-256 並驗證 mapping…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
            }

            if !sharedCacheMountReportMessage.isEmpty {
                Text(sharedCacheMountReportMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(sharedCacheMountReportMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !armv6SelfTestMessage.isEmpty {
                Text(armv6SelfTestMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(armv6SelfTestMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                do {
                    machOTestMessage = try RE4MachO32Parser.runSyntheticSelfTest()
                } catch {
                    machOTestMessage = "Mach-O parser self-test FAIL\n\(error.localizedDescription)"
                }
            } label: {
                Label("Mach-O 32-bit ARM 解析器自測", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.borderedProminent)

            if !machOTestMessage.isEmpty {
                Text(machOTestMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(machOTestMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                do {
                    machOMapTestMessage = try RE4MachO32Loader.runSyntheticSelfTest()
                } catch {
                    machOMapTestMessage = "Mach-O segment mapper self-test FAIL\n\(error.localizedDescription)"
                }
            } label: {
                Label("Mach-O Segment Mapper 自測", systemImage: "memorychip")
            }
            .buttonStyle(.borderedProminent)

            if !machOMapTestMessage.isEmpty {
                Text(machOMapTestMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(machOMapTestMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                activeSheet = .machOLoadImporter
            } label: {
                Label("載入 Mach-O 至 Guest Memory", systemImage: "memorychip.fill")
            }
            .buttonStyle(.bordered)
            .disabled(isApplyingExternalRelocations)

            if !machOMapReportMessage.isEmpty {
                Text(machOMapReportMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                activeSheet = .externalRelocationImporter
            } label: {
                Label(
                    isApplyingExternalRelocations
                        ? "Stage G：正在隔離套用 1,943 筆 relocation…"
                        : "Stage G：預檢並隔離套用 1,943 筆 external relocation",
                    systemImage: isApplyingExternalRelocations ? "hourglass" : "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isApplyingExternalRelocations || isApplyingStageHImports ||
                loadedMachOImage == nil ||
                mappedMachOMemory == nil ||
                sharedCacheBackingData == nil
            )

            if isApplyingExternalRelocations {
                ProgressView("正在核對原始記憶體、驗證候選 cache 位址，並建立獨立 staging memory…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
            }

            if !externalRelocationApplyMessage.isEmpty {
                Text(externalRelocationApplyMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(externalRelocationApplyMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !externalRelocationApplyCSV.isEmpty {
                Button {
                    exportExternalRelocationApplyCSV()
                } label: {
                    Label("匯出 1,943 筆 relocation staging read-back CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Button {
                activeSheet = .stageHImportPlanImporter
            } label: {
                Label(
                    isApplyingStageHImports
                        ? "Stage H：正在建立第二份隔離映像並套用 42 筆 imports…"
                        : "Stage H：驗證 672 筆匯入計畫，隔離套用 42 筆 non-lazy pointers",
                    systemImage: isApplyingStageHImports ? "hourglass" : "arrow.triangle.branch"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isApplyingStageHImports || isApplyingExternalRelocations ||
                stagedRelocatedMemory == nil || stageGRelocationTargetAddresses.count != 1_943 ||
                sharedCacheBackingData == nil
            )

            if isApplyingStageHImports {
                ProgressView("正在驗證 Stage H manifest、複製 Stage G __DATA，並建立第二份 Guest Memory…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
            }

            if !stageHImportApplyMessage.isEmpty {
                Text(stageHImportApplyMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(stageHImportApplyMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !stageHImportApplyCSV.isEmpty {
                Button {
                    exportStageHImportBindingCSV()
                } label: {
                    Label("匯出 42 筆 non-lazy binding read-back CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            Button {
                activeSheet = .stageILazyPlanImporter
            } label: {
                Label(
                    isApplyingStageILazyPointers
                        ? "Stage I-D：正在隔離套用 315 筆 lazy pointers…"
                        : "Stage I-D：隔離套用 315 筆 classic lazy pointers",
                    systemImage: isApplyingStageILazyPointers ? "hourglass" : "arrow.triangle.branch"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isApplyingStageILazyPointers || isApplyingStageHImports || isApplyingExternalRelocations ||
                loadedMachOImage == nil || stagedImportBindingMemory == nil ||
                stageHImportApplyCSV.isEmpty || stageGRelocationTargetAddresses.count != 1_943 ||
                sharedCacheBackingData == nil
            )

            Text("Stage I-D 會從已完成的 Stage H 建立第三份獨立 Guest Memory，只更新 315 個 lazy pointer slots；不執行 dyld helper、ARM 指令、HLE、initializer 或 constructor。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            if isApplyingStageILazyPointers {
                ProgressView("正在驗證 I-C 計畫、複製 Stage H __DATA，並逐筆讀回 315 個 lazy slots…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
            }

            if !stageILazyPointerApplyMessage.isEmpty {
                Text(stageILazyPointerApplyMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(stageILazyPointerApplyMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !stageILazyPointerApplyCSV.isEmpty {
                Button {
                    exportStageILazyPointerReadbackCSV()
                } label: {
                    Label("匯出 315 筆 lazy pointer read-back CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            if stageILazyPointerImageData != nil {
                Button {
                    exportStageILazyPointerImage()
                } label: {
                    Label("匯出 Stage I-D isolated ARMv6 image", systemImage: "externaldrive")
                }
                .buttonStyle(.bordered)
            }

            Button {
                do {
                    machOImportPlanTestMessage = try RE4MachO32ImportBindingPlanner.runSyntheticSelfTest()
                } catch {
                    machOImportPlanTestMessage = "Mach-O import binding plan self-test FAIL\n\(error.localizedDescription)"
                }
            } label: {
                Label("HLE 匯入繫結計畫自測", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderedProminent)

            if !machOImportPlanTestMessage.isEmpty {
                Text(machOImportPlanTestMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(machOImportPlanTestMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                if let loadedMachOImage {
                    do {
                        let guestSize = mappedMachOMemory?.size ?? 0x05000000
                        let plan = try RE4MachO32ImportBindingPlanner.makePlan(loadedMachOImage, guestMemorySize: guestSize)
                        machOImportPlanReportMessage = plan.report
                    } catch {
                        machOImportPlanReportMessage = "HLE 匯入計畫失敗：\(error.localizedDescription)"
                    }
                } else {
                    machOImportPlanReportMessage = "請先使用「載入 Mach-O 至 Guest Memory」選取 Res4。"
                }
            } label: {
                Label("產生 Res4 的 HLE 匯入計畫", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.bordered)

            if !machOImportPlanReportMessage.isEmpty {
                Text(machOImportPlanReportMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                do {
                    machOHLEBindingReportMessage = try RE4MachO32HLEBinder.runSyntheticSelfTest()
                } catch {
                    machOHLEBindingReportMessage = "HLE binder/dispatcher self-test FAIL\n\(error.localizedDescription)"
                }
            } label: {
                Label("HLE 指標繫結／呼叫回傳自測", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.borderedProminent)

            if !machOHLEBindingReportMessage.isEmpty {
                Text(machOHLEBindingReportMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(machOHLEBindingReportMessage.contains("PASS") ? .green : .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        let binding = try RE4MachO32HLEBinder.bind(image, into: memory)
                        loadedHLEBindingResult = binding
                        loadedHLEDispatcher = RE4GuestARMv6HLEDispatcher(
                            memory: memory, symbolByThunkAddress: binding.symbolByThunkAddress
                        )
                        machOHLEBindingReportMessage = binding.report
                    } catch {
                        machOHLEBindingReportMessage = "Res4 HLE 繫結失敗：\(error.localizedDescription)"
                    }
                } else {
                    machOHLEBindingReportMessage = "請先載入 Res4 至 Guest Memory，再套用 HLE 繫結。"
                }
            } label: {
                Label("套用已支援的 HLE 匯入繫結", systemImage: "link")
            }
            .buttonStyle(.bordered)
            .disabled(isApplyingExternalRelocations)

            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory, let entry = image.entryPoint {
                    do {
                        machOEntryPreflightMessage = try RE4ARMv6EntryPreflight.inspectEntryControlFlow(
                            entryPoint: entry, image: image, memory: memory, maxInstructions: 64
                        )
                    } catch {
                        machOEntryPreflightMessage = "Entry PC 預檢失敗：\(error.localizedDescription)"
                    }
                } else {
                    machOEntryPreflightMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("追蹤 Entry 控制流／Literal Pool（靜態）", systemImage: "list.number")
            }
            .buttonStyle(.borderedProminent)

            if !machOEntryPreflightMessage.isEmpty {
                Text(machOEntryPreflightMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOEntryPreflightMessage.contains("control-flow preflight PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        machOCallTargetAuditMessage = try RE4ARMv6EntryPreflight.inspectAddress(
                            0x00011FC0, label: "Entry BLX r12 target", image: image,
                            memory: memory, maxInstructions: 64
                        )
                    } catch {
                        machOCallTargetAuditMessage = "Call target audit failed：\(error.localizedDescription)"
                    }
                } else {
                    machOCallTargetAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("靜態檢查第一個呼叫目標 0x11FC0（不執行）", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)

            if !machOCallTargetAuditMessage.isEmpty {
                Text(machOCallTargetAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOCallTargetAuditMessage.contains("indirect target static audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }


            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    var reports = [String]()
                    for (address, label) in [
                        (UInt32(0x001A0558), "_main direct BL target #1"),
                        (UInt32(0x0019FC70), "_main direct BL target #2")
                    ] {
                        do {
                            reports.append(try RE4ARMv6EntryPreflight.inspectAddress(
                                address, label: label, image: image, memory: memory, maxInstructions: 64
                            ))
                        } catch {
                            reports.append(String(format: "%@ 0x%08X audit failed: %@",
                                                  label, address, error.localizedDescription))
                        }
                    }
                    machODirectCallAuditMessage = reports.joined(separator: "\n\n========== NEXT DIRECT TARGET ==========\n\n")
                } else {
                    machODirectCallAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("_main 直接呼叫目標 0x1A0558／0x19FC70（靜態）", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.borderedProminent)

            if !machODirectCallAuditMessage.isEmpty {
                Text(machODirectCallAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machODirectCallAuditMessage.contains("audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }


            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        machOStubTargetAuditMessage = try RE4ARMv6EntryPreflight.inspectAddress(
                            0x00008DD0, label: "Target reached by both imported-pointer stubs",
                            image: image, memory: memory, maxInstructions: 64
                        )
                    } catch {
                        machOStubTargetAuditMessage = "Stub target audit failed：\(error.localizedDescription)"
                    }
                } else {
                    machOStubTargetAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("靜態檢查 stub 共用跳轉目標 0x8DD0（不執行）", systemImage: "arrow.turn.down.right")
            }
            .buttonStyle(.borderedProminent)

            if !machOStubTargetAuditMessage.isEmpty {
                Text(machOStubTargetAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOStubTargetAuditMessage.contains("indirect target static audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        machOStubSlotAuditMessage = try RE4MachO32PointerFixupAudit.report(
                            image: image, memory: memory,
                            pointerSlotAddresses: [0x001C19F4, 0x001C16FC]
                        )
                    } catch {
                        machOStubSlotAuditMessage = "Stub slot audit failed：\(error.localizedDescription)"
                    }
                } else {
                    machOStubSlotAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("檢查 stub 指標槽 0x1C19F4／0x1C16FC（唯讀）", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderedProminent)

            if !machOStubSlotAuditMessage.isEmpty {
                Text(machOStubSlotAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOStubSlotAuditMessage.contains("audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }


            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        machOLegacyDyldAuditMessage = try RE4MachO32LegacyDyldAudit.report(
                            image: image, memory: memory, dyldSectionWordLimit: 16, lazySlotLimit: 48
                        )
                    } catch {
                        machOLegacyDyldAuditMessage = "Legacy dyld audit failed：\(error.localizedDescription)"
                    }
                } else {
                    machOLegacyDyldAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("檢查舊式 dyld lazy binding／__dyld 區段（唯讀）", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderedProminent)

            if !machOLegacyDyldAuditMessage.isEmpty {
                Text(machOLegacyDyldAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOLegacyDyldAuditMessage.contains("lazy-binding audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }


            Button {
                runLegacyRelocationAudit(exportToFile: false)
            } label: {
                Label("檢查 classic external relocations／符號 dylib 來源（唯讀）", systemImage: "point.topleft.down.curvedto.point.bottomright")
            }
            .buttonStyle(.borderedProminent)

            Button {
                runLegacyRelocationAudit(exportToFile: true)
            } label: {
                Label("一鍵匯出完整 relocation 報告（單一 TXT）", systemImage: "square.and.arrow.up.document")
            }
            .buttonStyle(.bordered)

            if !machOLegacyRelocationExportMessage.isEmpty {
                Text(machOLegacyRelocationExportMessage)
                    .font(.caption)
                    .foregroundStyle(machOLegacyRelocationExportMessage.hasPrefix("匯出完成") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !machOLegacyRelocationAuditMessage.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("稽核摘要")
                        .font(.headline)
                    ScrollView {
                        Text(machOLegacyRelocationAuditMessage)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(machOLegacyRelocationAuditMessage.contains("external relocation audit PASS") ? .green : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 300)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))

                    if !machOLegacyRelocationRecordLines.isEmpty {
                        let pageSize = 25
                        let total = machOLegacyRelocationRecordLines.count
                        let pageCount = (total + pageSize - 1) / pageSize
                        let start = min(machOLegacyRelocationPage * pageSize, max(0, total - 1))
                        let end = min(start + pageSize, total)
                        Text("完整 relocation 記錄")
                            .font(.headline)
                        Text("每頁 25 筆；可逐頁查看全部 \(total) 筆。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button {
                                machOLegacyRelocationPage = max(0, machOLegacyRelocationPage - 1)
                            } label: {
                                Label("上一頁", systemImage: "chevron.left")
                            }
                            .disabled(machOLegacyRelocationPage == 0)
                            Spacer(minLength: 4)
                            Text("\(start + 1)–\(end) / \(total)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button {
                                machOLegacyRelocationPage = min(pageCount - 1, machOLegacyRelocationPage + 1)
                            } label: {
                                Label("下一頁", systemImage: "chevron.right")
                            }
                            .disabled(machOLegacyRelocationPage >= pageCount - 1)
                        }
                        ScrollView {
                            Text(machOLegacyRelocationRecordLines[start..<end].joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxHeight: 380)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if let image = loadedMachOImage, let memory = mappedMachOMemory {
                    do {
                        machOPointerFixupAuditMessage = try RE4MachO32PointerFixupAudit.auditKnownRes4Entry(
                            image: image, memory: memory
                        )
                    } catch {
                        machOPointerFixupAuditMessage = "Pointer/fixup audit failed：\(error.localizedDescription)"
                    }
                } else {
                    machOPointerFixupAuditMessage = "請先載入 Res4 至 Guest Memory。"
                }
            } label: {
                Label("檢查 Entry 間接指標／Fixup（唯讀）", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderedProminent)

            if !machOPointerFixupAuditMessage.isEmpty {
                Text(machOPointerFixupAuditMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(machOPointerFixupAuditMessage.contains("audit PASS") ? .green : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Button {
                activeSheet = .machOImporter
            } label: {
                Label("檢查 Mach-O 執行檔", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)

            if !machOReportMessage.isEmpty {
                Text(machOReportMessage)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

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
                    armv6SelfTestMessage = ""
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
            case .sharedCacheImporter:
                // The dyld cache is extensionless on some Files providers. Use the
                // broad public.item type and copy-import mode, which is already proven
                // by the working MCT importer on this device.
                MCTDocumentPicker(contentTypes: [.item], asCopy: true) { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        mountSharedCache(from: url)
                    case .failed(let message):
                        sharedCacheMountReportMessage = "Shared cache 檔案選取失敗：\\(message)"
                    case .cancelled:
                        sharedCacheMountReportMessage = "已取消選取 shared cache，尚未修改 Guest Memory。"
                    }
                }
                .ignoresSafeArea()
            case .externalRelocationImporter:
                MCTDocumentPicker(contentTypes: [.item], asCopy: true) { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        startStageGExternalRelocationApply(from: url)
                    case .failed(let message):
                        externalRelocationApplyMessage = "Stage G 檔案選取失敗：\\(message)"
                    case .cancelled:
                        externalRelocationApplyMessage = "已取消 Stage G relocation overlay 選取；Guest Memory 未修改。"
                    }
                }
                .ignoresSafeArea()
            case .stageHImportPlanImporter:
                MCTDocumentPicker(contentTypes: [.item], asCopy: true) { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        startStageHImportBinding(from: url)
                    case .failed(let message):
                        stageHImportApplyMessage = "Stage H manifest 選取失敗：\\(message)"
                    case .cancelled:
                        stageHImportApplyMessage = "已取消 Stage H manifest 選取；Stage G 與原始 Guest Memory 均未修改。"
                    }
                }
                .ignoresSafeArea()
            case .stageILazyPlanImporter:
                MCTDocumentPicker(contentTypes: [.item], asCopy: true) { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        startStageILazyPointerApply(from: url)
                    case .failed(let message):
                        stageILazyPointerApplyMessage = "Stage I-C 計畫選取失敗：\(message)"
                    case .cancelled:
                        stageILazyPointerApplyMessage = "已取消 Stage I-C 計畫選取；Stage H 與原始 Guest Memory 均未修改。"
                    }
                }
                .ignoresSafeArea()
            case .machOLoadImporter:
                MCTDocumentPicker { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        do {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                            guard size > 0, size <= 512 * 1024 * 1024 else {
                                throw NSError(domain: "RE4MachOLoader", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "檔案大小必須介於 1 byte 與 512 MiB。"])
                            }
                            let binary = try Data(contentsOf: url, options: .mappedIfSafe)
                            let image = try RE4MachO32Parser.parse(binary)
                            mappedMachOMemory = nil
                            loadedMachOImage = nil
                            stagedRelocatedMemory = nil
                            stageGRelocationTargetAddresses = []
                            stagedImportBindingMemory = nil
                            stageHImportApplyMessage = ""
                            stageHImportApplyCSV = ""
                            stageILazyPointerApplyMessage = ""
            stageILazyPointerApplyCSV = ""
            stageILazyPointerImageData = nil
            stagedLazyPointerMemory = nil
                            externalRelocationApplyMessage = ""
                            externalRelocationApplyCSV = ""
                            loadedHLEBindingResult = nil
                            loadedHLEDispatcher = nil
                            machOHLEBindingReportMessage = ""
                            machOEntryPreflightMessage = ""
                            machOCallTargetAuditMessage = ""
                            machODirectCallAuditMessage = ""
                            machOStubTargetAuditMessage = ""
                            machOStubSlotAuditMessage = ""
                            machOLegacyDyldAuditMessage = ""
                            machOLegacyRelocationAuditMessage = ""
                            machOLegacyRelocationExportMessage = ""
                            machOLegacyRelocationRecordLines = []
                            machOLegacyRelocationPage = 0
                            machOPointerFixupAuditMessage = ""
                            let guestMemory = RE4GuestARMv6Memory(size: 0x05000000)
                            let mapResult = try RE4MachO32Loader.map(image, into: guestMemory)
                            var combinedMapReport = mapResult.report
                            if let cacheData = sharedCacheBackingData {
                                let cacheResult = try RE4IOS421SharedCacheMapper.mount(
                                    data: cacheData, into: guestMemory, slide: 0
                                )
                                combinedMapReport += "\n\n" + cacheResult.report
                            }
                            loadedMachOImage = image
                            mappedMachOMemory = guestMemory
                            machOMapReportMessage = "檔案：\(url.lastPathComponent)\n\(combinedMapReport)"
                        } catch {
                            machOMapReportMessage = "Mach-O segment mapping 失敗：\(url.lastPathComponent)\n\(error.localizedDescription)\n請選取 IPA 解壓後 .app 內的主執行檔，不是 IPA ZIP。"
                        }
                    case .failed(let message):
                        machOMapReportMessage = "檔案選取失敗：\(message)"
                    case .cancelled:
                        machOMapReportMessage = "已取消 Mach-O segment mapping。"
                    }
                }
                .ignoresSafeArea()
            case .machOImporter:
                MCTDocumentPicker { result in
                    activeSheet = nil
                    switch result {
                    case .picked(let url):
                        do {
                            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                            guard size > 0, size <= 512 * 1024 * 1024 else {
                                throw NSError(domain: "RE4MachOInspector", code: 1,
                                              userInfo: [NSLocalizedDescriptionKey: "檔案大小必須介於 1 byte 與 512 MiB。"])
                            }
                            let binary = try Data(contentsOf: url, options: .mappedIfSafe)
                            let image = try RE4MachO32Parser.parse(binary)
                            machOReportMessage = "檔案：\(url.lastPathComponent)\n\(image.inspectionReport)"
                        } catch {
                            machOReportMessage = "Mach-O 解析失敗：\(url.lastPathComponent)\n\(error.localizedDescription)\n若來源是 IPA，請先解壓縮並選取 .app 內的主執行檔，而不是整個 IPA。"
                        }
                    case .failed(let message):
                        machOReportMessage = "檔案選取失敗：\(message)"
                    case .cancelled:
                        machOReportMessage = "已取消 Mach-O 檔案選取。"
                    }
                }
                .ignoresSafeArea()
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
                            armv6SelfTestMessage = ""
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
            case .shareTextReport(let url):
                PreviewActivityView(activityItems: [url])
            }
        }
    }

    private func readCoordinatedSharedCache(from url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readData: Data?
        var readError: Error?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                readData = try Data(contentsOf: coordinatedURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let readData else {
            throw NSError(
                domain: "RE4SharedCacheImporter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Files provider 沒有交付可讀取的檔案。"]
            )
        }
        return readData
    }

    private func mountSharedCache(from url: URL) {
        guard !isMountingSharedCache else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        let existingMemory = mappedMachOMemory
        isMountingSharedCache = true
        sharedCacheMountReportMessage =
            "已選取：\\(url.lastPathComponent)\\n正在讀取檔案並驗證大小、SHA-256 和 8C148 mapping…"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Files providers may vend the document lazily; coordinate the read off the UI thread.
                let cacheData = try readCoordinatedSharedCache(from: url)
                let targetMemory = existingMemory ?? RE4GuestARMv6Memory(size: 0x05000000)

                guard !targetMemory.hasSparseRegion(named: "iOS421_SHARED_CACHE_TEXT_RX") else {
                    throw NSError(
                        domain: "RE4SharedCacheImporter",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "目前 Guest Memory 已掛載 8C148 shared cache。請重新載入 Res4 建立新的 Guest Memory 後，再掛載一次。"]
                    )
                }

                // The 166 MB SHA-256 and all mapping checks run on this background queue.
                let result = try RE4IOS421SharedCacheMapper.mount(
                    data: cacheData, into: targetMemory, slide: 0
                )

                DispatchQueue.main.async {
                    if let previousURL = sharedCacheSecurityScopedURL, previousURL != url {
                        previousURL.stopAccessingSecurityScopedResource()
                    }
                    sharedCacheBackingData = cacheData
                    sharedCacheSecurityScopedURL = accessed ? url : nil
                    mappedMachOMemory = targetMemory
                    stagedRelocatedMemory = nil
                            stageGRelocationTargetAddresses = []
                            stagedImportBindingMemory = nil
                            stageHImportApplyMessage = ""
                            stageHImportApplyCSV = ""
                    externalRelocationApplyMessage = ""
                    externalRelocationApplyCSV = ""
                    sharedCacheMountReportMessage = result.report
                    isMountingSharedCache = false
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    sharedCacheMountReportMessage =
                        "Shared cache mount FAIL\\n檔案：\\(url.lastPathComponent)\\n\\(error.localizedDescription)"
                    isMountingSharedCache = false
                }
            }
        }
    }

    private func startStageGExternalRelocationApply(from url: URL) {
        guard let image = loadedMachOImage,
              let originalMemory = mappedMachOMemory,
              let cacheData = sharedCacheBackingData else {
            externalRelocationApplyMessage =
                "Stage G blocked：請先掛載 8C148 shared cache，並載入 Res4 至同一個 Guest Memory。"
            return
        }

        do {
            let overlayData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard overlayData.count == 1_943 * 16 else {
                throw NSError(
                    domain: "RE4ExternalRelocationStager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "overlay 檔案大小應為 31,088 bytes，實際為 \\(overlayData.count)。"]
                )
            }

            isApplyingExternalRelocations = true
            externalRelocationApplyMessage =
                "已選取：\\(url.lastPathComponent)\\n正在驗證 Stage D overlay、原始 Res4 記憶體與 shared-cache 位址…"
            externalRelocationApplyCSV = ""
            stagedRelocatedMemory = nil
                            stageGRelocationTargetAddresses = []
                            stagedImportBindingMemory = nil
                            stageHImportApplyMessage = ""
                            stageHImportApplyCSV = ""
                            stageILazyPointerApplyMessage = ""
            stageILazyPointerApplyCSV = ""
            stageILazyPointerImageData = nil
            stagedLazyPointerMemory = nil

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try RE4ExternalRelocationStager.applyInIsolatedStaging(
                        image: image,
                        cacheData: cacheData,
                        originalMemory: originalMemory,
                        overlayData: overlayData
                    )
                    DispatchQueue.main.async {
                        stagedRelocatedMemory = result.stagingMemory
                        stageGRelocationTargetAddresses = result.relocationTargetAddresses
                        externalRelocationApplyMessage = result.report
                        externalRelocationApplyCSV = result.auditCSV
                        isApplyingExternalRelocations = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        stagedRelocatedMemory = nil
                            stageGRelocationTargetAddresses = []
                            stagedImportBindingMemory = nil
                            stageHImportApplyMessage = ""
                            stageHImportApplyCSV = ""
                        externalRelocationApplyMessage =
                            "Stage G external relocation apply FAIL\\n\\(error.localizedDescription)\\n原始 Guest Memory 未被此流程寫入。"
                        externalRelocationApplyCSV = ""
                        isApplyingExternalRelocations = false
                    }
                }
            }
        } catch {
            externalRelocationApplyMessage =
                "Stage G overlay 讀取失敗：\\(url.lastPathComponent)\\n\\(error.localizedDescription)"
        }
    }

    private func startStageHImportBinding(from url: URL) {
        guard let image = loadedMachOImage,
              let stageGMemory = stagedRelocatedMemory,
              let cacheData = sharedCacheBackingData,
              stageGRelocationTargetAddresses.count == 1_943 else {
            stageHImportApplyMessage =
                "Stage H blocked：請先完成 Stage G isolated external relocation apply，並保留同一個 shared cache 與 Res4。"
            return
        }

        do {
            let manifestData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard manifestData.count > 0, manifestData.count <= 2 * 1024 * 1024 else {
                throw NSError(
                    domain: "RE4ImportBindingStager",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Stage H CSV 大小超出允許範圍。"]
                )
            }
            isApplyingStageHImports = true
            stagedImportBindingMemory = nil
            stageHImportApplyCSV = ""
            stageILazyPointerApplyMessage = ""
            stageILazyPointerApplyCSV = ""
            stageILazyPointerImageData = nil
            stagedLazyPointerMemory = nil
            stageHImportApplyMessage =
                "已選取：\(url.lastPathComponent)\n正在核對 672 筆 Stage H manifest，並建立第二份隔離 Guest Memory…"

            let relocationTargets = stageGRelocationTargetAddresses
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try RE4IOS421ImportBindingStager.applyInIsolatedStaging(
                        image: image,
                        cacheData: cacheData,
                        stageGMemory: stageGMemory,
                        stageGRelocationTargets: relocationTargets,
                        manifestData: manifestData
                    )
                    DispatchQueue.main.async {
                        stagedImportBindingMemory = result.stagingMemory
                        stageHImportApplyMessage = result.report
                        stageHImportApplyCSV = result.auditCSV
                        isApplyingStageHImports = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        stagedImportBindingMemory = nil
                        stageHImportApplyMessage =
                            "Stage H isolated native import apply FAIL\n\(error.localizedDescription)\nStage G 與原始 Guest Memory 均未被此流程寫入。"
                        stageHImportApplyCSV = ""
                        isApplyingStageHImports = false
                    }
                }
            }
        } catch {
            stageHImportApplyMessage =
                "Stage H manifest 讀取失敗：\(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    private func exportStageHImportBindingCSV() {
        guard !stageHImportApplyCSV.isEmpty else { return }
        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RE4_StageH_NonLazy_Import_Readback_42.csv")
            try Data(stageHImportApplyCSV.utf8).write(to: outputURL, options: .atomic)
            activeSheet = .shareTextReport(outputURL)
        } catch {
            stageHImportApplyMessage += "\nCSV export failed: \(error.localizedDescription)"
        }
    }

    private func startStageILazyPointerApply(from url: URL) {
        guard let image = loadedMachOImage,
              let stageHMemory = stagedImportBindingMemory,
              let cacheData = sharedCacheBackingData,
              stageGRelocationTargetAddresses.count == 1_943,
              !stageHImportApplyCSV.isEmpty else {
            stageILazyPointerApplyMessage =
                "Stage I-D blocked：請先在同一個 App session 完成 Stage G 與 Stage H，並保留 shared cache、Res4 與 Stage H readback。"
            return
        }

        do {
            let planData = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !planData.isEmpty, planData.count <= 2 * 1024 * 1024 else {
                throw NSError(domain: "RE4LazyPointerStager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Stage I-C CSV 大小超出允許範圍。"])
            }
            isApplyingStageILazyPointers = true
            stagedLazyPointerMemory = nil
            stageILazyPointerApplyCSV = ""
            stageILazyPointerImageData = nil
            stageILazyPointerApplyMessage =
                "已選取：\(url.lastPathComponent)\n正在建立獨立 Stage I-D Guest Memory，Stage H source 將保持唯讀…"

            let relocationTargets = stageGRelocationTargetAddresses
            let stageHReadback = stageHImportApplyCSV
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try RE4IOS421LazyPointerStager.applyInIsolatedStaging(
                        image: image,
                        cacheData: cacheData,
                        stageHMemory: stageHMemory,
                        stageGRelocationTargets: relocationTargets,
                        stageHReadbackCSV: stageHReadback,
                        planData: planData
                    )
                    DispatchQueue.main.async {
                        stagedLazyPointerMemory = result.stagingMemory
                        stageILazyPointerApplyMessage = result.report
                        stageILazyPointerApplyCSV = result.auditCSV
                        stageILazyPointerImageData = result.imageData
                        isApplyingStageILazyPointers = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        stagedLazyPointerMemory = nil
                        stageILazyPointerApplyMessage =
                            "Stage I-D isolated lazy pointer apply FAIL\n\(error.localizedDescription)\nStage H source、Stage G source、原始 Guest Memory 與 IPA 均未被此流程寫入。"
                        stageILazyPointerApplyCSV = ""
                        stageILazyPointerImageData = nil
                        isApplyingStageILazyPointers = false
                    }
                }
            }
        } catch {
            stageILazyPointerApplyMessage =
                "Stage I-C 計畫讀取失敗：\(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    private func exportStageILazyPointerReadbackCSV() {
        guard !stageILazyPointerApplyCSV.isEmpty else { return }
        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RE4_StageI_D_Lazy_Pointer_Readback_315.csv")
            try Data(stageILazyPointerApplyCSV.utf8).write(to: outputURL, options: .atomic)
            activeSheet = .shareTextReport(outputURL)
        } catch {
            stageILazyPointerApplyMessage += "\nCSV export failed: \(error.localizedDescription)"
        }
    }

    private func exportStageILazyPointerImage() {
        guard let imageData = stageILazyPointerImageData else { return }
        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RE4_StageI_D_Lazy_Prebound_Isolated_ARMv6.bin")
            try imageData.write(to: outputURL, options: .atomic)
            activeSheet = .shareTextReport(outputURL)
        } catch {
            stageILazyPointerApplyMessage += "\nImage export failed: \(error.localizedDescription)"
        }
    }

    private func exportExternalRelocationApplyCSV() {
        guard !externalRelocationApplyCSV.isEmpty else { return }
        do {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RE4_StageG_External_Relocation_Readback_1943.csv")
            try Data(externalRelocationApplyCSV.utf8).write(to: outputURL, options: .atomic)
            activeSheet = .shareTextReport(outputURL)
        } catch {
            externalRelocationApplyMessage += "\\nCSV export failed: \\(error.localizedDescription)"
        }
    }

    private func runLegacyRelocationAudit(exportToFile: Bool) {
        machOLegacyRelocationPage = 0
        machOLegacyRelocationRecordLines = []

        guard let image = loadedMachOImage, let memory = mappedMachOMemory else {
            machOLegacyRelocationAuditMessage = "請先載入 Res4 至 Guest Memory。"
            if exportToFile {
                machOLegacyRelocationExportMessage = "匯出失敗：請先載入 Res4 至 Guest Memory。"
            }
            return
        }

        let report = RE4MachO32LegacyRelocationAudit.report(
            image: image, memory: memory, exampleLimit: 24
        )

        let summaryMarker = "[Representative relocation records]"
        let recordsMarker = "[All external relocation records, sorted by target address]"
        if let summaryRange = report.range(of: summaryMarker),
           let recordsRange = report.range(of: recordsMarker),
           summaryRange.lowerBound < recordsRange.lowerBound {
            machOLegacyRelocationAuditMessage = String(report[..<summaryRange.lowerBound])
            let recordsText = String(report[recordsRange.upperBound...])
            machOLegacyRelocationRecordLines = recordsText
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("#") }
        } else {
            machOLegacyRelocationAuditMessage = report
                .components(separatedBy: "\n")
                .prefix(70)
                .joined(separator: "\n")
            machOLegacyRelocationAuditMessage += "\n\n報告格式未能辨識；畫面僅顯示摘要。完整原始報告仍可匯出。"
        }

        guard exportToFile else { return }

        do {
            let recordCount = image.dynamicExternalRelocations.count
            let timestampFormatter = DateFormatter()
            timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
            timestampFormatter.timeZone = TimeZone.current
            timestampFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let timestamp = timestampFormatter.string(from: Date())
            let exportedAt = ISO8601DateFormatter().string(from: Date())

            let exportHeader = """
            RE4Mobile-iOS26 — Complete External Relocation Audit
            Exported at: \(exportedAt)
            Architecture: \(image.architectureName)
            External relocation records declared: \(recordCount)
            Report encoding: UTF-8
            Safety: read-only inventory; no relocation applied, no pointer changed, no guest instruction executed.

            ============================================================
            COMPLETE AUDIT REPORT
            ============================================================

            """
            let completeReport = exportHeader + report + "\n"
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RE4_External_Relocation_Audit_\(recordCount)_\(timestamp).txt")
            try Data(completeReport.utf8).write(to: outputURL, options: .atomic)

            let detailCount = report
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("#") }
                .count
            machOLegacyRelocationExportMessage = "匯出完成：\(recordCount) 筆 relocation；明細列辨識數：\(detailCount)；\(completeReport.utf8.count) bytes。請在分享面板選擇「儲存到檔案」。"
            activeSheet = .shareTextReport(outputURL)
        } catch {
            machOLegacyRelocationExportMessage = "匯出失敗：\(error.localizedDescription)"
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
    case sharedCacheImporter
    case externalRelocationImporter
    case stageHImportPlanImporter
    case stageILazyPlanImporter
    case machOImporter
    case machOLoadImporter
    case sharePNG(URL)
    case shareTextReport(URL)

    var id: String {
        switch self {
        case .importer: return "importer"
        case .sharedCacheImporter: return "shared-cache-importer"
        case .externalRelocationImporter: return "external-relocation-importer"
        case .stageHImportPlanImporter: return "stage-h-import-plan-importer"
        case .stageILazyPlanImporter: return "stage-i-lazy-plan-importer"
        case .machOImporter: return "macho-importer"
        case .machOLoadImporter: return "macho-load-importer"
        case .sharePNG(let url): return "share-\(url.lastPathComponent)"
        case .shareTextReport(let url): return "share-report-\(url.lastPathComponent)"
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
