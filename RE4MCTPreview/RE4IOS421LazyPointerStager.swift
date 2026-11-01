import Foundation
import CryptoKit

/// Stage I-D performs eager prebinding of the 315 classic lazy slots in a
/// third, newly-created Guest Memory. Stage H memory is treated as immutable.
/// This does NOT execute dyld, the lazy helper, guest code, HLE, or initializers.
public enum RE4IOS421LazyPointerStager {
    public static let expectedPlanSHA256 = "816db39d2f036bed2e803dd8ca3ca7de50cb423a12d1e4e5fbf5048ed2074b94"
    public static let expectedPlanRows = 315
    public static let expectedStageHImageSHA256 = "ec3d8a0f66411ffddb7601772d7a60cb0006bfe92b08463547df0f9a77905094"
    public static let expectedStageIDImageSHA256 = "f80eb88ac28548bb9208bfd18d399e82be9d6bce790c0b891066fbe83ff4afd4"
    public static let expectedRes4ThinSHA256 = "2067760a8c5d1d5bb6b4d7bde55b698406386fb25141fb5fe8cf4bc20d6938ed"
    public static let expectedCacheSHA256 = "ab9dbbc1e7efcc6e8c7f79d20f90dab62d4309be5269a2055e3cd5136a62d024"
    public static let expectedChangedByteCount = 1251

    private static let imageBaseVA: UInt32 = 0x00001000
    private static let imageEndVA: UInt32 = 0x003A4000
    private static let imageByteCount = 0x003A3000
    private static let lazyHelperVA: UInt32 = 0x00008DD0

    private static let planHeader = [
        "Stub_VA", "Stub_File_Offset", "Stub_Indirect_Local_Index", "Lazy_Pointer_VA",
        "Lazy_File_Offset", "Lazy_Index_Within_Section", "Lazy_Indirect_Table_Index",
        "Original_Lazy_Pointer_Value", "Res4_Nlist_Symbol_Index", "Res4_Nlist_Type_Hex",
        "Res4_Nlist_Desc_Hex", "Res4_Nlist_Undefined_Symbol", "Symbol_Name", "Dylib_Ordinal",
        "Provider_Dylib", "Provider_Nlist_Index", "Provider_N_Type_Hex", "Provider_N_Sect",
        "Provider_N_Desc_Hex", "Provider_N_Value", "N_ARM_THUMB_DEF",
        "Expected_Lazy_Pointer_Value", "Expected_Write_Bytes_LE", "Target_Canonical_Code_Address",
        "Target_Segment", "Provider_Text_VM_Start", "Provider_Text_VM_End_Exclusive",
        "Provider_Text_Permissions", "Shared_Cache_Region", "Shared_Cache_VM_Start",
        "Shared_Cache_VM_End_Exclusive", "Shared_Cache_Permissions", "Shared_Cache_File_Offset",
        "Candidate_First_4_Bytes_Hex", "Resolver_Provenance", "DryRun_Status", "Proposed_Action",
        "Guest_Memory_Write", "IPA_Modified", "StageH_Image_Modified", "Guest_Code_Executed"
    ]

    private static let stageHReadbackHeader = [
        "Index", "Site_Address", "File_Offset", "Symbol_Index", "Symbol_Name", "Provider_Dylib",
        "Provider_N_Value", "N_ARM_THUMB_DEF", "Resolved_Candidate_Pointer", "Cache_Segment",
        "Cache_Protection", "Staging_Readback", "Lazy_Pointer_Preserved", "Stub_Preserved",
        "StageG_Source_Unchanged"
    ]

    public struct ApplyResult {
        public let report: String
        public let auditCSV: String
        public let imageData: Data
        public let stagingMemory: RE4GuestARMv6Memory
    }

    private struct PlanRow {
        let stubVA: UInt32
        let stubFileOffset: UInt32
        let stubIndirectIndex: UInt32
        let lazyVA: UInt32
        let lazyFileOffset: UInt32
        let lazyIndex: UInt32
        let lazyIndirectIndex: UInt32
        let original: UInt32
        let symbolIndex: UInt32
        let symbol: String
        let ordinal: Int
        let provider: String
        let providerNValue: UInt32
        let isThumb: Bool
        let candidate: UInt32
        let writeBytes: Data
        let canonicalTarget: UInt32
        let targetSegment: String
        let providerTextStart: UInt32
        let providerTextEnd: UInt32
        let providerTextPermissions: String
        let cacheRegion: String
        let cacheVMStart: UInt32
        let cacheVMEnd: UInt32
        let cachePermissions: String
        let candidateFirstBytes: String
        let provenance: String
        let dryRunStatus: String
        let proposedAction: String
        let guestWrite: String
        let ipaModified: String
        let stageHModified: String
        let guestExecuted: String
    }

    private struct NonLazyReadback {
        let site: UInt32
        let fileOffset: UInt32
        let symbolIndex: UInt32
        let symbol: String
        let provider: String
        let candidate: UInt32
        let readback: UInt32
    }

    private enum StageError: Error, LocalizedError {
        case prerequisite(String)
        case input(String)
        case row(Int, String)
        case staging(String)

        var errorDescription: String? {
            switch self {
            case .prerequisite(let s): return "Stage I-D blocked: \(s)"
            case .input(let s): return "Stage I-D input rejected: \(s)"
            case .row(let n, let s): return "Stage I-D row #\(n) rejected: \(s)"
            case .staging(let s): return "Stage I-D isolated apply failed: \(s)"
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
        (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func hex32(_ value: String, _ field: String, _ row: Int) throws -> UInt32 {
        let raw = (value.hasPrefix("0x") || value.hasPrefix("0X")) ? String(value.dropFirst(2)) : value
        guard let result = UInt32(raw, radix: 16) else {
            throw StageError.row(row, "\(field) is not a UInt32 hexadecimal value")
        }
        return result
    }

    private static func decimal(_ value: String, _ field: String, _ row: Int) throws -> Int {
        guard let result = Int(value), result >= 0 else {
            throw StageError.row(row, "\(field) is not a non-negative integer")
        }
        return result
    }

    private static func bool(_ value: String, _ field: String, _ row: Int) throws -> Bool {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: throw StageError.row(row, "\(field) must be true or false")
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// RFC-4180 parser supporting quoted commas, escaped quotes, CRLF and UTF-8 BOM.
    private static func csvRecords(_ data: Data) throws -> [[String]] {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw StageError.input("CSV is not valid UTF-8")
        }
        let text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        let chars = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    guard field.isEmpty else { throw StageError.input("misplaced CSV quote") }
                    quoted = true
                case ",":
                    row.append(field); field = ""
                case "\r":
                    if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                case "\n":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        guard !quoted else { throw StageError.input("unterminated CSV quote") }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func decodePlan(_ data: Data) throws -> [PlanRow] {
        let actual = sha256(data)
        guard actual == expectedPlanSHA256 else {
            throw StageError.input("Stage I-C plan SHA-256 mismatch: \(actual)")
        }
        let records = try csvRecords(data)
        guard records.first == planHeader else {
            throw StageError.input("expected the pinned 41-column Stage I-C CSV header")
        }
        guard records.count == expectedPlanRows + 1 else {
            throw StageError.input("expected 315 plan rows; found \(max(0, records.count - 1))")
        }
        var output: [PlanRow] = []
        output.reserveCapacity(expectedPlanRows)
        for (i, fields) in records.dropFirst().enumerated() {
            let row = i + 1
            guard fields.count == planHeader.count else { throw StageError.row(row, "expected 41 columns") }
            func v(_ key: String) -> String { fields[planHeader.firstIndex(of: key)!] }
            let writeBytesRaw = v("Expected_Write_Bytes_LE")
            guard writeBytesRaw.count == 8, let writeBytes = Data(hexString: writeBytesRaw) else {
                throw StageError.row(row, "Expected_Write_Bytes_LE must contain exactly 4 bytes")
            }
            output.append(PlanRow(
                stubVA: try hex32(v("Stub_VA"), "Stub_VA", row),
                stubFileOffset: try hex32(v("Stub_File_Offset"), "Stub_File_Offset", row),
                stubIndirectIndex: UInt32(try decimal(v("Stub_Indirect_Local_Index"), "Stub_Indirect_Local_Index", row)),
                lazyVA: try hex32(v("Lazy_Pointer_VA"), "Lazy_Pointer_VA", row),
                lazyFileOffset: try hex32(v("Lazy_File_Offset"), "Lazy_File_Offset", row),
                lazyIndex: UInt32(try decimal(v("Lazy_Index_Within_Section"), "Lazy_Index_Within_Section", row)),
                lazyIndirectIndex: UInt32(try decimal(v("Lazy_Indirect_Table_Index"), "Lazy_Indirect_Table_Index", row)),
                original: try hex32(v("Original_Lazy_Pointer_Value"), "Original_Lazy_Pointer_Value", row),
                symbolIndex: UInt32(try decimal(v("Res4_Nlist_Symbol_Index"), "Res4_Nlist_Symbol_Index", row)),
                symbol: v("Symbol_Name"),
                ordinal: try decimal(v("Dylib_Ordinal"), "Dylib_Ordinal", row),
                provider: v("Provider_Dylib"),
                providerNValue: try hex32(v("Provider_N_Value"), "Provider_N_Value", row),
                isThumb: try bool(v("N_ARM_THUMB_DEF"), "N_ARM_THUMB_DEF", row),
                candidate: try hex32(v("Expected_Lazy_Pointer_Value"), "Expected_Lazy_Pointer_Value", row),
                writeBytes: writeBytes,
                canonicalTarget: try hex32(v("Target_Canonical_Code_Address"), "Target_Canonical_Code_Address", row),
                targetSegment: v("Target_Segment"),
                providerTextStart: try hex32(v("Provider_Text_VM_Start"), "Provider_Text_VM_Start", row),
                providerTextEnd: try hex32(v("Provider_Text_VM_End_Exclusive"), "Provider_Text_VM_End_Exclusive", row),
                providerTextPermissions: v("Provider_Text_Permissions"),
                cacheRegion: v("Shared_Cache_Region"),
                cacheVMStart: try hex32(v("Shared_Cache_VM_Start"), "Shared_Cache_VM_Start", row),
                cacheVMEnd: try hex32(v("Shared_Cache_VM_End_Exclusive"), "Shared_Cache_VM_End_Exclusive", row),
                cachePermissions: v("Shared_Cache_Permissions"),
                candidateFirstBytes: v("Candidate_First_4_Bytes_Hex").lowercased(),
                provenance: v("Resolver_Provenance"),
                dryRunStatus: v("DryRun_Status"),
                proposedAction: v("Proposed_Action"),
                guestWrite: v("Guest_Memory_Write"),
                ipaModified: v("IPA_Modified"),
                stageHModified: v("StageH_Image_Modified"),
                guestExecuted: v("Guest_Code_Executed")
            ))
        }
        return output
    }

    private static func decodeStageHReadback(_ text: String) throws -> [NonLazyReadback] {
        let records = try csvRecords(Data(text.utf8))
        guard records.first == stageHReadbackHeader else {
            throw StageError.input("Stage H readback CSV does not have the expected 15-column header")
        }
        guard records.count == 43 else {
            throw StageError.input("Stage H readback must contain exactly 42 non-lazy rows")
        }
        var output: [NonLazyReadback] = []
        for (i, fields) in records.dropFirst().enumerated() {
            let row = i + 1
            guard fields.count == stageHReadbackHeader.count else { throw StageError.row(row, "Stage H readback column count mismatch") }
            func v(_ key: String) -> String { fields[stageHReadbackHeader.firstIndex(of: key)!] }
            let result = NonLazyReadback(
                site: try hex32(v("Site_Address"), "Site_Address", row),
                fileOffset: try hex32(v("File_Offset"), "File_Offset", row),
                symbolIndex: UInt32(try decimal(v("Symbol_Index"), "Symbol_Index", row)),
                symbol: v("Symbol_Name"),
                provider: v("Provider_Dylib"),
                candidate: try hex32(v("Resolved_Candidate_Pointer"), "Resolved_Candidate_Pointer", row),
                readback: try hex32(v("Staging_Readback"), "Staging_Readback", row)
            )
            guard result.candidate == result.readback,
                  v("Lazy_Pointer_Preserved").lowercased() == "true",
                  v("Stub_Preserved").lowercased() == "true",
                  v("StageG_Source_Unchanged").lowercased() == "true" else {
                throw StageError.row(row, "Stage H readback contains a failed preservation/result marker")
            }
            output.append(result)
        }
        guard Set(output.map(\.site)).count == 42 else {
            throw StageError.input("Stage H readback contains duplicate non-lazy sites")
        }
        return output
    }

    private static func snapshot(_ memory: RE4GuestARMv6Memory,
                                 image: RE4MachO32Image) throws -> Data {
        let segments = image.segments.filter { ["__TEXT", "__DATA", "__LINKEDIT"].contains($0.name) }
            .sorted { $0.vmAddress < $1.vmAddress }
        guard segments.count == 3 else { throw StageError.prerequisite("expected three Res4 loadable segments") }
        var data = Data()
        data.reserveCapacity(imageByteCount)
        var next = UInt64(imageBaseVA)
        for segment in segments {
            guard UInt64(segment.vmAddress) == next else {
                throw StageError.prerequisite("Res4 segment snapshot has a gap or overlap")
            }
            data.append(try memory.copyBytes(at: segment.vmAddress, count: Int(segment.vmSize)))
            next = segment.vmEnd
        }
        guard next == UInt64(imageEndVA), data.count == imageByteCount else {
            throw StageError.prerequisite("Res4 compact snapshot size/end mismatch")
        }
        return data
    }

    private static func compactOffset(_ va: UInt32) throws -> Int {
        guard va >= imageBaseVA, va < imageEndVA else {
            throw StageError.prerequisite(String(format: "Res4 VA 0x%08X outside compact image", va))
        }
        return Int(va - imageBaseVA)
    }

    /// Creates an independent Guest Memory, clones Stage H __DATA into it,
    /// and eagerly pre-populates only the 315 classic lazy slots.
    public static func applyInIsolatedStaging(
        image: RE4MachO32Image,
        cacheData: Data,
        stageHMemory: RE4GuestARMv6Memory,
        stageGRelocationTargets: [UInt32],
        stageHReadbackCSV: String,
        planData: Data
    ) throws -> ApplyResult {
        guard image.cpuType == 12, (image.cpuSubtype & 0x00FF_FFFF) == 6,
              image.fileType == 2, image.wasUniversal, image.selectedSliceOffset == 0x1000,
              image.fileBytes.count == 3_795_728 else {
            throw StageError.prerequisite("selected executable is not the pinned universal Res4 ARMv6 slice")
        }
        let thinHash = sha256(image.fileBytes)
        guard thinHash == expectedRes4ThinSHA256 else {
            throw StageError.prerequisite("Res4 ARMv6 thin-slice SHA-256 mismatch: \(thinHash)")
        }
        guard cacheData.count == RE4IOS421SharedCacheMapper.expectedSize,
              sha256(cacheData) == expectedCacheSHA256 else {
            throw StageError.prerequisite("iOS 4.2.1 shared-cache size/hash mismatch")
        }
        for name in ["iOS421_SHARED_CACHE_TEXT_RX", "iOS421_SHARED_CACHE_LINKEDIT_RO",
                     "iOS421_SHARED_CACHE_CODE_SIGNATURE_RO", "iOS421_SHARED_CACHE_DATA_RW"] {
            guard stageHMemory.hasSparseRegion(named: name) else {
                throw StageError.prerequisite("Stage H memory missing sparse cache region \(name)")
            }
        }
        guard stageGRelocationTargets.count == 1_943,
              Set(stageGRelocationTargets).count == 1_943 else {
            throw StageError.prerequisite("Stage G must supply 1,943 unique relocation target addresses")
        }

        let textSegment = image.segments.first { $0.name == "__TEXT" }
        let dataSegment = image.segments.first { $0.name == "__DATA" }
        let linkeditSegment = image.segments.first { $0.name == "__LINKEDIT" }
        guard textSegment?.vmAddress == 0x00001000, textSegment?.vmSize == 0x001C0000,
              textSegment?.fileOffset == 0, textSegment?.fileSize == 0x001C0000,
              textSegment?.initialProtection == 5,
              dataSegment?.vmAddress == 0x001C1000, dataSegment?.vmSize == 0x00022000,
              dataSegment?.fileOffset == 0x001C0000, dataSegment?.fileSize == 0x0001E000,
              dataSegment?.initialProtection == 3,
              linkeditSegment?.vmAddress == 0x001E3000, linkeditSegment?.vmSize == 0x001C1000,
              linkeditSegment?.fileOffset == 0x001DE000,
              linkeditSegment?.initialProtection == 1,
              let dataSegment else {
            throw StageError.prerequisite("Res4 __TEXT/__DATA/__LINKEDIT layout differs from pinned image")
        }

        let rows = try decodePlan(planData)
        let nonLazyRows = try decodeStageHReadback(stageHReadbackCSV)
        let sourceBefore = try snapshot(stageHMemory, image: image)
        let sourceBeforeHash = sha256(sourceBefore)
        guard sourceBeforeHash == expectedStageHImageSHA256 else {
            throw StageError.prerequisite("Stage H source image hash mismatch: \(sourceBeforeHash)")
        }

        // Rebuild parsed indirect-import lookup directly from the selected Res4 Mach-O.
        var parsedByKey: [String: RE4MachO32IndirectImport] = [:]
        var typeCounts: [UInt32: Int] = [:]
        for item in image.indirectImports {
            let key = "\(item.slotAddress):\(item.sectionType)"
            guard parsedByKey[key] == nil else { throw StageError.prerequisite("duplicate parsed indirect-import site") }
            parsedByKey[key] = item
            typeCounts[item.sectionType, default: 0] += 1
        }
        guard image.indirectImports.count == 672,
              typeCounts[6] == 42, typeCounts[7] == 315, typeCounts[8] == 315 else {
            throw StageError.prerequisite("parsed Res4 import-site distribution is not 42/315/315")
        }

        // Confirm Stage H's 42 non-lazy pointers are present in its immutable source.
        var nonLazySites = Set<UInt32>()
        for (i, readback) in nonLazyRows.enumerated() {
            guard nonLazySites.insert(readback.site).inserted,
                  let parsed = parsedByKey["\(readback.site):6"],
                  parsed.entrySize == 4,
                  parsed.symbolIndex == readback.symbolIndex,
                  parsed.symbolName == readback.symbol else {
                throw StageError.row(i + 1, "Stage H non-lazy readback does not match Res4 LC_DYSYMTAB metadata")
            }
            let fileOffset = UInt64(dataSegment.fileOffset) + UInt64(readback.site - dataSegment.vmAddress)
            guard fileOffset == UInt64(readback.fileOffset),
                  try stageHMemory.read32(readback.site) == readback.readback else {
                throw StageError.row(i + 1, "Stage H non-lazy pointer bytes/readback mismatch")
            }
        }
        guard Set(image.indirectImports.filter { $0.sectionType == 6 }.map(\.slotAddress)) == nonLazySites else {
            throw StageError.prerequisite("Stage H readback does not cover every parsed non-lazy pointer")
        }

        // Capture Stage G relocation words, and reject overlap with any lazy destination.
        var relocationWords: [UInt32: UInt32] = [:]
        relocationWords.reserveCapacity(stageGRelocationTargets.count)
        for va in stageGRelocationTargets {
            guard UInt64(va) + 4 <= UInt64(imageEndVA) else {
                throw StageError.prerequisite(String(format: "Stage G target 0x%08X outside Res4 image", va))
            }
            relocationWords[va] = try stageHMemory.read32(va)
        }

        let lazyParsed = image.indirectImports.filter { $0.sectionType == 7 }
        let stubParsed = image.indirectImports.filter { $0.sectionType == 8 }
        var seenLazy = Set<UInt32>()
        var seenStub = Set<UInt32>()
        var seenSymbols = Set<String>()
        var rowsByLazy: [(PlanRow, RE4MachO32IndirectImport, RE4MachO32IndirectImport)] = []
        rowsByLazy.reserveCapacity(rows.count)

        for (i, row) in rows.enumerated() {
            let number = i + 1
            guard row.original == lazyHelperVA,
                  row.guestWrite == "NO", row.ipaModified == "NO",
                  row.stageHModified == "NO", row.guestExecuted == "NO",
                  row.dryRunStatus == "PASS_STATIC_CANDIDATE_ONLY",
                  row.proposedAction == "PLAN_ONLY_NO_WRITE",
                  row.provenance == "StageH_357_provider_nlist_and_cache_audit_plus_StageE_address_map" else {
                throw StageError.row(number, "I-C plan safety/provenance markers are not pinned")
            }
            guard seenLazy.insert(row.lazyVA).inserted,
                  seenStub.insert(row.stubVA).inserted,
                  seenSymbols.insert(row.symbol).inserted else {
                throw StageError.row(number, "duplicate lazy slot, stub, or imported symbol")
            }
            guard let lazy = parsedByKey["\(row.lazyVA):7"],
                  let stub = parsedByKey["\(row.stubVA):8"],
                  lazy.entrySize == 4, stub.entrySize == 12, stub.isStub,
                  lazy.symbolIndex == row.symbolIndex, stub.symbolIndex == row.symbolIndex,
                  lazy.symbolName == row.symbol, stub.symbolName == row.symbol,
                  lazy.indirectTableIndex == row.lazyIndirectIndex,
                  stub.indirectTableIndex == row.stubIndirectIndex else {
                throw StageError.row(number, "I-C row does not match parsed lazy/stub indirect-symbol metadata")
            }
            let lazyIndex = UInt32((UInt64(row.lazyVA) - 0x001C1598) / 4)
            guard row.lazyVA == 0x001C1598 + lazyIndex * 4,
                  row.lazyIndex == lazyIndex, row.lazyIndirectIndex == 426 + lazyIndex,
                  row.stubVA == 0x0019F844 + UInt32(number - 1) * 12,
                  row.stubIndirectIndex == UInt32(number - 1) else {
                throw StageError.row(number, "lazy/stub section index arithmetic mismatch")
            }
            let lazyFileOffset = UInt64(dataSegment.fileOffset) + UInt64(row.lazyVA - dataSegment.vmAddress)
            guard lazyFileOffset == UInt64(row.lazyFileOffset),
                  Int(row.lazyFileOffset) + 4 <= image.fileBytes.count,
                  try stageHMemory.read32(row.lazyVA) == lazyHelperVA else {
                throw StageError.row(number, "Stage H lazy preimage/file-offset mismatch")
            }

            guard Int(row.symbolIndex) < image.symbols.count else {
                throw StageError.row(number, "Res4 nlist index is outside parsed symbol table")
            }
            let symbol = image.symbols[Int(row.symbolIndex)]
            let ordinal = Int((symbol.description >> 8) & 0x00FF)
            guard symbol.name == row.symbol, symbol.isUndefined, symbol.isExternal,
                  ordinal == row.ordinal, ordinal > 0, ordinal <= image.dependencies.count,
                  image.dependencies[ordinal - 1].name == row.provider else {
                throw StageError.row(number, "Res4 undefined symbol name/ordinal/provider mismatch")
            }

            let candidate = row.isThumb ? (row.providerNValue | 1) : (row.providerNValue & 0xFFFF_FFFE)
            guard candidate == row.candidate,
                  row.writeBytes == Data([
                    UInt8(candidate & 0xFF), UInt8((candidate >> 8) & 0xFF),
                    UInt8((candidate >> 16) & 0xFF), UInt8((candidate >> 24) & 0xFF)
                  ]),
                  row.canonicalTarget == (candidate & 0xFFFF_FFFE),
                  row.targetSegment == "__TEXT",
                  row.providerTextPermissions == "RX",
                  row.cacheRegion == "TEXT_RX", row.cachePermissions == "RX",
                  row.cacheVMStart <= row.canonicalTarget, row.canonicalTarget < row.cacheVMEnd,
                  row.providerTextStart <= row.canonicalTarget, row.canonicalTarget < row.providerTextEnd else {
                throw StageError.row(number, "provider candidate, ARM/Thumb state or executable cache mapping mismatch")
            }
            guard row.lazyFileOffset == row.lazyVA - imageBaseVA,
                  row.stubFileOffset == row.stubVA - imageBaseVA else {
                throw StageError.row(number, "compact snapshot/file-offset mapping mismatch")
            }

            let sourceStub = try stageHMemory.copyBytes(at: row.stubVA, count: 12)
            let sourceStubBytes = [UInt8](sourceStub)
            guard le32(sourceStubBytes, 0) == 0xE59FC000,
                  le32(sourceStubBytes, 4) == 0xE59CF000,
                  le32(sourceStubBytes, 8) == row.lazyVA,
                  Int(row.stubFileOffset) + 12 <= image.fileBytes.count,
                  sourceStub == image.fileBytes.subdata(in: Int(row.stubFileOffset)..<(Int(row.stubFileOffset) + 12)) else {
                throw StageError.row(number, "ARMv6 symbol stub was not preserved byte-for-byte")
            }

            let targetBytes = try stageHMemory.copyBytes(at: row.canonicalTarget, count: 4)
            let targetHex = targetBytes.map { String(format: "%02x", $0) }.joined()
            guard targetHex == row.candidateFirstBytes else {
                throw StageError.row(number, "shared-cache candidate bytes differ from Stage H source audit")
            }
            _ = try stageHMemory.readInstruction32(row.canonicalTarget)
            for targetVA in stageGRelocationTargets {
                guard row.lazyVA >= targetVA + 4 || targetVA >= row.lazyVA + 4 else {
                    throw StageError.row(number, "lazy slot overlaps Stage G relocation target")
                }
            }
            for nonLazyVA in nonLazySites {
                guard row.lazyVA >= nonLazyVA + 4 || nonLazyVA >= row.lazyVA + 4 else {
                    throw StageError.row(number, "lazy slot overlaps Stage H non-lazy pointer")
                }
            }
            rowsByLazy.append((row, lazy, stub))
        }

        guard seenLazy.count == 315, seenStub.count == 315,
              Set(lazyParsed.map(\.slotAddress)) == seenLazy,
              Set(stubParsed.map(\.slotAddress)) == seenStub else {
            throw StageError.prerequisite("I-C plan does not cover exactly all 315 lazy pointers and 315 stubs")
        }

        // Build a completely new Guest Memory: map the pinned Res4 image, mount a
        // separate immutable cache backing, and copy only Stage H's relocated __DATA.
        let stagingMemory = RE4GuestARMv6Memory(size: Int(imageEndVA))
        let mapResult = try RE4MachO32Loader.map(image, into: stagingMemory)
        guard mapResult.fileBytesCopied == 3_795_728, mapResult.zeroFillBytes == 17_648 else {
            throw StageError.staging("fresh Res4 mapping byte counts differ")
        }
        _ = try RE4IOS421SharedCacheMapper.mount(data: cacheData, into: stagingMemory, slide: 0)
        let stageHData = try stageHMemory.copyBytes(at: dataSegment.vmAddress, count: Int(dataSegment.vmSize))
        try stagingMemory.writeBytes(at: dataSegment.vmAddress, data: stageHData)
        let cloneBefore = try snapshot(stagingMemory, image: image)
        let cloneBeforeHash = sha256(cloneBefore)
        guard cloneBeforeHash == expectedStageHImageSHA256 else {
            throw StageError.staging("fresh Stage H clone hash mismatch: \(cloneBeforeHash)")
        }

        // Ensure candidate code remains executable/readable through the new cache mapping.
        for (i, item) in rowsByLazy.enumerated() {
            let candidateBytes = try stagingMemory.copyBytes(at: item.0.canonicalTarget, count: 4)
            let candidateHex = candidateBytes.map { String(format: "%02x", $0) }.joined()
            guard candidateHex == item.0.candidateFirstBytes else {
                throw StageError.row(i + 1, "fresh clone shared-cache candidate bytes differ")
            }
            _ = try stagingMemory.readInstruction32(item.0.canonicalTarget)
        }
        for (va, value) in relocationWords {
            guard try stagingMemory.read32(va) == value else {
                throw StageError.staging(String(format: "fresh clone relocation word mismatch at 0x%08X", va))
            }
        }

        // The only writes in this function: the 315 four-byte lazy slots in the new clone.
        for (i, item) in rowsByLazy.enumerated() {
            let row = item.0
            guard try stagingMemory.read32(row.lazyVA) == lazyHelperVA else {
                throw StageError.row(i + 1, "fresh clone lazy preimage is not 0x8DD0")
            }
            try stagingMemory.writeBytes(at: row.lazyVA, data: row.writeBytes)
        }

        var audit = [
            "Index,Stub_VA,Lazy_Pointer_VA,Lazy_Compact_Image_Offset,Symbol_Index,Symbol_Name,Dylib_Ordinal,Provider_Dylib,Original_StageH_Value,Expected_Lazy_Pointer_Value,Expected_Write_Bytes_LE,StageI_D_Readback,Pointer_State,Target_Canonical_Code_Address,Target_Cache_Region,Target_Cache_Permissions,Readback_Match,StageH_Source_Unchanged,Guest_Code_Executed"
        ]
        for (i, item) in rowsByLazy.enumerated() {
            let row = item.0
            let readback = try stagingMemory.read32(row.lazyVA)
            guard readback == row.candidate else {
                throw StageError.row(i + 1, "315-slot readback differs from candidate pointer")
            }
            audit.append([
                String(i + 1), String(format: "0x%08X", row.stubVA),
                String(format: "0x%08X", row.lazyVA),
                String(format: "0x%08X", row.lazyVA - imageBaseVA),
                String(row.symbolIndex), csvEscape(row.symbol), String(row.ordinal), csvEscape(row.provider),
                String(format: "0x%08X", lazyHelperVA),
                String(format: "0x%08X", row.candidate),
                row.writeBytes.map { String(format: "%02X", $0) }.joined(),
                String(format: "0x%08X", readback), row.isThumb ? "Thumb" : "ARM",
                String(format: "0x%08X", row.canonicalTarget),
                row.cacheRegion, row.cachePermissions, "PASS", "YES", "NO"
            ].joined(separator: ","))
        }

        // Preservation checks on the new image.
        for (i, readback) in nonLazyRows.enumerated() {
            guard try stagingMemory.read32(readback.site) == readback.readback else {
                throw StageError.row(i + 1, "Stage H non-lazy pointer changed in Stage I-D clone")
            }
        }
        for (va, value) in relocationWords {
            guard try stagingMemory.read32(va) == value else {
                throw StageError.staging(String(format: "Stage G relocation changed at 0x%08X", va))
            }
        }
        for (i, item) in rowsByLazy.enumerated() {
            guard try stagingMemory.copyBytes(at: item.0.stubVA, count: 12) ==
                    stageHMemory.copyBytes(at: item.0.stubVA, count: 12) else {
                throw StageError.row(i + 1, "symbol stub changed in Stage I-D clone")
            }
        }

        let sourceAfter = try snapshot(stageHMemory, image: image)
        guard sha256(sourceAfter) == expectedStageHImageSHA256,
              sourceAfter == sourceBefore else {
            throw StageError.staging("Stage H source memory changed during Stage I-D")
        }

        let finalImage = try snapshot(stagingMemory, image: image)
        let finalHash = sha256(finalImage)
        guard finalHash == expectedStageIDImageSHA256 else {
            throw StageError.staging("Stage I-D final image hash mismatch: \(finalHash)")
        }
        let beforeBytes = [UInt8](cloneBefore)
        let afterBytes = [UInt8](finalImage)
        var allowedOffsets = Set<Int>()
        for item in rowsByLazy {
            let start = try compactOffset(item.0.lazyVA)
            for offset in start..<(start + 4) { allowedOffsets.insert(offset) }
        }
        var changedBytes = 0
        for offset in beforeBytes.indices where beforeBytes[offset] != afterBytes[offset] {
            changedBytes += 1
            guard allowedOffsets.contains(offset) else {
                throw StageError.staging(String(format: "changed byte outside lazy slots at compact offset 0x%X", offset))
            }
        }
        guard changedBytes == expectedChangedByteCount else {
            throw StageError.staging("changed-byte count mismatch: \(changedBytes)")
        }

        let thumbCount = rows.filter(\.isThumb).count
        let armCount = rows.count - thumbCount
        let report = [
            "Stage I-D isolated lazy pointer apply/readback PASS",
            "Res4 architecture: ARMv6",
            "Res4 thin-slice SHA-256: \(thinHash)",
            "Shared cache SHA-256: \(expectedCacheSHA256)",
            "Stage H baseline image SHA-256: \(sourceBeforeHash)",
            "Stage I-C plan rows/hash: \(rows.count) / \(expectedPlanSHA256)",
            "New isolated Guest Memory: created; Stage H __DATA copied into fresh mapping",
            "Stage G relocation words preserved: \(relocationWords.count)/1943",
            "Stage H non-lazy pointers preserved: \(nonLazyRows.count)/42",
            "Lazy pointer preimages at 0x00008DD0: 315/315",
            "Lazy pointer writes to isolated Stage I-D image: 315",
            "Lazy pointer staging read-back: 315/315",
            "Symbol stubs preserved byte-for-byte: 315/315",
            "Provider cache bytes / RX mapping / Thumb-state checks: 315/315",
            "ARM-state targets: \(armCount); Thumb-state targets: \(thumbCount)",
            "Stage G / Stage H / stub / lazy-slot overlaps: none",
            "Changed bytes: \(changedBytes); all changes confined to the 315 lazy slots",
            "Stage H source image remains unchanged: PASS",
            "Stage I-D isolated image SHA-256: \(finalHash)",
            "No live Guest Memory write; no guest instruction, dyld helper, HLE, initializer, or constructor was executed."
        ].joined(separator: "\n")

        return ApplyResult(
            report: report,
            auditCSV: audit.joined(separator: "\n") + "\n",
            imageData: finalImage,
            stagingMemory: stagingMemory
        )
    }

    /// Parser/format self-test only; no production memory, cache, IPA, or guest code is touched.
    public static func runSyntheticSelfTest() throws -> String {
        let sample = "a,b\r\n\"comma,inside\",\"double \"\"quote\"\"\"\r\n"
        let parsed = try csvRecords(Data(sample.utf8))
        guard parsed.count == 2,
              parsed[1] == ["comma,inside", "double \"quote\""] else {
            throw StageError.input("RFC-4180 quoted-field self-test failed")
        }
        let bytes = Data([0x20, 0x3F, 0xC3, 0x36])
        guard le32([0x20, 0x3F, 0xC3, 0x36], 0) == 0x36C33F20,
              bytes.count == 4 else {
            throw StageError.input("little-endian pointer encoding self-test failed")
        }
        return "Stage I-D plan parser / CSV / little-endian pointer self-test PASS. No production Guest Memory was created or modified."
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var output = Data()
        output.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }
}
