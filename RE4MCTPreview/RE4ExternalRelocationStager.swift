import Foundation
import CryptoKit

/// Verifies the pinned Stage D external-relocation overlay and applies it only to
/// a freshly created, isolated Guest Memory instance. The caller's live memory is
/// read-only throughout this operation.
public enum RE4ExternalRelocationStager {
    public static let expectedRecordCount = 1_943
    public static let expectedOverlaySHA256 =
        "3b6a3fc6450b26d24a364ad9e19642e9763040f8dee48d60eb8a41aea39ac00a"
    public static let expectedRes4ThinSHA256 =
        "2067760a8c5d1d5bb6b4d7bde55b698406386fb25141fb5fe8cf4bc20d6938ed"
    public static let expectedCacheSHA256 =
        "ab9dbbc1e7efcc6e8c7f79d20f90dab62d4309be5269a2055e3cd5136a62d024"
    public static let expectedBaselineSHA256 =
        "52f4be66f336dd012f2ddf76ac87e7fef40ba9cfde34b28af705143406b9aea5"
    public static let expectedRelocatedSHA256 =
        "7e5da46285c91312a78d05f6afba410d90fc21e0c621717a4e73ff6b7e1ae75a"

    private static let baseVA: UInt32 = 0x00001000
    private static let imageEndVA: UInt32 = 0x003A4000
    private static let imageByteCount = 0x003A3000

    private struct Record {
        let targetVA: UInt32
        let originalWord: UInt32
        let candidateWord: UInt32
        let thinFileOffset: UInt32
    }

    public struct ApplyResult {
        public let report: String
        public let auditCSV: String
        public let stagingMemory: RE4GuestARMv6Memory
        /// Exact target VAs already relocated in the isolated Stage G image.
        public let relocationTargetAddresses: [UInt32]
    }

    private enum StagerError: Error, LocalizedError {
        case invalidPrerequisite(String)
        case invalidOverlay(String)
        case recordFailure(index: Int, reason: String)
        case stagingFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidPrerequisite(let reason):
                return "Stage G preflight blocked: \(reason)"
            case .invalidOverlay(let reason):
                return "Stage D relocation overlay rejected: \(reason)"
            case .recordFailure(let index, let reason):
                return "Relocation record #\(index) rejected: \(reason)"
            case .stagingFailure(let reason):
                return "Isolated relocation staging failed: \(reason)"
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func decodeOverlay(
        _ data: Data,
        expectedCount: Int,
        expectedHash: String
    ) throws -> [Record] {
        guard data.count == expectedCount * 16 else {
            throw StagerError.invalidOverlay(
                "expected \(expectedCount * 16) bytes, received \(data.count)"
            )
        }
        let actualHash = sha256(data)
        guard actualHash == expectedHash else {
            throw StagerError.invalidOverlay("SHA-256 mismatch: \(actualHash)")
        }

        let bytes = [UInt8](data)
        var records: [Record] = []
        records.reserveCapacity(expectedCount)
        var seenTargets = Set<UInt32>()
        var sortedSpans: [(UInt64, UInt64)] = []

        for index in 0..<expectedCount {
            let offset = index * 16
            let record = Record(
                targetVA: readLE32(bytes, offset),
                originalWord: readLE32(bytes, offset + 4),
                candidateWord: readLE32(bytes, offset + 8),
                thinFileOffset: readLE32(bytes, offset + 12)
            )
            guard record.targetVA & 3 == 0 else {
                throw StagerError.recordFailure(index: index + 1, reason: "target is not 4-byte aligned")
            }
            guard seenTargets.insert(record.targetVA).inserted else {
                throw StagerError.recordFailure(index: index + 1, reason: "duplicate target VA")
            }
            guard record.candidateWord & 3 == 0 else {
                throw StagerError.recordFailure(index: index + 1, reason: "candidate pointer is not 4-byte aligned")
            }
            guard record.candidateWord != record.originalWord else {
                throw StagerError.recordFailure(index: index + 1, reason: "candidate equals original word")
            }
            guard record.originalWord == 0 || record.originalWord == 8 else {
                throw StagerError.recordFailure(index: index + 1, reason: "unexpected raw addend")
            }
            let start = UInt64(record.targetVA)
            sortedSpans.append((start, start + 4))
            records.append(record)
        }

        sortedSpans.sort { $0.0 < $1.0 }
        for index in 1..<sortedSpans.count {
            guard sortedSpans[index].0 >= sortedSpans[index - 1].1 else {
                throw StagerError.invalidOverlay("overlapping 4-byte relocation targets")
            }
        }
        return records
    }

    private static func snapshotMappedRes4(
        _ memory: RE4GuestARMv6Memory,
        image: RE4MachO32Image
    ) throws -> Data {
        let names: Set<String> = ["__TEXT", "__DATA", "__LINKEDIT"]
        let segments = image.segments
            .filter { names.contains($0.name) }
            .sorted { $0.vmAddress < $1.vmAddress }
        guard segments.count == 3 else {
            throw StagerError.invalidPrerequisite("expected exactly three loadable Res4 segments for snapshot")
        }

        var snapshot = Data()
        snapshot.reserveCapacity(imageByteCount)
        var expectedNextVA = UInt64(baseVA)
        for segment in segments {
            guard UInt64(segment.vmAddress) == expectedNextVA else {
                throw StagerError.invalidPrerequisite("Res4 segment snapshot encountered a VM gap or overlap")
            }
            // Read one protection range at a time. The Guest Memory API intentionally
            // rejects a single read that spans differently protected dense segments.
            snapshot.append(try memory.copyBytes(
                at: segment.vmAddress,
                count: Int(segment.vmSize)
            ))
            expectedNextVA = segment.vmEnd
        }
        guard expectedNextVA == UInt64(imageEndVA), snapshot.count == imageByteCount else {
            throw StagerError.invalidPrerequisite("Res4 segment snapshot size/end does not match the pinned image")
        }
        return snapshot
    }

    private static func requireSegment(
        _ image: RE4MachO32Image,
        name: String,
        vmAddress: UInt32,
        vmSize: UInt32,
        fileOffset: UInt32,
        fileSize: UInt32,
        initialProtection: Int32
    ) throws -> RE4MachO32Segment {
        guard let segment = image.segments.first(where: { $0.name == name }),
              segment.vmAddress == vmAddress,
              segment.vmSize == vmSize,
              segment.fileOffset == fileOffset,
              segment.fileSize == fileSize,
              segment.initialProtection == initialProtection else {
            throw StagerError.invalidPrerequisite(
                "Res4 \(name) segment layout/protection does not match the pinned Stage D image"
            )
        }
        return segment
    }

    /// Stage G: independently preflight the real loaded Guest Memory, then reproduce
    /// the Stage D relocation patch set in a new low-memory instance. No write is
    /// issued to originalMemory, no dyld binding is installed, and no guest code runs.
    public static func applyInIsolatedStaging(
        image: RE4MachO32Image,
        cacheData: Data,
        originalMemory: RE4GuestARMv6Memory,
        overlayData: Data
    ) throws -> ApplyResult {
        guard image.cpuType == 12,
              (image.cpuSubtype & 0x00FF_FFFF) == 6,
              image.fileType == 2,
              image.wasUniversal,
              image.selectedSliceOffset == 0x1000,
              image.fileBytes.count == 3_795_728 else {
            throw StagerError.invalidPrerequisite(
                "selected Mach-O is not the pinned universal Res4 ARMv6 slice at FAT offset 0x1000"
            )
        }

        let imageHash = sha256(image.fileBytes)
        guard imageHash == expectedRes4ThinSHA256 else {
            throw StagerError.invalidPrerequisite("Res4 thin-slice SHA-256 mismatch: \(imageHash)")
        }
        guard cacheData.count == RE4IOS421SharedCacheMapper.expectedSize else {
            throw StagerError.invalidPrerequisite("shared-cache byte count mismatch: \(cacheData.count)")
        }
        let cacheHash = sha256(cacheData)
        guard cacheHash == expectedCacheSHA256 else {
            throw StagerError.invalidPrerequisite("shared-cache SHA-256 mismatch: \(cacheHash)")
        }

        for regionName in [
            "iOS421_SHARED_CACHE_TEXT_RX",
            "iOS421_SHARED_CACHE_LINKEDIT_RO",
            "iOS421_SHARED_CACHE_CODE_SIGNATURE_RO",
            "iOS421_SHARED_CACHE_DATA_RW"
        ] {
            guard originalMemory.hasSparseRegion(named: regionName) else {
                throw StagerError.invalidPrerequisite("original Guest Memory is missing sparse region \(regionName)")
            }
        }

        let text = try requireSegment(
            image, name: "__TEXT", vmAddress: 0x00001000, vmSize: 0x001C0000,
            fileOffset: 0, fileSize: 0x001C0000, initialProtection: 5
        )
        let dataSegment = try requireSegment(
            image, name: "__DATA", vmAddress: 0x001C1000, vmSize: 0x00022000,
            fileOffset: 0x001C0000, fileSize: 0x0001E000, initialProtection: 3
        )
        _ = try requireSegment(
            image, name: "__LINKEDIT", vmAddress: 0x001E3000, vmSize: 0x001C1000,
            fileOffset: 0x001DE000, fileSize: 0x001C0B10, initialProtection: 1
        )
        guard text.vmEnd == UInt64(dataSegment.vmAddress),
              UInt64(dataSegment.vmAddress) + UInt64(dataSegment.vmSize) == 0x001E3000 else {
            throw StagerError.invalidPrerequisite("Res4 loadable segment boundaries are not contiguous as expected")
        }

        let records = try decodeOverlay(
            overlayData,
            expectedCount: expectedRecordCount,
            expectedHash: expectedOverlaySHA256
        )

        // Verify the caller's already-loaded memory before creating or writing staging memory.
        let originalBaseline = try snapshotMappedRes4(originalMemory, image: image)
        let originalBaselineHash = sha256(originalBaseline)
        guard originalBaselineHash == expectedBaselineSHA256 else {
            throw StagerError.invalidPrerequisite(
                "live Res4 baseline bytes do not match Stage D; expected \(expectedBaselineSHA256), got \(originalBaselineHash)"
            )
        }

        let sourceFileBytes = [UInt8](image.fileBytes)
        var textCandidateCount = 0
        var dataCandidateCount = 0
        var csvLines = [
            "Index,Target_VA,Thin_File_Offset,Original_Word,Candidate_New_Value,Original_Memory_Match,Candidate_Cache_Readable,Staging_Readback,Original_Memory_Unchanged"
        ]
        csvLines.reserveCapacity(records.count + 1)

        for (index, record) in records.enumerated() {
            let targetEnd = UInt64(record.targetVA) + 4
            let dataFileEnd = UInt64(dataSegment.vmAddress) + UInt64(dataSegment.fileSize)
            guard UInt64(record.targetVA) >= UInt64(dataSegment.vmAddress),
                  targetEnd <= dataFileEnd else {
                throw StagerError.recordFailure(index: index + 1, reason: "target is outside file-backed __DATA")
            }

            let expectedFileOffset =
                UInt64(dataSegment.fileOffset) + UInt64(record.targetVA - dataSegment.vmAddress)
            guard expectedFileOffset == UInt64(record.thinFileOffset),
                  expectedFileOffset + 4 <= UInt64(image.fileBytes.count) else {
                throw StagerError.recordFailure(index: index + 1, reason: "target VA to thin-file offset translation mismatch")
            }

            let fileOffset = Int(record.thinFileOffset)
            let sourceWord = readLE32(sourceFileBytes, fileOffset)
            guard sourceWord == record.originalWord else {
                throw StagerError.recordFailure(
                    index: index + 1,
                    reason: String(format: "overlay original 0x%08X differs from Res4 file word 0x%08X",
                                   record.originalWord, sourceWord)
                )
            }

            let liveWord = try originalMemory.read32(record.targetVA)
            guard liveWord == record.originalWord else {
                throw StagerError.recordFailure(
                    index: index + 1,
                    reason: String(format: "live mapped word is 0x%08X, expected original 0x%08X",
                                   liveWord, record.originalWord)
                )
            }

            // Stage C/E pinned the 1,943 candidates to provider-image addresses.
            // Verify each candidate is inside the actual mapped 8C148 cache ranges and readable.
            let candidate = UInt64(record.candidateWord)
            if candidate >= 0x30000000 && candidate < 0x379C9000 {
                textCandidateCount += 1
            } else if candidate >= 0x3E000000 && candidate < 0x3EBFC000 {
                dataCandidateCount += 1
            } else {
                throw StagerError.recordFailure(index: index + 1, reason: "candidate is outside the pinned TEXT/DATA cache mappings")
            }
            _ = try originalMemory.read32(record.candidateWord)
        }

        guard textCandidateCount == 320, dataCandidateCount == 1_623 else {
            throw StagerError.invalidPrerequisite(
                "candidate region distribution mismatch: TEXT=\(textCandidateCount), DATA=\(dataCandidateCount)"
            )
        }

        // Build a brand-new minimal low Guest Memory. The 166 MB cache Data is reused
        // as immutable backing; only this new instance receives relocation writes.
        let stagingMemory = RE4GuestARMv6Memory(size: Int(imageEndVA))
        let mapResult = try RE4MachO32Loader.map(image, into: stagingMemory)
        guard mapResult.fileBytesCopied == 3_795_728,
              mapResult.zeroFillBytes == 17_648 else {
            throw StagerError.stagingFailure("fresh Res4 segment mapping byte counts differ from Stage D")
        }
        _ = try RE4IOS421SharedCacheMapper.mount(
            data: cacheData, into: stagingMemory, slide: 0
        )

        let stagingBefore = try snapshotMappedRes4(stagingMemory, image: image)
        let stagingBeforeHash = sha256(stagingBefore)
        guard stagingBeforeHash == expectedBaselineSHA256 else {
            throw StagerError.stagingFailure(
                "fresh staging baseline hash mismatch: \(stagingBeforeHash)"
            )
        }

        // Complete a second, independent pass against the exact staging object before
        // the first write. This also proves candidate pages are readable from its cache.
        for (index, record) in records.enumerated() {
            let original = try stagingMemory.read32(record.targetVA)
            guard original == record.originalWord else {
                throw StagerError.recordFailure(index: index + 1, reason: "fresh staging source word mismatch")
            }
            _ = try stagingMemory.read32(record.candidateWord)
        }

        // All 1,943 preflight checks have passed. Apply only to the isolated staging memory.
        for record in records {
            try stagingMemory.write32(record.targetVA, record.candidateWord)
        }

        var readbackLines: [String] = []
        readbackLines.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            let readback = try stagingMemory.read32(record.targetVA)
            guard readback == record.candidateWord else {
                throw StagerError.recordFailure(
                    index: index + 1,
                    reason: String(format: "staging read-back 0x%08X differs from candidate 0x%08X",
                                   readback, record.candidateWord)
                )
            }
            let liveWord = try originalMemory.read32(record.targetVA)
            guard liveWord == record.originalWord else {
                throw StagerError.recordFailure(index: index + 1, reason: "original Guest Memory changed during staging")
            }
            readbackLines.append(
                "\(index + 1),0x\(String(record.targetVA, radix: 16, uppercase: true)),0x\(String(record.thinFileOffset, radix: 16, uppercase: true)),0x\(String(record.originalWord, radix: 16, uppercase: true)),0x\(String(record.candidateWord, radix: 16, uppercase: true)),true,true,0x\(String(readback, radix: 16, uppercase: true)),true"
            )
        }

        let originalAfter = try snapshotMappedRes4(originalMemory, image: image)
        let originalAfterHash = sha256(originalAfter)
        guard originalAfterHash == expectedBaselineSHA256 else {
            throw StagerError.stagingFailure("original Guest Memory baseline changed: \(originalAfterHash)")
        }

        let stagingAfter = try snapshotMappedRes4(stagingMemory, image: image)
        let stagingAfterHash = sha256(stagingAfter)
        guard stagingAfterHash == expectedRelocatedSHA256 else {
            throw StagerError.stagingFailure(
                "relocated staging hash mismatch: \(stagingAfterHash)"
            )
        }

        let beforeBytes = [UInt8](stagingBefore)
        let afterBytes = [UInt8](stagingAfter)
        let changedByteCount = zip(beforeBytes, afterBytes).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        guard changedByteCount == 7_751 else {
            throw StagerError.stagingFailure("changed-byte count mismatch: \(changedByteCount)")
        }

        csvLines.append(contentsOf: readbackLines)
        let auditCSV = csvLines.joined(separator: "\n") + "\n"
        let report = [
            "Stage G isolated external relocation apply PASS",
            "Res4 architecture: ARMv6",
            "Res4 thin-slice SHA-256: \(imageHash)",
            "Shared cache SHA-256: \(cacheHash)",
            "Overlay records: \(records.count)",
            "Overlay SHA-256: \(expectedOverlaySHA256)",
            "Unique aligned targets: \(records.count)",
            "Target region: __DATA RW (file-backed)",
            "Original addends: 1,623 × 0x00000000; 320 × 0x00000008",
            "Candidate cache regions: TEXT RX=\(textCandidateCount); DATA RW=\(dataCandidateCount)",
            "Candidate addresses readable: \(records.count)/\(records.count)",
            "Live memory preflight: \(records.count)/\(records.count) original words matched",
            "Isolated staging baseline SHA-256: \(stagingBeforeHash)",
            "Relocation writes applied to isolated staging memory: \(records.count)",
            "Staging read-back verified: \(records.count)/\(records.count)",
            "Changed bytes: \(changedByteCount)",
            "Isolated relocated image SHA-256: \(stagingAfterHash)",
            "Original live Guest Memory unchanged: PASS",
            "Original live baseline SHA-256 after staging: \(originalAfterHash)",
            "Original shared-cache Data remains immutable; no cache fixups were written.",
            "No indirect-import binding, lazy binding, HLE, initializer, constructor, or guest instruction execution was performed."
        ].joined(separator: "\n")

        return ApplyResult(
            report: report,
            auditCSV: auditCSV,
            stagingMemory: stagingMemory,
            relocationTargetAddresses: records.map(\.targetVA)
        )
    }

    /// A small format-level self-test used by the host CI. It does not map a cache
    /// or apply any production relocation data.
    public static func runOverlayFormatSelfTest() throws -> String {
        var data = Data()
        let values: [(UInt32, UInt32, UInt32, UInt32)] = [
            (0x001C1000, 0, 0x30000000, 0x001C0000),
            (0x001C1004, 8, 0x3E000008, 0x001C0004),
            (0x001C1008, 0, 0x30000010, 0x001C0008)
        ]
        for value in values {
            appendLE32(value.0, to: &data)
            appendLE32(value.1, to: &data)
            appendLE32(value.2, to: &data)
            appendLE32(value.3, to: &data)
        }
        let decoded = try decodeOverlay(
            data, expectedCount: values.count, expectedHash: sha256(data)
        )
        guard decoded.count == 3,
              decoded[0].targetVA == values[0].0,
              decoded[1].originalWord == 8,
              decoded[2].candidateWord == values[2].2 else {
            throw StagerError.invalidOverlay("synthetic record round-trip mismatch")
        }
        return "Stage G overlay format self-test PASS (3 synthetic records; no production memory touched)."
    }
}
