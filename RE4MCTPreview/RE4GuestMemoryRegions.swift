import Foundation
import CryptoKit

/// Mach-compatible VM protection bits: READ=1, WRITE=2, EXECUTE=4.
public struct RE4GuestMemoryProtection: OptionSet, Equatable {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let read = RE4GuestMemoryProtection(rawValue: 1)
    public static let write = RE4GuestMemoryProtection(rawValue: 2)
    public static let execute = RE4GuestMemoryProtection(rawValue: 4)

    public var label: String {
        var value = ""
        value += contains(.read) ? "R" : "-"
        value += contains(.write) ? "W" : "-"
        value += contains(.execute) ? "X" : "-"
        return value
    }

    public func isSubset(of other: RE4GuestMemoryProtection) -> Bool {
        intersection(other) == self
    }
}

/// One immutable cache/file backing shared by every virtual region that references it.
/// Writes are stored as 4 KiB shadow pages, so the original mapped Data is never modified.
public final class RE4GuestMemoryBacking {
    public let data: Data
    public let pageSize: Int
    private var dirtyPages: [UInt64: [UInt8]] = [:]

    public init(data: Data, pageSize: Int = 4096) {
        precondition(pageSize > 0 && (pageSize & (pageSize - 1)) == 0)
        self.data = data
        self.pageSize = pageSize
    }

    public var byteCount: Int { data.count }
    public var dirtyPageCount: Int { dirtyPages.count }

    private func validate(offset: UInt64, count: Int) throws {
        guard count >= 0,
              offset <= UInt64(data.count),
              UInt64(count) <= UInt64(data.count) - offset else {
            throw RE4GuestRuntimeError.invalidMemoryRange(
                address: UInt32(truncatingIfNeeded: offset),
                count: count
            )
        }
    }

    public func copyBytes(at offset: UInt64, count: Int) throws -> Data {
        try validate(offset: offset, count: count)
        guard count > 0 else { return Data() }

        var result: [UInt8] = []
        result.reserveCapacity(count)
        var cursor = offset
        var remaining = count

        while remaining > 0 {
            let pageIndex = cursor / UInt64(pageSize)
            let pageStart = pageIndex * UInt64(pageSize)
            let withinPage = Int(cursor - pageStart)
            let availableInBacking = data.count - Int(pageStart)
            let pageLength = min(pageSize, availableInBacking)
            let chunk = min(remaining, pageLength - withinPage)

            if let shadow = dirtyPages[pageIndex] {
                result.append(contentsOf: shadow[withinPage..<(withinPage + chunk)])
            } else {
                let start = Int(cursor)
                result.append(contentsOf: data[start..<(start + chunk)])
            }

            cursor += UInt64(chunk)
            remaining -= chunk
        }
        return Data(result)
    }

    public func writeBytes(at offset: UInt64, data payload: Data) throws {
        try validate(offset: offset, count: payload.count)
        guard !payload.isEmpty else { return }

        let input = [UInt8](payload)
        var sourceOffset = 0
        var cursor = offset
        var remaining = input.count

        while remaining > 0 {
            let pageIndex = cursor / UInt64(pageSize)
            let pageStart = pageIndex * UInt64(pageSize)
            let withinPage = Int(cursor - pageStart)
            let availableInBacking = data.count - Int(pageStart)
            let pageLength = min(pageSize, availableInBacking)
            let chunk = min(remaining, pageLength - withinPage)

            var shadow = dirtyPages[pageIndex] ?? Array(
                data[Int(pageStart)..<(Int(pageStart) + pageLength)]
            )
            shadow.replaceSubrange(
                withinPage..<(withinPage + chunk),
                with: input[sourceOffset..<(sourceOffset + chunk)]
            )
            dirtyPages[pageIndex] = shadow

            cursor += UInt64(chunk)
            sourceOffset += chunk
            remaining -= chunk
        }
    }

    public func zeroBytes(at offset: UInt64, count: Int) throws {
        guard count >= 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRange(
                address: UInt32(truncatingIfNeeded: offset),
                count: count
            )
        }
        try writeBytes(at: offset, data: Data(repeating: 0, count: count))
    }
}

/// A sparse Guest VA range backed by a slice of one shared file/data object.
public struct RE4GuestMemoryRegion {
    public let name: String
    public let guestBase: UInt32
    public let length: UInt64
    public let backing: RE4GuestMemoryBacking
    public let backingOffset: UInt64
    public let maxProtection: RE4GuestMemoryProtection
    public let initialProtection: RE4GuestMemoryProtection

    public init(
        name: String,
        guestBase: UInt32,
        length: UInt64,
        backing: RE4GuestMemoryBacking,
        backingOffset: UInt64,
        maxProtection: RE4GuestMemoryProtection,
        initialProtection: RE4GuestMemoryProtection
    ) {
        self.name = name
        self.guestBase = guestBase
        self.length = length
        self.backing = backing
        self.backingOffset = backingOffset
        self.maxProtection = maxProtection
        self.initialProtection = initialProtection
    }

    public var guestEndExclusive: UInt64 { UInt64(guestBase) + length }
    public var backingEndExclusive: UInt64 { backingOffset + length }
}

/// The first pinned system image: iPhone1,2 / iOS 4.2.1 / build 8C148 / ARMv6.
/// Non-zero slide is deliberately rejected until cache slide/fixup handling is implemented.
public enum RE4IOS421SharedCacheMapper {
    public static let expectedSize = 166_722_970
    public static let expectedSHA256 =
        "ab9dbbc1e7efcc6e8c7f79d20f90dab62d4309be5269a2055e3cd5136a62d024"
    public static let pinnedSlide: Int64 = 0

    private struct ExpectedMapping {
        let name: String
        let address: UInt64
        let size: UInt64
        let fileOffset: UInt64
        let protection: RE4GuestMemoryProtection
    }

    private static let expectedMappings: [ExpectedMapping] = [
        ExpectedMapping(
            name: "iOS421_SHARED_CACHE_TEXT_RX",
            address: 0x30000000,
            size: 0x079C9000,
            fileOffset: 0x00000000,
            protection: [.read, .execute]
        ),
        ExpectedMapping(
            name: "iOS421_SHARED_CACHE_DATA_RW",
            address: 0x3E000000,
            size: 0x00BFC000,
            fileOffset: 0x079C9000,
            protection: [.read, .write]
        ),
        ExpectedMapping(
            name: "iOS421_SHARED_CACHE_LINKEDIT_RO",
            address: 0x379C9000,
            size: 0x01875000,
            fileOffset: 0x085C5000,
            protection: [.read]
        )
    ]

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readLE32(data, offset)) |
            (UInt64(readLE32(data, offset + 4)) << 32)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHeader(_ data: Data) throws -> (signatureOffset: UInt64, tailAddress: UInt64) {
        guard data.count == expectedSize else {
            throw RE4IOS421SharedCacheMapperError.invalidFileSize(
                actual: data.count, expected: expectedSize
            )
        }

        let actualHash = hex(Data(SHA256.hash(data: data)))
        guard actualHash == expectedSHA256 else {
            throw RE4IOS421SharedCacheMapperError.hashMismatch(actual: actualHash)
        }

        let expectedMagic = Array("dyld_v1   armv6".utf8) + [0]
        guard Array(data.prefix(16)) == expectedMagic else {
            throw RE4IOS421SharedCacheMapperError.wrongArchitecture
        }

        let mappingOffset = readLE32(data, 16)
        let mappingCount = readLE32(data, 20)
        let imagesCount = readLE32(data, 28)
        let dyldBaseAddress = readLE64(data, 32)
        let signatureOffset = readLE64(data, 40)
        let signatureSize = readLE64(data, 48)
        let slideInfoOffset = readLE64(data, 56)
        let slideInfoSize = readLE64(data, 64)

        guard mappingOffset == 72, mappingCount == 3, imagesCount == 360,
              dyldBaseAddress == 0x2FE00000,
              signatureOffset == 0x09E3A000, signatureSize == 0,
              slideInfoOffset == 0, slideInfoSize == 0 else {
            throw RE4IOS421SharedCacheMapperError.headerMismatch
        }

        let recordSize = 32
        for (index, expected) in expectedMappings.enumerated() {
            let offset = Int(mappingOffset) + index * recordSize
            let address = readLE64(data, offset)
            let size = readLE64(data, offset + 8)
            let fileOffset = readLE64(data, offset + 16)
            let maxProtection = Int32(bitPattern: readLE32(data, offset + 24))
            let initialProtection = Int32(bitPattern: readLE32(data, offset + 28))
            guard address == expected.address,
                  size == expected.size,
                  fileOffset == expected.fileOffset,
                  maxProtection == expected.protection.rawValue,
                  initialProtection == expected.protection.rawValue else {
                throw RE4IOS421SharedCacheMapperError.mappingMismatch(index: index)
            }
        }

        let signatureLength = UInt64(data.count) - signatureOffset
        let tailAddress = expectedMappings[2].address + expectedMappings[2].size
        guard signatureOffset + signatureLength == UInt64(data.count),
              tailAddress == 0x3923E000,
              signatureLength == 810_394 else {
            throw RE4IOS421SharedCacheMapperError.codeSignatureTailMismatch
        }

        return (signatureOffset, tailAddress)
    }

    public static func mount(
        data: Data,
        into memory: RE4GuestARMv6Memory,
        slide: Int64 = pinnedSlide
    ) throws -> RE4IOS421SharedCacheMountResult {
        guard slide == pinnedSlide else {
            throw RE4IOS421SharedCacheMapperError.unsupportedSlide(slide)
        }

        let header = try validateHeader(data)
        let backing = RE4GuestMemoryBacking(data: data)
        var regions: [RE4GuestMemoryRegion] = []

        for mapping in expectedMappings {
            regions.append(RE4GuestMemoryRegion(
                name: mapping.name,
                guestBase: UInt32(mapping.address),
                length: mapping.size,
                backing: backing,
                backingOffset: mapping.fileOffset,
                maxProtection: mapping.protection,
                initialProtection: mapping.protection
            ))
        }

        let signatureLength = UInt64(data.count) - header.signatureOffset
        regions.append(RE4GuestMemoryRegion(
            name: "iOS421_SHARED_CACHE_CODE_SIGNATURE_RO",
            guestBase: UInt32(header.tailAddress),
            length: signatureLength,
            backing: backing,
            backingOffset: header.signatureOffset,
            maxProtection: .read,
            initialProtection: .read
        ))

        try memory.mountRegions(regions)

        return RE4IOS421SharedCacheMountResult(
            slide: slide,
            backing: backing,
            regions: regions,
            report: [
                "iOS 4.2.1 Build 8C148 ARMv6 shared-cache mount PASS",
                "SHA-256: \(expectedSHA256)",
                "Backing bytes: \(data.count)",
                "Slide: \(slide)",
                "Shared backing objects: 1",
                "Sparse regions mounted: \(regions.count)",
                "TEXT RX: 0x30000000–0x379C9000",
                "LINKEDIT R: 0x379C9000–0x3923E000",
                "CODE SIGNATURE R: 0x3923E000–0x39303D9A",
                "DATA RW: 0x3E000000–0x3EBFC000",
                "The original cache Data is immutable; DATA writes use 4 KiB shadow pages.",
                "No dyld relocation, cache fixup, Res4 relocation, or guest code execution was performed."
            ].joined(separator: "\n")
        )
    }
}

public struct RE4IOS421SharedCacheMountResult {
    public let slide: Int64
    public let backing: RE4GuestMemoryBacking
    public let regions: [RE4GuestMemoryRegion]
    public let report: String

    public var dirtyPageCount: Int { backing.dirtyPageCount }
}

public enum RE4IOS421SharedCacheMapperError: Error, LocalizedError {
    case invalidFileSize(actual: Int, expected: Int)
    case hashMismatch(actual: String)
    case wrongArchitecture
    case headerMismatch
    case mappingMismatch(index: Int)
    case codeSignatureTailMismatch
    case unsupportedSlide(Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidFileSize(let actual, let expected):
            return "Shared-cache file size mismatch: \(actual), expected \(expected)."
        case .hashMismatch(let actual):
            return "Shared-cache SHA-256 mismatch: \(actual)."
        case .wrongArchitecture:
            return "The file is not the pinned dyld_v1 ARMv6 shared cache."
        case .headerMismatch:
            return "The iOS 4.2.1/8C148 shared-cache header does not match the verified baseline."
        case .mappingMismatch(let index):
            return "Shared-cache mapping table entry \(index) does not match the verified 8C148 layout."
        case .codeSignatureTailMismatch:
            return "Shared-cache code-signature tail does not match the verified 8C148 extent."
        case .unsupportedSlide(let slide):
            return "Slide \(slide) is not supported; this milestone is pinned to 8C148 slide=0."
        }
    }
}

public extension RE4GuestARMv6Memory {
    /// Exercises sparse routing, shared backing, W^X, read-only regions, and dense-range protection.
    /// No original game image or instruction execution is involved.
    static func runSparseRegionSelfTest() throws -> String {
        let memory = RE4GuestARMv6Memory(
            size: 0x10000,
            heapBase: 0x8000,
            stackTop: 0xF000,
            returnSentinel: 0x7000
        )

        let seed = Data([0x00, 0x00, 0xA0, 0xE1] + [UInt8](repeating: 0x5A, count: 0x4FFC))
        let backing = RE4GuestMemoryBacking(data: seed)
        let regions = [
            RE4GuestMemoryRegion(
                name: "TEST_TEXT_RX", guestBase: 0x30000000, length: 0x1000,
                backing: backing, backingOffset: 0,
                maxProtection: [.read, .execute], initialProtection: [.read, .execute]
            ),
            RE4GuestMemoryRegion(
                name: "TEST_DATA_RW", guestBase: 0x3E000000, length: 0x1000,
                backing: backing, backingOffset: 0x1000,
                maxProtection: [.read, .write], initialProtection: [.read, .write]
            ),
            RE4GuestMemoryRegion(
                name: "TEST_DATA_ALIAS_RW", guestBase: 0x40000000, length: 0x1000,
                backing: backing, backingOffset: 0x1000,
                maxProtection: [.read, .write], initialProtection: [.read, .write]
            ),
            RE4GuestMemoryRegion(
                name: "TEST_LINKEDIT_R", guestBase: 0x379C9000, length: 0x1000,
                backing: backing, backingOffset: 0x2000,
                maxProtection: .read, initialProtection: .read
            )
        ]
        try memory.mountRegions(regions)

        try memory.write32(0x100, 0x12345678)
        guard try memory.read32(0x100) == 0x12345678 else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("dense low-memory compatibility")
        }
        try memory.setProtectionRange(
            address: 0x1000, length: 0x1000, protection: [.read, .execute]
        )
        guard try memory.readInstruction32(0x1000) == 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("dense execute permission")
        }

        guard try memory.readInstruction32(0x30000000) == 0xE1A00000 else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("sparse executable read")
        }
        guard try memory.read32(0x3E000000) == 0x5A5A5A5A else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("sparse data read")
        }

        do {
            try memory.write32(0x30000000, 0xFFFFFFFF)
            throw RE4GuestRuntimeError.invalidMemoryRegion("RX write unexpectedly succeeded")
        } catch RE4GuestRuntimeError.memoryProtectionViolation { }

        do {
            _ = try memory.readInstruction32(0x3E000000)
            throw RE4GuestRuntimeError.invalidMemoryRegion("RW execute unexpectedly succeeded")
        } catch RE4GuestRuntimeError.memoryProtectionViolation { }

        do {
            try memory.write32(0x2000, 0xFFFFFFFF)
            throw RE4GuestRuntimeError.invalidMemoryRegion("dense RX write unexpectedly succeeded")
        } catch RE4GuestRuntimeError.memoryProtectionViolation { }

        do {
            try memory.write8(0x379C9000, 0xFF)
            throw RE4GuestRuntimeError.invalidMemoryRegion("read-only LINKEDIT write unexpectedly succeeded")
        } catch RE4GuestRuntimeError.memoryProtectionViolation { }

        try memory.write32(0x3E000000, 0x12345678)
        guard try memory.read32(0x40000000) == 0x12345678 else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("shared backing alias visibility")
        }

        do {
            _ = try memory.copyBytes(at: 0x30000FFE, count: 4)
            throw RE4GuestRuntimeError.invalidMemoryRegion("cross-region read unexpectedly succeeded")
        } catch RE4GuestRuntimeError.invalidMemoryRange { }

        do {
            _ = try memory.read8(0x35000000)
            throw RE4GuestRuntimeError.invalidMemoryRegion("unmapped gap read unexpectedly succeeded")
        } catch RE4GuestRuntimeError.invalidMemoryRange { }

        do {
            try memory.mountRegion(RE4GuestMemoryRegion(
                name: "TEST_OVERLAP", guestBase: 0x30000000, length: 0x1000,
                backing: backing, backingOffset: 0, maxProtection: .read,
                initialProtection: .read
            ))
            throw RE4GuestRuntimeError.invalidMemoryRegion("overlapping region unexpectedly mounted")
        } catch RE4GuestRuntimeError.overlappingMemoryRegion { }

        do {
            try memory.mountRegion(RE4GuestMemoryRegion(
                name: "TEST_WX", guestBase: 0x41000000, length: 0x1000,
                backing: backing, backingOffset: 0, maxProtection: [.read, .write, .execute],
                initialProtection: [.read, .write, .execute]
            ))
            throw RE4GuestRuntimeError.invalidMemoryRegion("W+X region unexpectedly mounted")
        } catch RE4GuestRuntimeError.writeExecuteRegionDenied { }

        guard memory.sparseRegionCount == 4,
              memory.hasSparseRegion(named: "TEST_TEXT_RX"),
              backing.dirtyPageCount == 1 else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("sparse-region bookkeeping")
        }

        return [
            "Sparse Guest Memory self-test PASS",
            "Dense low Guest VA remains compatible and separately protected.",
            "Sparse RX / RW / R regions mounted above 0x30000000.",
            "A single immutable backing is shared by multiple Guest VA aliases.",
            "DATA writes are isolated in 4 KiB shadow pages.",
            "RX write rejected; RW execute rejected; R write rejected.",
            "Unmapped gaps, cross-region access, overlap, and W+X rejected.",
            "No iOS shared cache file, IPA, or game code was loaded or executed."
        ].joined(separator: "\n")
    }
}
