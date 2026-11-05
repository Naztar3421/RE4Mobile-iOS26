import Foundation

// Stage J.8.11 bridge: preserve the J.8.10 provider projection and its
// outstanding execution obligations when creating a Core commit candidate.
public extension RE4StageJ811CPUStateCandidate {
    static func from(
        preparedContext: RE4StageJ810PreparedContext
    ) -> RE4StageJ811CPUStateCandidate {
        RE4StageJ811CPUStateCandidate(
            registers: preparedContext.stateAfterPlannedTransfer.registers,
            flags: RE4StageJ811ConditionFlags(
                negative: preparedContext.stateAfterPlannedTransfer.flags.negative,
                zero: preparedContext.stateAfterPlannedTransfer.flags.zero,
                carry: preparedContext.stateAfterPlannedTransfer.flags.carry,
                overflow: preparedContext.stateAfterPlannedTransfer.flags.overflow
            ),
            executionMode: preparedContext.targetState == .arm
                ? .arm32Interpreter : .thumb16Required,
            cpsrRestoreRequest: .modeledNZCVOnly,
            vfpRestoreRequirement:
                preparedContext.targetFunctionEpilogueMustRestoreVFPRegisters.isEmpty
                    ? .notRequired : .d8ThroughD15RequiredByGuestEpilogue
        )
    }
}
