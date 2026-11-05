import Foundation

// Stage J.8: host-only ARMv6 BX/context-restore harness.
// All frame bytes are local synthetic Data. This file never accesses Guest Memory,
// writes architectural CPU registers, executes instructions, or performs a branch.

public enum RE4StageJ8Error: Error, CustomStringConvertible {
    case misalignedFrameBase(UInt32)
    case invalidFrameLength(Int)
    case frameWordOutOfBounds(Int)
    case invalidCodeRange(UInt32, UInt32)
    case stackPointerNotEightByteAligned(UInt32)
    case unpredictableARMBranchAlignment(UInt32)
    case branchTargetOutOfRange(raw: UInt32, normalized: UInt32, state: RE4StageJ8InstructionState)
    case invalidJ7Plan(String)

    public var description: String {
        switch self {
        case .misalignedFrameBase(let value):
            return String(format: "Synthetic frame base 0x%08X is not word-aligned", value)
        case .invalidFrameLength(let length):
            return "Synthetic frame must contain exactly 0x2C bytes; got \(length)"
        case .frameWordOutOfBounds(let offset):
            return String(format: "Synthetic frame word at offset 0x%X is out of bounds", offset)
        case .invalidCodeRange(let start, let end):
            return String(format: "Invalid synthetic code range [0x%08X, 0x%08X)", start, end)
        case .stackPointerNotEightByteAligned(let value):
            return String(format: "Restored SP 0x%08X is not 8-byte aligned", value)
        case .unpredictableARMBranchAlignment(let value):
            return String(format: "BX ARM target 0x%08X has low bits 10 (ARMv6 UNPREDICTABLE)", value)
        case .branchTargetOutOfRange(let raw, let normalized, let state):
            return String(format: "BX %@ target raw=0x%08X normalized=0x%08X is outside the synthetic code range", state.rawValue, raw, normalized)
        case .invalidJ7Plan(let message):
            return "Stage J.7 plan rejected: \(message)"
        }
    }
}

public enum RE4StageJ8InstructionState: String, Equatable {
    case arm = "ARM"
    case thumb = "Thumb"
}

/// A synthetic executable-address window. Upper bound is exclusive.
/// It describes allowed addresses for tests only; it is not a mapped Guest image.
public struct RE4StageJ8SyntheticCodeRange: Equatable {
    public let lowerBound: UInt32
    public let upperBoundExclusive: UInt32

    public init(lowerBound: UInt32, upperBoundExclusive: UInt32) throws {
        guard lowerBound < upperBoundExclusive,
              (lowerBound & 1) == 0,
              (upperBoundExclusive & 1) == 0 else {
            throw RE4StageJ8Error.invalidCodeRange(lowerBound, upperBoundExclusive)
        }
        self.lowerBound = lowerBound
        self.upperBoundExclusive = upperBoundExclusive
    }

    public func contains(_ address: UInt32) -> Bool {
        address >= lowerBound && address < upperBoundExclusive
    }
}

/// The result of interpreting an ARMv6 BX operand without performing BX.
/// Valid ARM operands have low bits 00; Thumb operands clear bit 0.
public struct RE4StageJ8BXTarget: Equatable {
    public let rawPointer: UInt32
    public let address: UInt32
    public let state: RE4StageJ8InstructionState
}

/// Exactly the local byte span needed for the audited SJLJ frame fields through +0x28.
/// Word access is explicitly little-endian, matching the pinned ARMv6 target.
public struct RE4StageJ8SyntheticFrame: Equatable {
    public static let byteCount = 0x2C

    public let baseAddress: UInt32
    private var bytes: [UInt8]

    public init(baseAddress: UInt32) throws {
        guard (baseAddress & 0x3) == 0 else {
            throw RE4StageJ8Error.misalignedFrameBase(baseAddress)
        }
        self.baseAddress = baseAddress
        self.bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    public init(baseAddress: UInt32, bytes: [UInt8]) throws {
        guard (baseAddress & 0x3) == 0 else {
            throw RE4StageJ8Error.misalignedFrameBase(baseAddress)
        }
        guard bytes.count == Self.byteCount else {
            throw RE4StageJ8Error.invalidFrameLength(bytes.count)
        }
        self.baseAddress = baseAddress
        self.bytes = bytes
    }

    public var byteCount: Int { bytes.count }
    public var rawBytes: [UInt8] { bytes }

    public mutating func storeWord(at offset: Int, value: UInt32) throws {
        guard offset >= 0, offset <= bytes.count - 4, (offset & 0x3) == 0 else {
            throw RE4StageJ8Error.frameWordOutOfBounds(offset)
        }
        for index in 0..<4 {
            bytes[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xFF)
        }
    }

    public func loadWord(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4, (offset & 0x3) == 0 else {
            throw RE4StageJ8Error.frameWordOutOfBounds(offset)
        }
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }
}

/// A data-only projection of the fields the pinned phase-2 path consumes.
/// This is not a live register file and cannot be applied to a CPU.
public struct RE4StageJ8SyntheticRestoreSnapshot: Equatable {
    public let frameBaseAddress: UInt32
    public let lsdaVA: UInt32
    public let selectorWord: UInt32
    public let unwindGR0: UInt32
    public let unwindGR1: UInt32
    public let restoredR7: UInt32
    public let restoredSP: UInt32
    public let rawBXOperand: UInt32
    public let targetPC: UInt32
    public let targetState: RE4StageJ8InstructionState

    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let cpuContextApplied: Bool
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ8SyntheticContextRestoreHarness {
    // These offsets are relative to the frame base, not the caller's entry SP.
    public static let selectorOffset = 0x04
    public static let gr0Offset = 0x08
    public static let gr1Offset = 0x0C
    public static let lsdaOffset = 0x1C
    public static let savedR7Offset = 0x20
    public static let savedPCOffset = 0x24
    public static let savedSPOffset = 0x28
    public static let requiredSPAlignment: UInt32 = 8

    /// Builds a local test frame from the pinned Stage J.7 data plan.
    /// The method writes only to a Swift byte array owned by this test harness.
    public static func makeSyntheticFrame(from plan: RE4StageJ7CleanupContextPlan) throws -> RE4StageJ8SyntheticFrame {
        guard !plan.controlTransferPerformed else {
            throw RE4StageJ8Error.invalidJ7Plan("the source model claims a control transfer occurred")
        }
        guard plan.frameBaseOffsetFromPostPrologueSP == RE4StageJ7LandingPadContextModel.frameBaseOffset else {
            throw RE4StageJ8Error.invalidJ7Plan("unexpected frame-base offset")
        }
        guard plan.cleanupContinuationPC == plan.savedContinuationPC else {
            throw RE4StageJ8Error.invalidJ7Plan("saved PC and cleanup continuation disagree")
        }
        guard plan.personalityReturnCode == RE4StageJ7LandingPadContextModel.personalityInstallContextCode else {
            throw RE4StageJ8Error.invalidJ7Plan("unexpected personality return code")
        }

        var frame = try RE4StageJ8SyntheticFrame(baseAddress: plan.frameAddress)
        try frame.storeWord(at: selectorOffset, value: plan.setIPStoredSelector)
        try frame.storeWord(at: gr0Offset, value: plan.setGR0Value)
        try frame.storeWord(at: gr1Offset, value: plan.setGR1Value)
        try frame.storeWord(at: lsdaOffset, value: plan.lsdaVA)
        try frame.storeWord(at: savedR7Offset, value: plan.savedR7)
        try frame.storeWord(at: savedPCOffset, value: plan.savedContinuationPC)
        try frame.storeWord(at: savedSPOffset, value: plan.savedSP)
        return frame
    }

    /// Models the data readback and BX target interpretation. It does not branch.
    public static func inspectRestore(frame: RE4StageJ8SyntheticFrame,
                                      codeRange: RE4StageJ8SyntheticCodeRange) throws -> RE4StageJ8SyntheticRestoreSnapshot {
        let selector = try frame.loadWord(at: selectorOffset)
        let gr0 = try frame.loadWord(at: gr0Offset)
        let gr1 = try frame.loadWord(at: gr1Offset)
        let lsda = try frame.loadWord(at: lsdaOffset)
        let r7 = try frame.loadWord(at: savedR7Offset)
        let rawPC = try frame.loadWord(at: savedPCOffset)
        let sp = try frame.loadWord(at: savedSPOffset)

        guard (sp & (requiredSPAlignment - 1)) == 0 else {
            throw RE4StageJ8Error.stackPointerNotEightByteAligned(sp)
        }
        let bx = try interpretBXOperand(rawPC, codeRange: codeRange)
        return RE4StageJ8SyntheticRestoreSnapshot(
            frameBaseAddress: frame.baseAddress,
            lsdaVA: lsda,
            selectorWord: selector,
            unwindGR0: gr0,
            unwindGR1: gr1,
            restoredR7: r7,
            restoredSP: sp,
            rawBXOperand: rawPC,
            targetPC: bx.address,
            targetState: bx.state,
            guestInstructionsExecuted: false,
            guestMemoryWrites: 0,
            cpuContextApplied: false,
            controlTransferPerformed: false)
    }

    /// ARMv6 interworking semantics for BX, represented as data only.
    /// Bit 0 selects Thumb. For an ARM target, low bits 10 are UNPREDICTABLE;
    /// a valid ARM operand already has low bits 00. Thumb clears bit 0 only.
    public static func interpretBXOperand(_ rawPointer: UInt32,
                                          codeRange: RE4StageJ8SyntheticCodeRange) throws -> RE4StageJ8BXTarget {
        let state: RE4StageJ8InstructionState = (rawPointer & 1) == 1 ? .thumb : .arm
        if state == .arm && (rawPointer & 0x2) != 0 {
            throw RE4StageJ8Error.unpredictableARMBranchAlignment(rawPointer)
        }
        let normalized: UInt32 = state == .thumb ? (rawPointer & ~UInt32(1)) : rawPointer
        guard codeRange.contains(normalized) else {
            throw RE4StageJ8Error.branchTargetOutOfRange(raw: rawPointer, normalized: normalized, state: state)
        }
        return RE4StageJ8BXTarget(rawPointer: rawPointer, address: normalized, state: state)
    }
}
