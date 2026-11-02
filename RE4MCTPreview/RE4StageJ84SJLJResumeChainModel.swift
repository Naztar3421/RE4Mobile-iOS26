import Foundation

// Stage J.8.4: host-only SJLJ Resume traversal across a multi-frame chain.
// It reuses the audited J.6 state machine and J.8.2/J.7 handoff values. No target
// Resume function, personality, unwinder, pthread TSD, Guest CPU, or Guest Memory
// is invoked or modified.

public enum RE4StageJ84Error: Error, CustomStringConvertible {
    case handoffMismatch(String)
    case cleanupFrameNotTSDTop(expected: UInt32, actual: UInt32)
    case missingCleanupFrame(UInt32)
    case wrongCleanupPersonality(UInt32)
    case selectorMismatch(expected: UInt32, actual: UInt32)
    case invalidResumeRoute(private1: UInt32)
    case zeroHandlerAddress
    case sentinelMismatch(UInt32)
    case getIPMismatch(UInt32)
    case cleanupNotFirstVisit(UInt32?)
    case handlerNotInChain(UInt32)
    case corruptFrameChain(UInt32)
    case handlerAddressIsNotHandler(UInt32)
    case intermediateDidNotContinue(frame: UInt32, decision: String)
    case handlerDidNotInstall(UInt32)
    case unexpectedResumeResult(String)

    public var description: String {
        switch self {
        case .handoffMismatch(let field): return "J.8.4 handoff mismatch: \(field)"
        case .cleanupFrameNotTSDTop(let expected, let actual):
            return String(format: "Cleanup frame 0x%08X is not TSD top (0x%08X).", expected, actual)
        case .missingCleanupFrame(let address):
            return String(format: "Cleanup frame 0x%08X is missing.", address)
        case .wrongCleanupPersonality(let address):
            return String(format: "Frame 0x%08X is not the audited #101 cleanup frame.", address)
        case .selectorMismatch(let expected, let actual):
            return String(format: "Expected cleanup selector 0x%08X, got 0x%08X.", expected, actual)
        case .invalidResumeRoute(let value):
            return String(format: "J.8.4 only models normal Resume (private_1 == 0); got 0x%08X.", value)
        case .zeroHandlerAddress: return "private_2 handler-frame address cannot be zero."
        case .sentinelMismatch(let value):
            return String(format: "Expected cleanup sentinel 0xFFFFFFFF, got 0x%08X.", value)
        case .getIPMismatch(let value):
            return String(format: "Expected GetIP zero after sentinel, got 0x%08X.", value)
        case .cleanupNotFirstVisit(let address):
            return "Resume did not revisit the completed cleanup frame first (\(address.map { String(format: "0x%08X", $0) } ?? "no visit"))."
        case .handlerNotInChain(let address):
            return String(format: "private_2 handler 0x%08X was not reached in the frame chain.", address)
        case .corruptFrameChain(let address):
            return String(format: "SJLJ frame chain references missing frame 0x%08X.", address)
        case .handlerAddressIsNotHandler(let address):
            return String(format: "private_2 points to 0x%08X, but that frame did not install a handler context.", address)
        case .intermediateDidNotContinue(let frame, let decision):
            return String(format: "Intermediate frame 0x%08X did not continue unwind: %@.", frame, decision)
        case .handlerDidNotInstall(let address):
            return String(format: "Handler frame 0x%08X did not produce INSTALL_CONTEXT.", address)
        case .unexpectedResumeResult(let value): return "Unexpected J.6 Resume result: \(value)"
        }
    }
}

public struct RE4StageJ84ResumeChainSnapshot: Equatable {
    public let cleanupFrameAddress: UInt32
    public let handlerFrameAddress: UInt32
    public let selectorBeforeCleanup: UInt32
    public let selectorAfterCleanup: UInt32
    public let getIPAfterCleanup: UInt32
    public let tsdTopBeforeCleanup: UInt32
    public let tsdTopAfterSentinelWrite: UInt32
    public let resumeVisitAddresses: [UInt32]
    public let intermediateFrameAddresses: [UInt32]
    public let intermediateDecisions: [RE4StageJ6PersonalityDecision]
    public let handlerAction: RE4StageJ6UnwindActions
    public let handlerDecision: RE4StageJ6PersonalityDecision
    public let installFrameAddress: UInt32
    public let installLSDArow: Int?
    public let installLandingPadIndex: UInt32?
    public let installSavedR7: UInt32
    public let installSavedSP: UInt32
    public let installSavedPC: UInt32
    public let finalTSDTopAddress: UInt32
    public let completedCleanupFrameRemainsRegistered: Bool
    public let completedCleanupFrameHasSentinel: Bool
    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let cpuContextApplied: Bool
    public let controlTransferPerformed: Bool
    public let targetResumeFunctionInvoked: Bool
}

public enum RE4StageJ84SJLJResumeChainModel {
    /// Completes the #101 cleanup and resumes phase 2 through any number of
    /// intervening SJLJ frames until private_2 identifies the enclosing handler.
    /// The J.6 Resume state machine is called as a host metadata/state model only.
    public static func completeCleanupAndResumeAcrossChain(
        machine: RE4StageJ6SJLJStateMachine,
        threadID: UInt64,
        handoff: RE4StageJ83HandoffInput,
        exception: RE4StageJ6SJLJException
    ) throws -> RE4StageJ84ResumeChainSnapshot {
        let phase2Plan = handoff.phase2Plan
        let j7Plan = handoff.j7Plan
        let cleanupAddress = j7Plan.frameAddress

        guard !handoff.controlTransferPerformed,
              !phase2Plan.controlTransferPerformed,
              !j7Plan.controlTransferPerformed else {
            throw RE4StageJ84Error.handoffMismatch("control transfer must remain false")
        }
        guard phase2Plan.action == .ordinaryCleanup,
              phase2Plan.frameAddress == cleanupAddress,
              phase2Plan.lsdaRow == j7Plan.row,
              phase2Plan.landingPadIndex == j7Plan.selector,
              phase2Plan.savedR7 == j7Plan.savedR7,
              phase2Plan.savedSP == j7Plan.savedSP,
              phase2Plan.savedContinuationPC == j7Plan.savedContinuationPC,
              phase2Plan.savedContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              phase2Plan.landingPadPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              phase2Plan.frameRetainedAtTSDTop,
              j7Plan.initializerVA == RE4StageJ7LandingPadContextModel.initializerVA,
              j7Plan.lsdaVA == RE4StageJ7LandingPadContextModel.lsdaVA,
              j7Plan.row >= 2 && j7Plan.row <= 20,
              j7Plan.dispatchIndex == UInt32(j7Plan.row),
              j7Plan.savedContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              j7Plan.cleanupContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              j7Plan.setGR0Offset == RE4StageJ7LandingPadContextModel.frameGR0Offset,
              j7Plan.setGR1Offset == RE4StageJ7LandingPadContextModel.frameGR1Offset,
              j7Plan.setGR1Value == 0,
              j7Plan.setIPArgument == j7Plan.dispatchIndex,
              j7Plan.setIPStoredSelector == j7Plan.dispatchIndex - 1,
              j7Plan.contextPCOverwriteSkipped,
              j7Plan.personalityReturnCode == RE4StageJ7LandingPadContextModel.personalityInstallContextCode,
              j7Plan.frameRetainedAtTSDTop,
              j7Plan.cleanupEntryReadsGR0,
              j7Plan.resumeExceptionArgument == j7Plan.setGR0Value,
              j7Plan.resumeSelectorSentinel == UInt32.max,
              j7Plan.resumeGetIPAfterCleanup == 0,
              j7Plan.resumeContinuesPastCurrentFrame else {
            throw RE4StageJ84Error.handoffMismatch("J.6/J.7 #101 cleanup contract")
        }
        guard handoff.finalTSDTopAddress == cleanupAddress else {
            throw RE4StageJ84Error.handoffMismatch("J.8.2 final TSD top does not identify #101 cleanup")
        }
        let topBefore = machine.top(threadID: threadID)
        guard topBefore == cleanupAddress else {
            throw RE4StageJ84Error.cleanupFrameNotTSDTop(expected: cleanupAddress, actual: topBefore)
        }
        guard let cleanupFrame = machine.frame(threadID: threadID, address: cleanupAddress) else {
            throw RE4StageJ84Error.missingCleanupFrame(cleanupAddress)
        }
        guard cleanupFrame.personality == .extraProductListCleanupOnly else {
            throw RE4StageJ84Error.wrongCleanupPersonality(cleanupAddress)
        }
        guard cleanupFrame.selectorRaw == j7Plan.setIPStoredSelector,
              cleanupFrame.callSiteIP == j7Plan.dispatchIndex else {
            throw RE4StageJ84Error.selectorMismatch(expected: j7Plan.setIPStoredSelector,
                                                     actual: cleanupFrame.selectorRaw)
        }
        guard exception.private1 == 0 else {
            throw RE4StageJ84Error.invalidResumeRoute(private1: exception.private1)
        }
        guard exception.private2 != 0 else { throw RE4StageJ84Error.zeroHandlerAddress }

        // Host metadata equivalent of the audited write at 0x560C.
        let sentinel = try machine.markCleanupContinuationComplete(threadID: threadID,
                                                                    address: cleanupAddress)
        guard sentinel == UInt32.max else { throw RE4StageJ84Error.sentinelMismatch(sentinel) }
        guard RE4StageJ6StaticContextHelpers.getIP(selectorRaw: sentinel) == 0,
              machine.frame(threadID: threadID, address: cleanupAddress)?.callSiteIP == 0 else {
            throw RE4StageJ84Error.getIPMismatch(
                RE4StageJ6StaticContextHelpers.getIP(selectorRaw: sentinel) ?? UInt32.max)
        }
        let topAfterSentinel = machine.top(threadID: threadID)
        guard topAfterSentinel == cleanupAddress else {
            throw RE4StageJ84Error.cleanupFrameNotTSDTop(expected: cleanupAddress,
                                                          actual: topAfterSentinel)
        }

        // This invokes only the J.6 host state machine. It never calls target Resume.
        let resumed = machine.resume(threadID: threadID, exception: exception)
        switch resumed {
        case .endOfStack:
            throw RE4StageJ84Error.handlerNotInChain(exception.private2)
        case .corruptFrameChain(let missing, _):
            throw RE4StageJ84Error.corruptFrameChain(missing)
        case .fatalPhase2Error(let frame, _):
            if frame == exception.private2 {
                throw RE4StageJ84Error.handlerAddressIsNotHandler(exception.private2)
            }
            throw RE4StageJ84Error.unexpectedResumeResult(String(describing: resumed))
        case .installContextPending(let plan, let visits):
            guard let first = visits.first, first.frameAddress == cleanupAddress else {
                throw RE4StageJ84Error.cleanupNotFirstVisit(visits.first?.frameAddress)
            }
            guard first.decision == .continueUnwind else {
                throw RE4StageJ84Error.cleanupNotFirstVisit(first.frameAddress)
            }
            guard let finalVisit = visits.last,
                  finalVisit.frameAddress == exception.private2 else {
                throw RE4StageJ84Error.handlerNotInChain(exception.private2)
            }
            let intermediateVisits = Array(visits.dropFirst().dropLast())
            for visit in intermediateVisits {
                guard visit.actions == .ordinaryCleanup,
                      visit.decision == .continueUnwind else {
                    throw RE4StageJ84Error.intermediateDidNotContinue(
                        frame: visit.frameAddress, decision: String(describing: visit.decision))
                }
            }
            guard finalVisit.actions == .handlerCleanup,
                  finalVisit.decision == .installCleanupContext(row: 0, landingPadIndex: 0),
                  plan.frameAddress == exception.private2,
                  plan.action == .handlerCleanup,
                  plan.lsdaRow == 0,
                  plan.landingPadIndex == 0,
                  plan.frameRetainedAtTSDTop,
                  !plan.controlTransferPerformed else {
                throw RE4StageJ84Error.handlerDidNotInstall(exception.private2)
            }
            guard let handler = machine.frame(threadID: threadID, address: exception.private2) else {
                throw RE4StageJ84Error.handlerNotInChain(exception.private2)
            }
            guard handler.personality == .syntheticOuterHandler,
                  plan.savedR7 == handler.savedR7,
                  plan.savedSP == handler.savedSP,
                  plan.savedContinuationPC == handler.continuationPC else {
                throw RE4StageJ84Error.handlerDidNotInstall(exception.private2)
            }
            let finalTop = machine.top(threadID: threadID)
            guard finalTop == exception.private2 else {
                throw RE4StageJ84Error.handlerDidNotInstall(exception.private2)
            }
            let completed = machine.frame(threadID: threadID, address: cleanupAddress)
            return RE4StageJ84ResumeChainSnapshot(
                cleanupFrameAddress: cleanupAddress,
                handlerFrameAddress: exception.private2,
                selectorBeforeCleanup: cleanupFrame.selectorRaw,
                selectorAfterCleanup: sentinel,
                getIPAfterCleanup: 0,
                tsdTopBeforeCleanup: topBefore,
                tsdTopAfterSentinelWrite: topAfterSentinel,
                resumeVisitAddresses: visits.map(\.frameAddress),
                intermediateFrameAddresses: intermediateVisits.map(\.frameAddress),
                intermediateDecisions: intermediateVisits.map(\.decision),
                handlerAction: finalVisit.actions,
                handlerDecision: finalVisit.decision,
                installFrameAddress: plan.frameAddress,
                installLSDArow: plan.lsdaRow,
                installLandingPadIndex: plan.landingPadIndex,
                installSavedR7: plan.savedR7,
                installSavedSP: plan.savedSP,
                installSavedPC: plan.savedContinuationPC,
                finalTSDTopAddress: finalTop,
                completedCleanupFrameRemainsRegistered: completed != nil,
                completedCleanupFrameHasSentinel: completed?.selectorRaw == UInt32.max,
                guestInstructionsExecuted: false,
                guestMemoryWrites: 0,
                cpuContextApplied: false,
                controlTransferPerformed: false,
                targetResumeFunctionInvoked: false)
        case .unresolvedCallSiteIndex, .missingSyntheticStopCallback:
            throw RE4StageJ84Error.unexpectedResumeResult(String(describing: resumed))
        }
    }
}
