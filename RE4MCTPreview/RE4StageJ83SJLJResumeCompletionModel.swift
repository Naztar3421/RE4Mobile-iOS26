import Foundation

// Stage J.8.3: host-only SJLJ cleanup-completion and Resume state audit.
// This model observes J.6 synthetic frame state and the J.8.2 handoff values.
// It never calls a target Resume/unregister function pointer or applies a CPU context.

public enum RE4StageJ83Error: Error, CustomStringConvertible {
    case handoffMismatch(String)
    case cleanupFrameNotTSDTop(expected: UInt32, actual: UInt32)
    case missingCleanupFrame(UInt32)
    case wrongCleanupPersonality(UInt32)
    case selectorMismatch(expected: UInt32, actual: UInt32)
    case invalidResumeRoute(private1: UInt32)
    case predecessorMismatch(expected: UInt32, actual: UInt32)
    case resumeDidNotSkipCleanupFrame
    case resumeDidNotReachHandler(UInt32)
    case unexpectedResumeResult(String)
    case sentinelMismatch(UInt32)
    case getIPMismatch(UInt32)
    case normalUnregisterDidNotAdvance(expected: UInt32, actual: UInt32)
    case normalPathChangedSelector(before: UInt32, after: UInt32)
    case normalPathWasMarkedExceptional

    public var description: String {
        switch self {
        case .handoffMismatch(let field): return "J.8.2 handoff mismatch: \(field)"
        case .cleanupFrameNotTSDTop(let expected, let actual):
            return String(format: "Cleanup frame 0x%08X is not the TSD top (0x%08X).", expected, actual)
        case .missingCleanupFrame(let address): return String(format: "Missing synthetic cleanup frame 0x%08X.", address)
        case .wrongCleanupPersonality(let address): return String(format: "Frame 0x%08X is not the audited ExtraProductList cleanup frame.", address)
        case .selectorMismatch(let expected, let actual): return String(format: "Expected selector 0x%08X, got 0x%08X.", expected, actual)
        case .invalidResumeRoute(let private1): return String(format: "Expected normal Resume route (private_1=0), got 0x%08X.", private1)
        case .predecessorMismatch(let expected, let actual): return String(format: "Expected handler predecessor 0x%08X, got 0x%08X.", expected, actual)
        case .resumeDidNotSkipCleanupFrame: return "Resume phase 2 did not continue past the sentinel-marked cleanup frame."
        case .resumeDidNotReachHandler(let address): return String(format: "Resume did not reach enclosing synthetic handler 0x%08X.", address)
        case .unexpectedResumeResult(let result): return "Unexpected Resume result: \(result)"
        case .sentinelMismatch(let value): return String(format: "Expected cleanup selector sentinel 0xFFFFFFFF, got 0x%08X.", value)
        case .getIPMismatch(let value): return String(format: "Expected wrapped GetIP=0, got 0x%08X.", value)
        case .normalUnregisterDidNotAdvance(let expected, let actual): return String(format: "Normal Unregister expected TSD top 0x%08X, got 0x%08X.", expected, actual)
        case .normalPathChangedSelector(let before, let after): return String(format: "Normal Unregister changed selector 0x%08X -> 0x%08X.", before, after)
        case .normalPathWasMarkedExceptional: return "Normal completion must not write the exceptional Resume sentinel."
        }
    }
}

/// Value projection of the J.8.2 handoff. The caller copies the J.8.2 fields
/// unchanged; J.8.3 checks their consistency against the live synthetic J.6 model.
public struct RE4StageJ83HandoffInput: Equatable {
    public let phase2Plan: RE4StageJ6ContextInstallPlan
    public let j7Plan: RE4StageJ7CleanupContextPlan
    public let finalTSDTopAddress: UInt32
    public let controlTransferPerformed: Bool

    public init(phase2Plan: RE4StageJ6ContextInstallPlan,
                j7Plan: RE4StageJ7CleanupContextPlan,
                finalTSDTopAddress: UInt32,
                controlTransferPerformed: Bool = false) {
        self.phase2Plan = phase2Plan
        self.j7Plan = j7Plan
        self.finalTSDTopAddress = finalTSDTopAddress
        self.controlTransferPerformed = controlTransferPerformed
    }
}

public struct RE4StageJ83ExceptionalResumeSnapshot: Equatable {
    public let cleanupFrameAddress: UInt32
    public let enclosingHandlerFrameAddress: UInt32
    public let selectorBeforeCleanup: UInt32
    public let selectorAfterCleanup: UInt32
    public let callSiteIPAfterCleanup: UInt32
    public let tsdTopBeforeCleanup: UInt32
    public let tsdTopAfterSentinelWrite: UInt32
    public let resumeVisitAddresses: [UInt32]
    public let cleanupFrameResumeDecision: RE4StageJ6PersonalityDecision
    public let handlerFrameResumeDecision: RE4StageJ6PersonalityDecision
    public let resumedInstallFrameAddress: UInt32
    public let finalTSDTopAddress: UInt32
    /// The Swift host registry still retains the record; it is no longer the TSD top.
    public let cleanupFrameRemainsRegistered: Bool
    public let cleanupFrameStillHasSentinel: Bool
    public let resumeWasInvokedAsMetadataModel: Bool
    public let controlTransferPerformed: Bool
    public let guestMemoryWrites: Int
}

public struct RE4StageJ83NormalUnregisterSnapshot: Equatable {
    public let frameAddress: UInt32
    public let previousFrameAddress: UInt32
    public let selectorBeforeUnregister: UInt32
    public let selectorAfterUnregister: UInt32
    public let callSiteIPAfterUnregister: UInt32
    public let tsdTopBeforeUnregister: UInt32
    public let tsdTopAfterUnregister: UInt32
    public let unregisterRouteTaken: Bool
    public let exceptionalResumeInvoked: Bool
    public let sentinelWritten: Bool
    public let controlTransferPerformed: Bool
    public let guestMemoryWrites: Int
}

public enum RE4StageJ83SJLJResumeCompletionModel {
    public static let cleanupSentinel: UInt32 = UInt32.max

    /// Models exceptional completion after the #101 cleanup trampoline.
    /// The selected frame must still be TSD top when Resume re-enters phase 2.
    public static func completeCleanupAndResume(machine: RE4StageJ6SJLJStateMachine,
                                                 threadID: UInt64,
                                                 handoff: RE4StageJ83HandoffInput,
                                                 exception: RE4StageJ6SJLJException) throws -> RE4StageJ83ExceptionalResumeSnapshot {
        let phase2Plan = handoff.phase2Plan
        let j7Plan = handoff.j7Plan
        let cleanupAddress = j7Plan.frameAddress

        guard !handoff.controlTransferPerformed,
              !phase2Plan.controlTransferPerformed,
              !j7Plan.controlTransferPerformed else {
            throw RE4StageJ83Error.handoffMismatch("controlTransferPerformed must remain false")
        }
        guard phase2Plan.action == .ordinaryCleanup,
              phase2Plan.frameAddress == cleanupAddress,
              phase2Plan.lsdaRow == j7Plan.row,
              phase2Plan.landingPadIndex == j7Plan.selector,
              phase2Plan.savedR7 == j7Plan.savedR7,
              phase2Plan.savedSP == j7Plan.savedSP,
              phase2Plan.savedContinuationPC == j7Plan.savedContinuationPC,
              phase2Plan.frameRetainedAtTSDTop else {
            throw RE4StageJ83Error.handoffMismatch("J.6/J.7 cleanup plan fields or retained-frame contract")
        }
        guard handoff.finalTSDTopAddress == cleanupAddress else {
            throw RE4StageJ83Error.handoffMismatch("J.8.2 final TSD top differs from selected cleanup frame")
        }
        let topBefore = machine.top(threadID: threadID)
        guard topBefore == cleanupAddress else {
            throw RE4StageJ83Error.cleanupFrameNotTSDTop(expected: cleanupAddress, actual: topBefore)
        }
        guard let beforeFrame = machine.frame(threadID: threadID, address: cleanupAddress) else {
            throw RE4StageJ83Error.missingCleanupFrame(cleanupAddress)
        }
        guard beforeFrame.personality == .extraProductListCleanupOnly else {
            throw RE4StageJ83Error.wrongCleanupPersonality(cleanupAddress)
        }
        guard beforeFrame.selectorRaw == j7Plan.setIPStoredSelector,
              beforeFrame.callSiteIP == j7Plan.dispatchIndex else {
            throw RE4StageJ83Error.selectorMismatch(expected: j7Plan.setIPStoredSelector,
                                                     actual: beforeFrame.selectorRaw)
        }
        guard exception.private1 == 0 else {
            throw RE4StageJ83Error.invalidResumeRoute(private1: exception.private1)
        }
        guard exception.private2 != 0,
              exception.private2 == beforeFrame.previousFrame else {
            throw RE4StageJ83Error.predecessorMismatch(expected: beforeFrame.previousFrame,
                                                       actual: exception.private2)
        }

        // The cleanup trampoline writes 0xFFFFFFFF to frame+4 before calling Resume.
        let sentinel = try machine.markCleanupContinuationComplete(threadID: threadID,
                                                                     address: cleanupAddress)
        guard sentinel == cleanupSentinel else { throw RE4StageJ83Error.sentinelMismatch(sentinel) }
        let afterFrame = machine.frame(threadID: threadID, address: cleanupAddress)
        guard afterFrame?.selectorRaw == cleanupSentinel else {
            throw RE4StageJ83Error.sentinelMismatch(afterFrame?.selectorRaw ?? 0)
        }
        let getIP = RE4StageJ6StaticContextHelpers.getIP(selectorRaw: sentinel) ?? UInt32.max
        guard getIP == 0, afterFrame?.callSiteIP == 0 else {
            throw RE4StageJ83Error.getIPMismatch(getIP)
        }
        let topAfterSentinel = machine.top(threadID: threadID)
        guard topAfterSentinel == cleanupAddress else {
            throw RE4StageJ83Error.cleanupFrameNotTSDTop(expected: cleanupAddress,
                                                         actual: topAfterSentinel)
        }

        // This invokes only the J.6 host state machine; no target Resume code executes.
        let resumed = machine.resume(threadID: threadID, exception: exception)
        guard case .installContextPending(let resumedPlan, let visits) = resumed else {
            throw RE4StageJ83Error.unexpectedResumeResult(String(describing: resumed))
        }
        guard let first = visits.first,
              first.frameAddress == cleanupAddress,
              first.decision == .continueUnwind else {
            throw RE4StageJ83Error.resumeDidNotSkipCleanupFrame
        }
        guard visits.contains(where: { $0.frameAddress == beforeFrame.previousFrame }) else {
            throw RE4StageJ83Error.resumeDidNotReachHandler(beforeFrame.previousFrame)
        }
        guard visits.last?.frameAddress == exception.private2,
              visits.last?.decision == .installCleanupContext(row: 0, landingPadIndex: 0),
              resumedPlan.frameAddress == exception.private2 else {
            throw RE4StageJ83Error.resumeDidNotReachHandler(exception.private2)
        }
        let finalTop = machine.top(threadID: threadID)
        guard finalTop == exception.private2 else {
            throw RE4StageJ83Error.resumeDidNotReachHandler(exception.private2)
        }
        let finalCleanupFrame = machine.frame(threadID: threadID, address: cleanupAddress)
        return RE4StageJ83ExceptionalResumeSnapshot(
            cleanupFrameAddress: cleanupAddress,
            enclosingHandlerFrameAddress: exception.private2,
            selectorBeforeCleanup: beforeFrame.selectorRaw,
            selectorAfterCleanup: sentinel,
            callSiteIPAfterCleanup: getIP,
            tsdTopBeforeCleanup: topBefore,
            tsdTopAfterSentinelWrite: topAfterSentinel,
            resumeVisitAddresses: visits.map(\.frameAddress),
            cleanupFrameResumeDecision: first.decision,
            handlerFrameResumeDecision: visits.last?.decision ?? .continueUnwind,
            resumedInstallFrameAddress: resumedPlan.frameAddress,
            finalTSDTopAddress: finalTop,
            cleanupFrameRemainsRegistered: finalCleanupFrame != nil,
            cleanupFrameStillHasSentinel: finalCleanupFrame?.selectorRaw == cleanupSentinel,
            resumeWasInvokedAsMetadataModel: true,
            controlTransferPerformed: false,
            guestMemoryWrites: 0)
    }

    /// Models the normal non-exceptional path at the explicit Unregister site.
    /// It does not write the Resume sentinel and does not invoke Resume.
    public static func finishNormallyWithUnregister(machine: RE4StageJ6SJLJStateMachine,
                                                     threadID: UInt64,
                                                     frameAddress: UInt32,
                                                     expectedDispatchIndex: UInt32) throws -> RE4StageJ83NormalUnregisterSnapshot {
        let topBefore = machine.top(threadID: threadID)
        guard topBefore == frameAddress else {
            throw RE4StageJ83Error.cleanupFrameNotTSDTop(expected: frameAddress, actual: topBefore)
        }
        guard let frameBefore = machine.frame(threadID: threadID, address: frameAddress) else {
            throw RE4StageJ83Error.missingCleanupFrame(frameAddress)
        }
        guard frameBefore.personality == .extraProductListCleanupOnly else {
            throw RE4StageJ83Error.wrongCleanupPersonality(frameAddress)
        }
        guard frameBefore.callSiteIP == expectedDispatchIndex, frameBefore.selectorRaw != cleanupSentinel else {
            throw RE4StageJ83Error.selectorMismatch(expected: expectedDispatchIndex &- 1,
                                                     actual: frameBefore.selectorRaw)
        }
        let selectorBefore = frameBefore.selectorRaw
        let previous = frameBefore.previousFrame
        let returnedPrevious = try machine.unregister(threadID: threadID, address: frameAddress)
        guard returnedPrevious == previous else {
            throw RE4StageJ83Error.normalUnregisterDidNotAdvance(expected: previous,
                                                                  actual: returnedPrevious)
        }
        let topAfter = machine.top(threadID: threadID)
        guard topAfter == previous else {
            throw RE4StageJ83Error.normalUnregisterDidNotAdvance(expected: previous,
                                                                  actual: topAfter)
        }
        guard let frameAfter = machine.frame(threadID: threadID, address: frameAddress) else {
            throw RE4StageJ83Error.missingCleanupFrame(frameAddress)
        }
        guard frameAfter.selectorRaw == selectorBefore else {
            throw RE4StageJ83Error.normalPathChangedSelector(before: selectorBefore,
                                                              after: frameAfter.selectorRaw)
        }
        guard frameAfter.selectorRaw != cleanupSentinel else {
            throw RE4StageJ83Error.normalPathWasMarkedExceptional
        }
        return RE4StageJ83NormalUnregisterSnapshot(
            frameAddress: frameAddress,
            previousFrameAddress: previous,
            selectorBeforeUnregister: selectorBefore,
            selectorAfterUnregister: frameAfter.selectorRaw,
            callSiteIPAfterUnregister: frameAfter.callSiteIP ?? UInt32.max,
            tsdTopBeforeUnregister: topBefore,
            tsdTopAfterUnregister: topAfter,
            unregisterRouteTaken: true,
            exceptionalResumeInvoked: false,
            sentinelWritten: false,
            controlTransferPerformed: false,
            guestMemoryWrites: 0)
    }
}
