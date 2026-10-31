import Foundation
import CryptoKit

/// Applies the pinned Stage H import manifest only to a second, newly-created Guest Memory.
/// The Stage G image and the app's original loaded memory are read-only.
public enum RE4IOS421ImportBindingStager {
    public static let expectedManifestSHA256 = "9b1fb98e033633f2dbf852ee7b27977c440d5818c4e4ff2b9d60c9f7308e36d1"
    public static let expectedManifestRows = 672
    public static let expectedStageGImageSHA256 = "7e5da46285c91312a78d05f6afba410d90fc21e0c621717a4e73ff6b7e1ae75a"
    public static let expectedStageHImageSHA256 = "ec3d8a0f66411ffddb7601772d7a60cb0006bfe92b08463547df0f9a77905094"
    public static let expectedChangedByteCount = 167

    private static let imageBaseVA: UInt32 = 0x00001000
    private static let imageEndVA: UInt32 = 0x003A4000
    private static let imageByteCount = 0x003A3000
    private static let lazyHelperVA: UInt32 = 0x00008DD0
    private static let expectedThinSHA256 = "2067760a8c5d1d5bb6b4d7bde55b698406386fb25141fb5fe8cf4bc20d6938ed"
    private static let expectedCacheSHA256 = "ab9dbbc1e7efcc6e8c7f79d20f90dab62d4309be5269a2055e3cd5136a62d024"

    private static let expectedHeader = [
        "Site_Address", "File_Offset", "Section", "Site_Kind", "Indirect_Table_Index",
        "Symbol_Index", "Symbol_Name", "Dylib_Ordinal", "Provider_Dylib", "Original_Word",
        "Original_Site_Bytes_Hex", "Provider_N_Value", "N_ARM_THUMB_DEF",
        "Resolved_Candidate_Pointer", "Candidate_Cache_Segment", "Candidate_Cache_Protection",
        "Candidate_Cache_File_Offset", "Stub_Embedded_Lazy_Pointer_VA", "Pairing_Validation",
        "Proposed_Action", "Would_Write_In_DryRun", "Staged_Value", "Live_Guest_Memory_Write"
    ]

    public struct ApplyResult {
        public let report: String
        public let auditCSV: String
        public let stagingMemory: RE4GuestARMv6Memory
    }

    private struct Row {
        let site: UInt32
        let fileOffset: UInt32
        let section: String
        let kind: String
        let indirectIndex: UInt32
        let symbolIndex: UInt32
        let symbol: String
        let ordinal: Int
        let provider: String
        let original: UInt32
        let originalBytes: String
        let providerNValue: UInt32
        let isThumb: Bool
        let candidate: UInt32
        let cacheSegment: String
        let cacheProtection: Int32
        let cacheFileOffset: UInt32
        let embeddedLazyVA: UInt32?
        let pairing: String
        let action: String
        let wouldWrite: Bool
        let stagedValue: UInt32?
        let liveWrite: String

        var sectionType: UInt32 {
            switch kind {
            case "non-lazy pointer": return 6
            case "lazy pointer": return 7
            case "symbol stub": return 8
            default: return 0
            }
        }
    }

    private enum StageError: Error, LocalizedError {
        case prerequisite(String)
        case manifest(String)
        case row(Int, String)
        case staging(String)

        var errorDescription: String? {
            switch self {
            case .prerequisite(let s): return "Stage H blocked: \(s)"
            case .manifest(let s): return "Stage H manifest rejected: \(s)"
            case .row(let n, let s): return "Stage H row #\(n) rejected: \(s)"
            case .staging(let s): return "Stage H isolated staging failed: \(s)"
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// RFC-4180 parsing for quoted commas, doubled quotes, CRLF and a possible UTF-8 BOM.
    private static func csvRecords(_ data: Data) throws -> [[String]] {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw StageError.manifest("CSV is not valid UTF-8")
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
                    guard field.isEmpty else { throw StageError.manifest("misplaced quote in unquoted field") }
                    quoted = true
                case ",":
                    row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                case "\r":
                    if i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        guard !quoted else { throw StageError.manifest("unterminated quoted field") }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func hex32(_ s: String, _ name: String, _ row: Int) throws -> UInt32 {
        let raw = (s.hasPrefix("0x") || s.hasPrefix("0X")) ? String(s.dropFirst(2)) : s
        guard let n = UInt32(raw, radix: 16) else {
            throw StageError.row(row, "\(name) is not a UInt32 hex value")
        }
        return n
    }

    private static func decimal(_ s: String, _ name: String, _ row: Int) throws -> Int {
        guard let n = Int(s), n >= 0 else { throw StageError.row(row, "\(name) is not a non-negative integer") }
        return n
    }

    private static func bool(_ s: String, _ name: String, _ row: Int) throws -> Bool {
        switch s.lowercased() {
        case "true": return true
        case "false": return false
        default: throw StageError.row(row, "\(name) must be True or False")
        }
    }

    private static func optionalHex32(_ s: String, _ name: String, _ row: Int) throws -> UInt32? {
        s.isEmpty ? nil : try hex32(s, name, row)
    }

    private static func decodeManifest(_ data: Data, hash: String, rowCount: Int) throws -> [Row] {
        let actual = sha256(data)
        guard actual == hash else { throw StageError.manifest("SHA-256 mismatch: \(actual)") }
        let records = try csvRecords(data)
        guard records.first == expectedHeader else {
            throw StageError.manifest("expected the pinned 23-column Stage H CSV header")
        }
        guard records.count == rowCount + 1 else {
            throw StageError.manifest("expected \(rowCount) rows; found \(max(0, records.count - 1))")
        }
        var result: [Row] = []
        result.reserveCapacity(rowCount)
        for (i, f) in records.dropFirst().enumerated() {
            let n = i + 1
            guard f.count == expectedHeader.count else { throw StageError.row(n, "expected 23 columns") }
            func v(_ key: String) -> String { f[expectedHeader.firstIndex(of: key)!] }
            let kind = v("Site_Kind")
            guard ["non-lazy pointer", "lazy pointer", "symbol stub"].contains(kind) else {
                throw StageError.row(n, "unrecognized Site_Kind")
            }
            let prot = try decimal(v("Candidate_Cache_Protection"), "Candidate_Cache_Protection", n)
            let symbolIndex = try decimal(v("Symbol_Index"), "Symbol_Index", n)
            let indirectIndex = try decimal(v("Indirect_Table_Index"), "Indirect_Table_Index", n)
            guard prot <= Int(Int32.max), symbolIndex <= Int(UInt32.max), indirectIndex <= Int(UInt32.max) else {
                throw StageError.row(n, "integer field overflows its storage type")
            }
            result.append(Row(
                site: try hex32(v("Site_Address"), "Site_Address", n),
                fileOffset: try hex32(v("File_Offset"), "File_Offset", n),
                section: v("Section"), kind: kind,
                indirectIndex: UInt32(indirectIndex), symbolIndex: UInt32(symbolIndex),
                symbol: v("Symbol_Name"),
                ordinal: try decimal(v("Dylib_Ordinal"), "Dylib_Ordinal", n),
                provider: v("Provider_Dylib"),
                original: try hex32(v("Original_Word"), "Original_Word", n),
                originalBytes: v("Original_Site_Bytes_Hex").lowercased(),
                providerNValue: try hex32(v("Provider_N_Value"), "Provider_N_Value", n),
                isThumb: try bool(v("N_ARM_THUMB_DEF"), "N_ARM_THUMB_DEF", n),
                candidate: try hex32(v("Resolved_Candidate_Pointer"), "Resolved_Candidate_Pointer", n),
                cacheSegment: v("Candidate_Cache_Segment"), cacheProtection: Int32(prot),
                cacheFileOffset: try hex32(v("Candidate_Cache_File_Offset"), "Candidate_Cache_File_Offset", n),
                embeddedLazyVA: try optionalHex32(v("Stub_Embedded_Lazy_Pointer_VA"), "Stub_Embedded_Lazy_Pointer_VA", n),
                pairing: v("Pairing_Validation"), action: v("Proposed_Action"),
                wouldWrite: try bool(v("Would_Write_In_DryRun"), "Would_Write_In_DryRun", n),
                stagedValue: try optionalHex32(v("Staged_Value"), "Staged_Value", n),
                liveWrite: v("Live_Guest_Memory_Write")
            ))
        }
        return result
    }

    private static func snapshot(_ memory: RE4GuestARMv6Memory, image: RE4MachO32Image) throws -> Data {
        let segments = image.segments.filter { ["__TEXT", "__DATA", "__LINKEDIT"].contains($0.name) }
            .sorted { $0.vmAddress < $1.vmAddress }
        guard segments.count == 3 else { throw StageError.prerequisite("expected three Res4 segments") }
        var data = Data()
        data.reserveCapacity(imageByteCount)
        var next = UInt64(imageBaseVA)
        for segment in segments {
            guard UInt64(segment.vmAddress) == next else { throw StageError.prerequisite("Res4 segment map has a gap or overlap") }
            data.append(try memory.copyBytes(at: segment.vmAddress, count: Int(segment.vmSize)))
            next = segment.vmEnd
        }
        guard next == UInt64(imageEndVA), data.count == imageByteCount else {
            throw StageError.prerequisite("Res4 snapshot size/end mismatch")
        }
        return data
    }

    private static func validateRows(_ rows: [Row], image: RE4MachO32Image,
                                     memory: RE4GuestARMv6Memory,
                                     relocationTargets: [UInt32]) throws
        -> (nonLazy: [Row], lazy: [Row], stubs: [Row]) {
        guard rows.count == expectedManifestRows, image.indirectImports.count == expectedManifestRows else {
            throw StageError.prerequisite("parsed import-site count does not equal 672")
        }
        var parsedByKey: [String: RE4MachO32IndirectImport] = [:]
        for item in image.indirectImports {
            let key = "\(item.slotAddress):\(item.sectionType)"
            guard parsedByKey[key] == nil else { throw StageError.prerequisite("duplicate parsed import site") }
            parsedByKey[key] = item
        }
        let segments = image.segments.filter { ["__TEXT", "__DATA", "__LINKEDIT"].contains($0.name) }
        var seen = Set<String>()
        var intervals: [(UInt64, UInt64)] = []
        var nonLazy: [Row] = []
        var lazy: [Row] = []
        var stubs: [Row] = []
        var nonLazySymbols = Set<UInt32>()
        var lazySymbols = Set<UInt32>()
        var stubSymbols = Set<UInt32>()

        for (i, row) in rows.enumerated() {
            let n = i + 1
            let key = "\(row.site):\(row.sectionType)"
            guard seen.insert(key).inserted, let parsed = parsedByKey.removeValue(forKey: key) else {
                throw StageError.row(n, "site does not uniquely match a parsed indirect-symbol record")
            }
            guard parsed.symbolName == row.symbol,
                  parsed.symbolIndex == row.symbolIndex,
                  parsed.indirectTableIndex == row.indirectIndex,
                  parsed.sectionType == row.sectionType,
                  parsed.entrySize == (row.kind == "symbol stub" ? 12 : 4) else {
                throw StageError.row(n, "symbol/indirect index, section type or entry size mismatch")
            }
            let sectionDataName = "__DATA,\(parsed.sectionName)"
            let sectionTextName = "__TEXT,\(parsed.sectionName)"
            guard row.section == sectionDataName || row.section == sectionTextName else {
                throw StageError.row(n, "section name mismatch")
            }
            guard let segment = segments.first(where: {
                UInt64(row.site) >= UInt64($0.vmAddress) &&
                UInt64(row.site) + UInt64(parsed.entrySize) <= $0.vmEnd
            }) else { throw StageError.row(n, "site lies outside mapped Res4 segments") }
            let calculatedOffset = UInt64(segment.fileOffset) + UInt64(row.site - segment.vmAddress)
            guard calculatedOffset == UInt64(row.fileOffset) else { throw StageError.row(n, "VA/file offset mismatch") }
            guard Int(row.symbolIndex) < image.symbols.count else { throw StageError.row(n, "nlist index out of range") }
            let symbol = image.symbols[Int(row.symbolIndex)]
            guard symbol.name == row.symbol, symbol.isUndefined, symbol.isExternal else {
                throw StageError.row(n, "nlist symbol is not the expected undefined external symbol")
            }
            let ordinal = Int((symbol.description >> 8) & 0x00FF)
            guard row.ordinal == ordinal, ordinal > 0, ordinal <= image.dependencies.count,
                  image.dependencies[ordinal - 1].name == row.provider else {
                throw StageError.row(n, "dylib ordinal/provider path mismatch")
            }
            guard row.liveWrite == "NO", row.site & 3 == 0 else {
                throw StageError.row(n, "live-write marker or target alignment invalid")
            }
            intervals.append((UInt64(row.site), UInt64(row.site) + UInt64(parsed.entrySize)))
            let siteBytes = try memory.copyBytes(at: row.site, count: Int(parsed.entrySize))
            let siteHex = siteBytes.map { String(format: "%02x", $0) }.joined()
            guard siteHex == row.originalBytes, try memory.read32(row.site) == row.original else {
                throw StageError.row(n, "Stage G source site bytes differ from the manifest")
            }

            let providerVA = UInt64(row.providerNValue)
            let pointer = row.isThumb ? row.providerNValue | 1 : row.providerNValue
            guard pointer == row.candidate else { throw StageError.row(n, "Thumb-state candidate pointer mismatch") }
            let expectedOffset: UInt64
            if providerVA >= 0x30000000 && providerVA < 0x379C9000 {
                guard row.cacheSegment == "__TEXT", row.cacheProtection == 5 else {
                    throw StageError.row(n, "provider TEXT mapping/protection mismatch")
                }
                expectedOffset = providerVA - 0x30000000
            } else if providerVA >= 0x3E000000 && providerVA < 0x3EBFC000 {
                guard row.cacheSegment == "__DATA", row.cacheProtection == 3, !row.isThumb else {
                    throw StageError.row(n, "provider DATA mapping/protection mismatch")
                }
                expectedOffset = 0x079C9000 + providerVA - 0x3E000000
            } else {
                throw StageError.row(n, "provider address is outside pinned cache TEXT/DATA")
            }
            guard expectedOffset == UInt64(row.cacheFileOffset) else {
                throw StageError.row(n, "provider cache file offset mismatch")
            }
            _ = try memory.copyBytes(at: row.providerNValue, count: 4)

            switch row.kind {
            case "non-lazy pointer":
                guard row.section == "__DATA,__nl_symbol_ptr", row.original == 0,
                      row.originalBytes == "00000000", row.wouldWrite,
                      row.action == "STAGE_EAGER_BIND_CANDIDATE_IN_ISOLATED_COPY",
                      row.stagedValue == row.candidate, row.embeddedLazyVA == nil,
                      nonLazySymbols.insert(row.symbolIndex).inserted else {
                    throw StageError.row(n, "non-lazy pointer invariants failed")
                }
                nonLazy.append(row)
            case "lazy pointer":
                guard row.section == "__DATA,__la_symbol_ptr", row.original == lazyHelperVA,
                      row.originalBytes == "d08d0000", !row.wouldWrite,
                      row.action == "DEFER_TO_LAZY_HELPER_PRESERVE_0x8DD0",
                      row.stagedValue == nil,
                      row.pairing == "PASS: matching symbol stub points to this lazy slot",
                      lazySymbols.insert(row.symbolIndex).inserted else {
                    throw StageError.row(n, "lazy pointer must remain 0x8DD0 and be paired with one stub")
                }
                lazy.append(row)
            case "symbol stub":
                guard row.section == "__TEXT,__symbol_stub4", parsed.entrySize == 12,
                      !row.wouldWrite, row.action == "VERIFY_STUB_LITERAL_ONLY_PRESERVE_STUB",
                      row.pairing == "PASS: embedded literal equals matching lazy pointer slot",
                      stubSymbols.insert(row.symbolIndex).inserted,
                      let lazyVA = row.embeddedLazyVA else {
                    throw StageError.row(n, "symbol-stub preservation invariants failed")
                }
                let bytes = [UInt8](siteBytes)
                guard le32(bytes, 0) == 0xE59FC000, le32(bytes, 4) == 0xE59CF000,
                      le32(bytes, 8) == lazyVA else {
                    throw StageError.row(n, "stub instruction pair/lazy-slot literal mismatch")
                }
                stubs.append(row)
            default:
                throw StageError.row(n, "unknown site kind")
            }
        }
        guard parsedByKey.isEmpty else { throw StageError.manifest("manifest omitted parsed indirect sites") }
        intervals.sort { $0.0 < $1.0 }
        for i in 1..<intervals.count where intervals[i].0 < intervals[i - 1].1 {
            throw StageError.manifest("indirect site intervals overlap")
        }
        guard nonLazy.count == 42, lazy.count == 315, stubs.count == 315,
              nonLazySymbols.count == 42, lazySymbols.count == 315, stubSymbols.count == 315,
              lazySymbols == stubSymbols else {
            throw StageError.manifest("site distribution/lazy-stub symbol pairing is not 42/315/315")
        }
        let lazyBySymbol = Dictionary(uniqueKeysWithValues: lazy.map { ($0.symbolIndex, $0.site) })
        for stub in stubs {
            guard lazyBySymbol[stub.symbolIndex] == stub.embeddedLazyVA else {
                throw StageError.manifest("stub literal does not target its matching lazy slot")
            }
        }
        let relocationSet = Set(relocationTargets)
        guard relocationSet.count == relocationTargets.count else {
            throw StageError.prerequisite("Stage G relocation target list has duplicates")
        }
        for span in intervals {
            for target in relocationSet {
                let other = (UInt64(target), UInt64(target) + 4)
                if span.0 < other.1 && span.1 > other.0 {
                    throw StageError.manifest("import site overlaps Stage G relocation target")
                }
            }
        }
        return (nonLazy.sorted { $0.site < $1.site },
                lazy.sorted { $0.site < $1.site },
                stubs.sorted { $0.site < $1.site })
    }

    public static func applyInIsolatedStaging(
        image: RE4MachO32Image,
        cacheData: Data,
        stageGMemory: RE4GuestARMv6Memory,
        stageGRelocationTargets: [UInt32],
        manifestData: Data
    ) throws -> ApplyResult {
        guard image.cpuType == 12, (image.cpuSubtype & 0x00FF_FFFF) == 6,
              image.fileType == 2, image.wasUniversal, image.selectedSliceOffset == 0x1000,
              image.fileBytes.count == 3_795_728 else {
            throw StageError.prerequisite("selected executable is not the pinned universal Res4 ARMv6 slice")
        }
        let thinHash = sha256(image.fileBytes)
        guard thinHash == expectedThinSHA256 else { throw StageError.prerequisite("Res4 thin-slice SHA-256 mismatch") }
        guard cacheData.count == RE4IOS421SharedCacheMapper.expectedSize,
              sha256(cacheData) == expectedCacheSHA256 else {
            throw StageError.prerequisite("iOS 4.2.1 shared-cache size/hash mismatch")
        }
        for name in ["iOS421_SHARED_CACHE_TEXT_RX", "iOS421_SHARED_CACHE_LINKEDIT_RO",
                     "iOS421_SHARED_CACHE_CODE_SIGNATURE_RO", "iOS421_SHARED_CACHE_DATA_RW"] {
            guard stageGMemory.hasSparseRegion(named: name) else {
                throw StageError.prerequisite("Stage G input missing sparse cache region \(name)")
            }
        }
        guard let dataSegment = image.segments.first(where: { $0.name == "__DATA" }),
              dataSegment.vmAddress == 0x001C1000, dataSegment.vmSize == 0x00022000,
              dataSegment.fileOffset == 0x001C0000, dataSegment.fileSize == 0x0001E000,
              dataSegment.initialProtection == 3 else {
            throw StageError.prerequisite("Res4 __DATA layout/protection differs from pinned Stage D")
        }
        let text = image.segments.first(where: { $0.name == "__TEXT" })
        let linkedit = image.segments.first(where: { $0.name == "__LINKEDIT" })
        guard text?.vmAddress == 0x1000, text?.vmSize == 0x1C0000,
              linkedit?.vmAddress == 0x1E3000, linkedit?.vmSize == 0x1C1000 else {
            throw StageError.prerequisite("Res4 __TEXT/__LINKEDIT layout differs from pinned image")
        }

        let rows = try decodeManifest(manifestData, hash: expectedManifestSHA256, rowCount: expectedManifestRows)
        let sourceBeforeHash = sha256(try snapshot(stageGMemory, image: image))
        guard sourceBeforeHash == expectedStageGImageSHA256 else {
            throw StageError.prerequisite("Stage G image SHA-256 mismatch: \(sourceBeforeHash)")
        }
        let groups = try validateRows(rows, image: image, memory: stageGMemory,
                                      relocationTargets: stageGRelocationTargets)

        // Create a completely separate Guest Memory, then copy Stage G's relocated __DATA
        // into it. No pointer is written into either the original loaded memory or Stage G.
        let stagingMemory = RE4GuestARMv6Memory(size: Int(imageEndVA))
        let map = try RE4MachO32Loader.map(image, into: stagingMemory)
        guard map.fileBytesCopied == 3_795_728, map.zeroFillBytes == 17_648 else {
            throw StageError.staging("fresh Res4 segment mapping byte counts differ")
        }
        _ = try RE4IOS421SharedCacheMapper.mount(data: cacheData, into: stagingMemory, slide: 0)
        let stageGData = try stageGMemory.copyBytes(at: dataSegment.vmAddress, count: Int(dataSegment.vmSize))
        try stagingMemory.writeBytes(at: dataSegment.vmAddress, data: stageGData)
        let cloneBefore = try snapshot(stagingMemory, image: image)
        guard sha256(cloneBefore) == expectedStageGImageSHA256 else {
            throw StageError.staging("fresh clone does not reproduce the Stage G image hash")
        }

        for (i, row) in groups.nonLazy.enumerated() {
            guard try stagingMemory.read32(row.site) == 0 else {
                throw StageError.row(i + 1, "fresh clone non-lazy slot is not zero")
            }
            _ = try stagingMemory.copyBytes(at: row.providerNValue, count: 4)
        }
        for row in groups.lazy {
            guard try stagingMemory.read32(row.site) == lazyHelperVA else {
                throw StageError.staging("lazy pointer changed before binding")
            }
        }
        for row in groups.stubs {
            let bytes = [UInt8](try stagingMemory.copyBytes(at: row.site, count: 12))
            guard let lazyVA = row.embeddedLazyVA,
                  le32(bytes, 0) == 0xE59FC000, le32(bytes, 4) == 0xE59CF000,
                  le32(bytes, 8) == lazyVA else {
                throw StageError.staging("symbol stub changed before binding")
            }
        }

        // The only writes in this function: 42 non-lazy pointers in the new clone.
        for row in groups.nonLazy {
            try stagingMemory.write32(row.site, row.candidate)
        }

        var audit = ["Index,Site_Address,File_Offset,Symbol_Index,Symbol_Name,Provider_Dylib,Provider_N_Value,N_ARM_THUMB_DEF,Resolved_Candidate_Pointer,Cache_Segment,Cache_Protection,Staging_Readback,Lazy_Pointer_Preserved,Stub_Preserved,StageG_Source_Unchanged"]
        for (i, row) in groups.nonLazy.enumerated() {
            let readback = try stagingMemory.read32(row.site)
            guard readback == row.candidate else { throw StageError.row(i + 1, "readback differs from candidate") }
            audit.append([
                String(i + 1), String(format: "0x%08X", row.site), String(format: "0x%08X", row.fileOffset),
                String(row.symbolIndex), csvEscape(row.symbol), csvEscape(row.provider),
                String(format: "0x%08X", row.providerNValue), String(row.isThumb),
                String(format: "0x%08X", row.candidate), row.cacheSegment, String(row.cacheProtection),
                String(format: "0x%08X", readback), "true", "true", "true"
            ].joined(separator: ","))
        }

        for row in groups.lazy {
            guard try stagingMemory.read32(row.site) == lazyHelperVA else {
                throw StageError.staging("lazy pointer was modified")
            }
        }
        for row in groups.stubs {
            let stagedBytes = try stagingMemory.copyBytes(at: row.site, count: 12)
            let sourceBytes = try stageGMemory.copyBytes(at: row.site, count: 12)
            guard stagedBytes == sourceBytes else { throw StageError.staging("symbol stub changed") }
        }
        let sourceAfterHash = sha256(try snapshot(stageGMemory, image: image))
        guard sourceAfterHash == expectedStageGImageSHA256 else {
            throw StageError.staging("Stage G source memory changed during import staging")
        }

        let finalImage = try snapshot(stagingMemory, image: image)
        let finalHash = sha256(finalImage)
        guard finalHash == expectedStageHImageSHA256 else {
            throw StageError.staging("final Stage H image hash mismatch: \(finalHash)")
        }
        let before = [UInt8](cloneBefore)
        let after = [UInt8](finalImage)
        var allowedOffsets = Set<Int>()
        for row in groups.nonLazy {
            let start = Int(row.site - imageBaseVA)
            for i in start..<(start + 4) { allowedOffsets.insert(i) }
        }
        var changed = 0
        for i in before.indices where before[i] != after[i] {
            changed += 1
            guard allowedOffsets.contains(i) else {
                throw StageError.staging("changed byte found outside the 42 non-lazy slots")
            }
        }
        guard changed == expectedChangedByteCount else {
            throw StageError.staging("changed-byte count mismatch: \(changed)")
        }

        let report = [
            "Stage H isolated native import apply PASS",
            "Res4 architecture: ARMv6",
            "Res4 thin-slice SHA-256: \(thinHash)",
            "Shared cache SHA-256: \(expectedCacheSHA256)",
            "Stage H manifest rows/hash: \(rows.count) / \(expectedManifestSHA256)",
            "Stage G source relocated image SHA-256 before: \(sourceBeforeHash)",
            "Stage G source relocated image SHA-256 after: \(sourceAfterHash)",
            "New isolated Guest Memory: created; Stage G __DATA copied into fresh mapping",
            "Indirect sites verified: 672/672 (non-lazy=42; lazy=315; stubs=315)",
            "Non-lazy pointer writes to isolated Stage H image: 42",
            "Non-lazy staging read-back: 42/42",
            "Lazy pointers preserved at 0x00008DD0: 315/315",
            "Symbol stubs preserved byte-for-byte: 315/315",
            "Provider n_value / cache mapping / Thumb-state checks: 672/672",
            "Stage G relocation/import site overlap: none",
            "Changed bytes: \(changed); every changed byte is inside one of the 42 non-lazy slots",
            "Stage G input image remains unchanged: PASS",
            "Stage H isolated image SHA-256: \(finalHash)",
            "No live Guest Memory write; no guest instruction, HLE, lazy helper, initializer, or constructor was executed."
        ].joined(separator: "\n")
        return ApplyResult(report: report, auditCSV: audit.joined(separator: "\n") + "\n",
                           stagingMemory: stagingMemory)
    }

    /// Format-only test: no production binary/cache is loaded and no Guest Memory is written.
    public static func runSyntheticSelfTest() throws -> String {
        let header = expectedHeader.joined(separator: ",")
        let values = [
            "0x001C1000", "0x001C0000", "__DATA,__nl_symbol_ptr", "non-lazy pointer", "316",
            "53527", "_exit", "19", "/usr/lib/libSystem.B.dylib", "0x00000000", "00000000",
            "0x35D87D70", "True", "0x35D87D71", "__TEXT", "5", "0x05D87D70", "",
            "N/A: standalone non-lazy pointer", "STAGE_EAGER_BIND_CANDIDATE_IN_ISOLATED_COPY", "True", "0x35D87D71", "NO"
        ]
        let data = Data((header + "\n" + values.map(csvEscape).joined(separator: ",") + "\n").utf8)
        let parsed = try decodeManifest(data, hash: sha256(data), rowCount: 1)
        guard parsed.count == 1, parsed[0].symbol == "_exit",
              parsed[0].candidate == 0x35D87D71, parsed[0].isThumb else {
            throw StageError.manifest("synthetic CSV row round-trip mismatch")
        }
        let quoted = try csvRecords(Data("a,b\r\n\"comma,inside\",\"double \"\"quote\"\"\"\r\n".utf8))
        guard quoted.count == 2, quoted[1] == ["comma,inside", "double \"quote\""] else {
            throw StageError.manifest("synthetic RFC-4180 quoting test failed")
        }
        return "Stage H import manifest parser self-test PASS (pinned schema, SHA-256 path, 23-column row, quoted commas/quotes; no Guest Memory touched)."
    }
}