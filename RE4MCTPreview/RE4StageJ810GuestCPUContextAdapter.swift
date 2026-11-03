import Foundation

// Stage J.8.10: data-only adapter contract for the actual forced-Resume
// InstallContext tail in the pinned iOS 4.2.1 / 8C148 ARMv6 provider.
// It prepares an immutable successor context and NEVER applies it to a live
// core, fetches Guest instructions, updates a real CPSR, or performs BX.

public enum RE4StageJ810AdapterError: Error, Equatable {
    case invalidRegisterFileCount(Int)
    case sourceStateMustBeARM
    case invalidCanonicalPC(state: RE4ARMv6InstructionSet, value: UInt32)
    case providerFrameRegisterMismatch(expected: UInt32, actual: UInt32)
}

public struct RE4StageJ810ConditionFlags: Equatable {
    public let negative: Bool
    public let zero: Bool
    public let carry: Bool
    public let overflow: Bool

    public init(negative: Bool, zero: Bool, carry: Bool, overflow: Bool) {
        self.negative = negative
        self.zero = zero
        self.carry = carry
        self.overflow = overflow
    }
}

/// Register-file and status subset currently represented by RE4GuestARMv6Core.
/// R15 is stored as a canonical instruction address; ARM/Thumb state is separate.
/// This is deliberately not advertised as a complete architectural CPSR image.
public struct RE4StageJ810ArchitecturalState: Equatable {
    public let registers: [UInt32]
    public let flags: RE4StageJ810ConditionFlags
    public let instructionState: RE4ARMv6InstructionSet

    public init(
        registers: [UInt32],
        flags: RE4StageJ810ConditionFlags,
        instructionState: RE4ARMv6InstructionSet
    ) throws {
        guard registers.count == 16 else {
            throw RE4StageJ810AdapterError.invalidRegisterFileCount(registers.count)
        }
        let pc = registers[15]
        switch instructionState {
        case .arm where (pc & 0x3) != 0:
            throw RE4StageJ810AdapterError.invalidCanonicalPC(state: .arm, value: pc)
        case .thumb where (pc & 0x1) != 0:
            throw RE4StageJ810AdapterError.invalidCanonicalPC(state: .thumb, value: pc)
        default:
            break
        }
        self.registers = registers
        self.flags = flags
        self.instructionState = instructionState
    }

    public var r0: UInt32 { registers[0] }
    public var r7: UInt32 { registers[7] }
    public var sp: UInt32 { registers[13] }
    public var lr: UInt32 { registers[14] }
    public var pc: UInt32 { registers[15] }
}

public enum RE4StageJ810ProviderPath: String, Equatable {
    case forcedPhase2InstallContext
}

/// Prepared state immediately after the provider's final BX has selected its
/// target, expressed as immutable data. It is not an executed transfer.
public struct RE4StageJ810PreparedContext: Equatable {
    public let providerPath: RE4StageJ810ProviderPath
    public let frameAddress: UInt32
    public let providerInstructionAddresses: [UInt32]
    public let stateBefore: RE4StageJ810ArchitecturalState
    public let stateAfterPlannedTransfer: RE4StageJ810ArchitecturalState
    public let rawBXOperand: UInt32
    public let changedRegisterIndices: [Int]
    public let preservedConditionFlags: Bool
    public let fullCPSRRestored: Bool
    public let targetFunctionEpilogueMustRestoreCoreRegisters: [String]
    public let targetFunctionEpilogueMustRestoreVFPRegisters: [String]
    public let guestCoreHasThumbExecution: Bool
    public let guestCoreImplementsVFPStackTransfers: Bool
    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let liveCPUStateMutated: Bool
    public let bxExecuted: Bool

    public var targetState: RE4ARMv6InstructionSet { stateAfterPlannedTransfer.instructionState }
    public var targetPC: UInt32 { stateAfterPlannedTransfer.pc }
    public var r0AfterBX: UInt32 { stateAfterPlannedTransfer.r0 }
}

public enum RE4StageJ810GuestCPUContextAdapter {
    /// Actual ARM instructions in the forced _unwind_phase2_forced path:
    /// LDR R7,[R4,#0x20]; LDR SP,[R4,#0x28]; LDR R0,[R4,#0x24]; BX R0.
    /// The neighbouring 0x358CF9D0 sequence belongs to normal _unwind_phase2.
    public static let forcedInstallRestoreInstructionAddresses: [UInt32] = [
        0x358CF8DC, 0x358CF8E0, 0x358CF8E4, 0x358CF8E8
    ]

    public static let normalInstallRestoreInstructionAddresses: [UInt32] = [
        0x358CF9D0, 0x358CF9D4, 0x358CF9D8, 0x358CF9DC
    ]

    /// Build a pure successor-state projection for the forced Resume route used
    /// by Res4 initializer #101. R4 must still point at the selected SJLJ frame,
    /// as it does at the provider's InstallContext tail.
    public static func prepareForcedInstallContext(
        current: RE4StageJ810ArchitecturalState,
        frame: RE4StageJ89SJLJFrame,
        stackRange: RE4StageJ89AddressRange,
        codeRange: RE4StageJ89AddressRange
    ) throws -> RE4StageJ810PreparedContext {
        guard current.instructionState == .arm else {
            throw RE4StageJ810AdapterError.sourceStateMustBeARM
        }
        guard current.registers[4] == frame.baseAddress else {
            throw RE4StageJ810AdapterError.providerFrameRegisterMismatch(
                expected: frame.baseAddress, actual: current.registers[4])
        }

        let profile = try RE4StageJ89ContextRestorePreconditions.inspect(
            frame: frame, stackRange: stackRange, codeRange: codeRange)

        var nextRegisters = current.registers
        // The provider loads the raw PC operand into R0 immediately before BX.
        // BX does not modify R0, so the raw value survives into the target.
        nextRegisters[0] = profile.rawContinuationPC
        nextRegisters[7] = profile.savedR7
        nextRegisters[13] = profile.savedSP
        nextRegisters[15] = profile.continuationPC

        let next = try RE4StageJ810ArchitecturalState(
            registers: nextRegisters,
            flags: current.flags,
            instructionState: profile.instructionState == .arm ? .arm : .thumb)

        let changed = current.registers.indices.filter {
            current.registers[$0] != next.registers[$0]
        }
        return RE4StageJ810PreparedContext(
            providerPath: .forcedPhase2InstallContext,
            frameAddress: frame.baseAddress,
            providerInstructionAddresses: forcedInstallRestoreInstructionAddresses,
            stateBefore: current,
            stateAfterPlannedTransfer: next,
            rawBXOperand: profile.rawContinuationPC,
            changedRegisterIndices: changed,
            preservedConditionFlags: current.flags == next.flags,
            fullCPSRRestored: false,
            targetFunctionEpilogueMustRestoreCoreRegisters:
                ["R4", "R5", "R6", "R7", "LR", "R8", "R10", "R11"],
            targetFunctionEpilogueMustRestoreVFPRegisters:
                ["D8", "D9", "D10", "D11", "D12", "D13", "D14", "D15"],
            guestCoreHasThumbExecution: false,
            guestCoreImplementsVFPStackTransfers: true,
            guestInstructionsExecuted: false,
            guestMemoryWrites: 0,
            liveCPUStateMutated: false,
            bxExecuted: false)
    }
}
