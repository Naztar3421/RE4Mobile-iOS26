import Foundation

// Stage J.8.11: transactional boundary between a data-only context candidate
// and the ARM-only Guest Core. This file deliberately models no synthetic CPSR
// bits and no VFP D8-D15 payload.

public enum RE4StageJ811ExecutionMode: String, Equatable {
    /// The current interpreter's operational mode: 32-bit ARM instructions only.
    /// This is not a claim that an unavailable CPSR.T bit was read or captured.
    case arm32Interpreter
    /// A candidate that requires the not-yet-implemented Thumb execution path.
    case thumb16Required
}

public enum RE4StageJ811UnmodeledCPSRState: String, Equatable {
    /// CPSR fields other than N/Z/C/V are not represented by this core.
    /// No values are supplied, defaulted, or inferred for those fields.
    case notRepresentedByCurrentCore
}

public enum RE4StageJ811VFPStateCoverage: String, Equatable {
    /// The current core has no D8-D15 snapshot or stack-restore contract.
    case d8ThroughD15NotCaptured
}

public enum RE4StageJ811CPSRRestoreRequest: String, Equatable {
    /// Commit only the four condition flags represented by the current core.
    case modeledNZCVOnly
    /// Explicit request for a complete CPSR restore; rejected until modeled.
    case fullCPSR
}

public enum RE4StageJ811VFPRestoreRequirement: String, Equatable {
    case notRequired
    case d8ThroughD15Required
}

/// A verified snapshot of exactly the state currently represented by
/// RE4GuestARMv6Core: R0-R15 and N/Z/C/V. The remaining CPSR and VFP state is
/// explicitly unrepresented rather than padded with guessed values.
public struct RE4StageJ811CPUStateSnapshot: Equatable {
    public let registers: [UInt32]
    public let flags: RE4StageJ810ConditionFlags
    public let executionMode: RE4StageJ811ExecutionMode
    public let unmodeledCPSRState: RE4StageJ811UnmodeledCPSRState
    public let vfpStateCoverage: RE4StageJ811VFPStateCoverage

    public var pc: UInt32 { registers[15] }
    public var sp: UInt32 { registers[13] }

    public init(registers: [UInt32], flags: RE4StageJ810ConditionFlags) throws {
        guard registers.count == 16 else {
            throw RE4StageJ811CommitError.invalidRegisterFileCount(registers.count)
        }
        guard (registers[15] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.programCounterNotWordAligned(registers[15])
        }
        guard (registers[13] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.stackPointerNotWordAligned(registers[13])
        }
        self.registers = registers
        self.flags = flags
        self.executionMode = .arm32Interpreter
        self.unmodeledCPSRState = .notRepresentedByCurrentCore
        self.vfpStateCoverage = .d8ThroughD15NotCaptured
    }
}

/// An untrusted complete successor-state request. Construction is intentionally
/// non-throwing so the Core preflight can reject malformed candidates without
/// changing any live state.
public struct RE4StageJ811CPUStateCandidate: Equatable {
    public let registers: [UInt32]
    public let flags: RE4StageJ810ConditionFlags
    public let executionMode: RE4StageJ811ExecutionMode
    public let cpsrRestoreRequest: RE4StageJ811CPSRRestoreRequest
    public let vfpRestoreRequirement: RE4StageJ811VFPRestoreRequirement

    public init(
        registers: [UInt32],
        flags: RE4StageJ810ConditionFlags,
        executionMode: RE4StageJ811ExecutionMode,
        cpsrRestoreRequest: RE4StageJ811CPSRRestoreRequest = .modeledNZCVOnly,
        vfpRestoreRequirement: RE4StageJ811VFPRestoreRequirement = .notRequired
    ) {
        self.registers = registers
        self.flags = flags
        self.executionMode = executionMode
        self.cpsrRestoreRequest = cpsrRestoreRequest
        self.vfpRestoreRequirement = vfpRestoreRequirement
    }

    /// Converts the J.8.10 immutable forced-Resume projection into a commit
    /// candidate. #101's target epilogue needs D8-D15 restored by VPOP, so that
    /// requirement is carried forward and then fails closed at the Core gate.
    public static func from(
        preparedContext: RE4StageJ810PreparedContext
    ) -> RE4StageJ811CPUStateCandidate {
        RE4StageJ811CPUStateCandidate(
            registers: preparedContext.stateAfterPlannedTransfer.registers,
            flags: preparedContext.stateAfterPlannedTransfer.flags,
            executionMode: preparedContext.targetState == .arm
                ? .arm32Interpreter : .thumb16Required,
            cpsrRestoreRequest: .modeledNZCVOnly,
            vfpRestoreRequirement:
                preparedContext.targetFunctionEpilogueMustRestoreVFPRegisters.isEmpty
                    ? .notRequired : .d8ThroughD15Required
        )
    }

    func validate(
        against source: RE4StageJ811CPUStateSnapshot
    ) throws -> RE4StageJ811ValidatedCPUStateCommit {
        guard registers.count == 16 else {
            throw RE4StageJ811CommitError.invalidRegisterFileCount(registers.count)
        }
        guard executionMode == .arm32Interpreter else {
            throw RE4StageJ811CommitError.thumbExecutionUnsupported
        }
        guard (registers[15] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.programCounterNotWordAligned(registers[15])
        }
        guard (registers[13] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.stackPointerNotWordAligned(registers[13])
        }
        guard cpsrRestoreRequest == .modeledNZCVOnly else {
            throw RE4StageJ811CommitError.fullCPSRRestoreUnsupported
        }
        guard vfpRestoreRequirement == .notRequired else {
            throw RE4StageJ811CommitError.vfpD8ThroughD15RestoreUnsupported
        }
        return RE4StageJ811ValidatedCPUStateCommit(
            expectedSource: source,
            registers: registers,
            flags: flags
        )
    }
}

/// Opaque result of Phase 1. Obtain one only from the Core's preflight method.
public struct RE4StageJ811ValidatedCPUStateCommit {
    let expectedSource: RE4StageJ811CPUStateSnapshot
    let registers: [UInt32]
    let flags: RE4StageJ810ConditionFlags

    init(
        expectedSource: RE4StageJ811CPUStateSnapshot,
        registers: [UInt32],
        flags: RE4StageJ810ConditionFlags
    ) {
        self.expectedSource = expectedSource
        self.registers = registers
        self.flags = flags
    }
}

public struct RE4StageJ811CommitReceipt: Equatable {
    public let committedGeneralRegisterCount: Int
    public let committedNZCV: Bool
    public let restoredFullCPSR: Bool
    public let restoredVFPD8ThroughD15: Bool
    public let guestInstructionsExecuted: Bool
}
