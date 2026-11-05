import Foundation

// Stage J.8.9: static ARMv6 preconditions for the pinned #101 SJLJ context
// restore. Data-only: no CPU register write, Guest Memory read/write, BX or transfer.

public enum RE4StageJ89InstructionState: String, Equatable {
    case arm = "ARM"
    case thumb = "Thumb"
}

public enum RE4StageJ89Error: Error, Equatable {
    case misalignedFrameBase(UInt32)
    case invalidFrameLength(Int)
    case wordOutOfBounds(Int)
    case frameRangeOverflow(UInt32)
    case savedSPNotEightByteAligned(UInt32)
    case savedSPOutsideStack(UInt32)
    case savedR7NotWordAligned(UInt32)
    case savedR7OutsideStack(UInt32)
    case savedR7Relation(expected: UInt32, actual: UInt32)
    case savedSPRelation(expected: UInt32, actual: UInt32)
    case armBXOperandUnpredictable(UInt32)
    case bxTargetOutsideText(raw: UInt32, normalized: UInt32)
    case stackRangeInvalid
    case wrongPersonalityGPR0(UInt32)
    case wrongPersonalityGPR1(UInt32)
    case wrongLSDA(UInt32)
}

public struct RE4StageJ89AddressRange: Equatable {
    public let lowerBound: UInt32
    public let upperBoundExclusive: UInt32

    public init(lowerBound: UInt32, upperBoundExclusive: UInt32) throws {
        guard lowerBound < upperBoundExclusive else { throw RE4StageJ89Error.stackRangeInvalid }
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
    }

    public func contains(_ address: UInt32) -> Bool {
        address >= lowerBound && address < upperBoundExclusive
    }
}

public struct RE4StageJ89SJLJFrame: Equatable {
    public static let byteCount = 0x2C
    public static let predecessorOffset = 0x00
    public static let selectorOffset = 0x04
    public static let gr0Offset = 0x08
    public static let gr1Offset = 0x0C
    public static let personalityOffset = 0x18
    public static let lsdaOffset = 0x1C
    public static let savedR7Offset = 0x20
    public static let continuationPCOffset = 0x24
    public static let savedSPOffset = 0x28

    public let baseAddress: UInt32
    private var bytes: [UInt8]

    public init(baseAddress: UInt32) throws {
        guard (baseAddress & 3) == 0 else { throw RE4StageJ89Error.misalignedFrameBase(baseAddress) }
        self.baseAddress = baseAddress
        self.bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    public init(baseAddress: UInt32, bytes: [UInt8]) throws {
        guard (baseAddress & 3) == 0 else { throw RE4StageJ89Error.misalignedFrameBase(baseAddress) }
        guard bytes.count == Self.byteCount else { throw RE4StageJ89Error.invalidFrameLength(bytes.count) }
        self.baseAddress = baseAddress
        self.bytes = bytes
    }

    public mutating func storeWord(at offset: Int, value: UInt32) throws {
        guard offset >= 0, offset <= bytes.count - 4, (offset & 3) == 0 else {
            throw RE4StageJ89Error.wordOutOfBounds(offset)
        }
        for n in 0..<4 { bytes[offset+n] = UInt8((value >> UInt32(n*8)) & 0xFF) }
    }

    public func loadWord(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4, (offset & 3) == 0 else {
            throw RE4StageJ89Error.wordOutOfBounds(offset)
        }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) |
            (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
    }
}

public struct RE4StageJ89RestorationProfile: Equatable {
    public let savedR7: UInt32
    public let savedSP: UInt32
    public let rawContinuationPC: UInt32
    public let continuationPC: UInt32
    public let instructionState: RE4StageJ89InstructionState
    public let personalityGR0ExceptionPointer: UInt32
    public let personalityGR1: UInt32
    public let lsdaVA: UInt32
    public let providerRestoresR7: Bool
    public let providerRestoresSP: Bool
    public let providerRestoresPC: Bool
    public let providerRestoresOtherGPRs: Bool
    public let providerRestoresLR: Bool
    public let providerRestoresFullCPSR: Bool
    public let bxDerivesInstructionStateFromPCBit0: Bool
    public let targetStackSavedCoreRegisters: [String]
    public let targetEpiloguePopsSavedLRIntoPC: Bool
    public let targetStackSavedVFPRegisters: [String]
    public let targetEpilogueRestoresVFPRegisters: Bool
    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let cpuContextApplied: Bool
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ89ContextRestorePreconditions {
    public static let coreSaveBytes: UInt32 = 0x14
    public static let extendedCoreSaveBytes: UInt32 = 0x0C
    public static let vfpSaveBytes: UInt32 = 0x40
    public static let localAllocationBytes: UInt32 = 0x60
    public static let totalPrologueStackDelta: UInt32 = 0xC0
    public static let savedR7FromSavedSPOffset: UInt32 = 0xB8
    public static let frameBaseFromSavedSPOffset: UInt32 = 0x18
    public static let requiredSPAlignment: UInt32 = 8
    public static let expectedLSDA: UInt32 = 0x001C0996

    public static func inspect(
        frame: RE4StageJ89SJLJFrame,
        stackRange: RE4StageJ89AddressRange,
        codeRange: RE4StageJ89AddressRange
    ) throws -> RE4StageJ89RestorationProfile {
        let end64 = UInt64(frame.baseAddress) + UInt64(RE4StageJ89SJLJFrame.byteCount)
        guard end64 <= UInt64(UInt32.max) + 1 else {
            throw RE4StageJ89Error.frameRangeOverflow(frame.baseAddress)
        }
        guard stackRange.contains(frame.baseAddress),
              end64 <= UInt64(stackRange.upperBoundExclusive) else {
            throw RE4StageJ89Error.savedSPOutsideStack(frame.baseAddress)
        }

        let gr0 = try frame.loadWord(at: RE4StageJ89SJLJFrame.gr0Offset)
        let gr1 = try frame.loadWord(at: RE4StageJ89SJLJFrame.gr1Offset)
        let lsda = try frame.loadWord(at: RE4StageJ89SJLJFrame.lsdaOffset)
        let r7 = try frame.loadWord(at: RE4StageJ89SJLJFrame.savedR7Offset)
        let rawPC = try frame.loadWord(at: RE4StageJ89SJLJFrame.continuationPCOffset)
        let sp = try frame.loadWord(at: RE4StageJ89SJLJFrame.savedSPOffset)

        guard (sp & (requiredSPAlignment - 1)) == 0 else {
            throw RE4StageJ89Error.savedSPNotEightByteAligned(sp)
        }
        guard stackRange.contains(sp) else { throw RE4StageJ89Error.savedSPOutsideStack(sp) }
        guard (r7 & 3) == 0 else { throw RE4StageJ89Error.savedR7NotWordAligned(r7) }
        guard stackRange.contains(r7) else { throw RE4StageJ89Error.savedR7OutsideStack(r7) }

        let expectedSP = frame.baseAddress &- frameBaseFromSavedSPOffset
        guard sp == expectedSP else {
            throw RE4StageJ89Error.savedSPRelation(expected: expectedSP, actual: sp)
        }
        let expectedR7 = sp &+ savedR7FromSavedSPOffset
        guard r7 == expectedR7 else {
            throw RE4StageJ89Error.savedR7Relation(expected: expectedR7, actual: r7)
        }
        guard gr0 != 0 else { throw RE4StageJ89Error.wrongPersonalityGPR0(gr0) }
        guard gr1 == 0 else { throw RE4StageJ89Error.wrongPersonalityGPR1(gr1) }
        guard lsda == expectedLSDA else { throw RE4StageJ89Error.wrongLSDA(lsda) }

        let state: RE4StageJ89InstructionState = (rawPC & 1) == 1 ? .thumb : .arm
        if state == .arm && (rawPC & 2) != 0 {
            throw RE4StageJ89Error.armBXOperandUnpredictable(rawPC)
        }
        let normalizedPC = state == .thumb ? (rawPC & ~UInt32(1)) : rawPC
        guard codeRange.contains(normalizedPC) else {
            throw RE4StageJ89Error.bxTargetOutsideText(raw: rawPC, normalized: normalizedPC)
        }

        return RE4StageJ89RestorationProfile(
            savedR7: r7, savedSP: sp,
            rawContinuationPC: rawPC, continuationPC: normalizedPC,
            instructionState: state,
            personalityGR0ExceptionPointer: gr0, personalityGR1: gr1, lsdaVA: lsda,
            providerRestoresR7: true, providerRestoresSP: true, providerRestoresPC: true,
            providerRestoresOtherGPRs: false, providerRestoresLR: false,
            providerRestoresFullCPSR: false, bxDerivesInstructionStateFromPCBit0: true,
            targetStackSavedCoreRegisters: ["R4","R5","R6","R7","LR","R8","R10","R11"],
            targetEpiloguePopsSavedLRIntoPC: true,
            targetStackSavedVFPRegisters: (8...15).map { "D\($0)" },
            targetEpilogueRestoresVFPRegisters: true,
            guestInstructionsExecuted: false, guestMemoryWrites: 0,
            cpuContextApplied: false, controlTransferPerformed: false)
    }
}
