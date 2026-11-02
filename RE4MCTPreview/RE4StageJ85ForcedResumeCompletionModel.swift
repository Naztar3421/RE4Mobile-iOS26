import Foundation

// Stage J.8.5: host-only forced-unwind Resume completion model.
// The raw stop-function token is metadata only. J.6 receives an explicit host
// closure; no target function pointer, Resume routine, or Guest state is invoked.

public enum RE4StageJ85Error: Error, CustomStringConvertible {
    case handoffMismatch(String)
    case invalidForcedRoute(UInt32)
    case missingSyntheticStopCallback(UInt32)
    case cleanupFrameNotTSDTop(expected: UInt32, actual: UInt32)
    case missingCleanupFrame(UInt32)
    case wrongCleanupPersonality(UInt32)
    case selectorMismatch(expected: UInt32, actual: UInt32)
    case sentinelMismatch(UInt32)
    case getIPMismatch(UInt32)
    case firstVisitMismatch(UInt32?)
    case intermediateVisitMismatch(UInt32, String)
    case nextCleanupMismatch(UInt32)
    case unexpectedResumeResult(String)

    public var description: String {
        switch self {
        case .handoffMismatch(let field): return "J.8.5 forced handoff mismatch: \(field)"
        case .invalidForcedRoute(let value):
            return String(format: "Forced Resume requires private_1 != 0; got 0x%08X.", value)
        case .missingSyntheticStopCallback(let token):
            return String(format: "No synthetic host stop callback supplied for token 0x%08X.", token)
        case .cleanupFrameNotTSDTop(let expected, let actual):
            return String(format: "Cleanup frame 0x%08X is not synthetic TSD top 0x%08X.", expected, actual)
        case .missingCleanupFrame(let address):
            return String(format: "Missing synthetic #101 cleanup frame 0x%08X.", address)
        case .wrongCleanupPersonality(let address):
            return String(format: "Frame 0x%08X is not the #101 cleanup frame.", address)
        case .selectorMismatch(let expected, let actual):
            return String(format: "Expected cleanup selector 0x%08X, got 0x%08X.", expected, actual)
        case .sentinelMismatch(let value):
            return String(format: "Expected 0xFFFFFFFF cleanup sentinel, got 0x%08X.", value)
        case .getIPMismatch(let value):
            return String(format: "Expected forced Resume GetIP zero, got 0x%08X.", value)
        case .firstVisitMismatch(let address):
            return "Forced Resume did not revisit the completed frame first (\(address.map { String(format: "0x%08X", $0) } ?? "no visit"))."
        case .intermediateVisitMismatch(let address, let reason):
            return String(format: "Forced Resume visit at 0x%08X violated continue contract: %@.", address, reason)
        case .nextCleanupMismatch(let address):
            return String(format: "Next forced cleanup frame 0x%08X did not produce a valid INSTALL_CONTEXT plan.", address)
        case .unexpectedResumeResult(let value):
            return "Unexpected forced Resume result: \(value)"
        }
    }
}

public enum RE4StageJ85ForcedResumeDisposition: Equatable {
    case nextCleanupInstalled(frameAddress: UInt32, row: Int, landingPadIndex: UInt32)
    case stopCallbackRejected(frameAddress: UInt32, returnCode: Int32)
    case endOfStack
    case unresolvedCallSite(frameAddress: UInt32, callSiteIP: UInt32?)
    case corruptFrameChain(missingFrame: UInt32)
}

public struct RE4StageJ85ForcedResumeSnapshot: Equatable {
    public let completedCleanupFrameAddress: UInt32
    public let stopFunctionRaw: UInt32
    public let stopParameter: UInt32
    public let selectorBeforeCleanup: UInt32
    public let selectorAfterCleanup: UInt32
    public let getIPAfterCleanup: UInt32
    public let tsdTopBeforeCleanup: UInt32
    public let tsdTopAfterSentinelWrite: UInt32
    public let resumeVisits: [RE4StageJ6Phase2Visit]
    public let callbackVisitAddresses: [UInt32]
    public let callbackReturnCodes: [Int32]
    public let disposition: RE4StageJ85ForcedResumeDisposition
    public let nextCleanupInstallPlan: RE4StageJ6ContextInstallPlan?
    public let modelTSDTopAfterResume: UInt32
    public let completedFrameRemainsRegistered: Bool
    public let completedFrameRetainsSentinel: Bool
    public let targetStopFunctionInvoked: Bool
    public let targetResumeFunctionInvoked: Bool
    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let cpuContextApplied: Bool
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ85ForcedResumeCompletionModel {
    /// Models the forced branch of __Unwind_SjLj_Resume after #101 cleanup.
    /// The synthetic host closure is the only callback that may be invoked.
    public static func completeCleanupAndResume(
        machine: RE4StageJ6SJLJStateMachine,
        threadID: UInt64,
        handoff: RE4StageJ83HandoffInput,
        exception: RE4StageJ6SJLJException,
        syntheticStop: ((RE4StageJ6ForcedStopEvent) -> Int32)?
    ) throws -> RE4StageJ85ForcedResumeSnapshot {
        let rawStopFunction = exception.private1
        let stopParameter = exception.private2
        guard rawStopFunction != 0 else {
            throw RE4StageJ85Error.invalidForcedRoute(rawStopFunction)
        }
        guard let stop = syntheticStop else {
            throw RE4StageJ85Error.missingSyntheticStopCallback(rawStopFunction)
        }

        let phase2Plan = handoff.phase2Plan
        let j7Plan = handoff.j7Plan
        let cleanupAddress = j7Plan.frameAddress
        guard !handoff.controlTransferPerformed,
              !phase2Plan.controlTransferPerformed,
              !j7Plan.controlTransferPerformed else {
            throw RE4StageJ85Error.handoffMismatch("control transfer must remain false")
        }
        guard phase2Plan.action == .forcedCleanup,
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
              (2...20).contains(j7Plan.row),
              j7Plan.dispatchIndex == UInt32(j7Plan.row),
              j7Plan.selector == UInt32(j7Plan.row - 1),
              j7Plan.savedContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              j7Plan.cleanupContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
              j7Plan.setIPArgument == j7Plan.dispatchIndex,
              j7Plan.setIPStoredSelector == j7Plan.dispatchIndex - 1,
              j7Plan.personalityReturnCode == RE4StageJ7LandingPadContextModel.personalityInstallContextCode,
              j7Plan.frameRetainedAtTSDTop,
              j7Plan.resumeSelectorSentinel == UInt32.max,
              j7Plan.resumeGetIPAfterCleanup == 0,
              j7Plan.resumeContinuesPastCurrentFrame else {
            throw RE4StageJ85Error.handoffMismatch("J.6/J.7 forced cleanup contract")
        }
        guard handoff.finalTSDTopAddress == cleanupAddress else {
            throw RE4StageJ85Error.handoffMismatch("J.8.2 final TSD top is not the selected forced cleanup frame")
        }
        let topBefore = machine.top(threadID: threadID)
        guard topBefore == cleanupAddress else {
            throw RE4StageJ85Error.cleanupFrameNotTSDTop(expected: cleanupAddress, actual: topBefore)
        }
        guard let beforeFrame = machine.frame(threadID: threadID, address: cleanupAddress) else {
            throw RE4StageJ85Error.missingCleanupFrame(cleanupAddress)
        }
        guard beforeFrame.personality == .extraProductListCleanupOnly else {
            throw RE4StageJ85Error.wrongCleanupPersonality(cleanupAddress)
        }
        guard beforeFrame.selectorRaw == j7Plan.setIPStoredSelector,
              beforeFrame.callSiteIP == j7Plan.dispatchIndex else {
            throw RE4StageJ85Error.selectorMismatch(expected: j7Plan.setIPStoredSelector,
                                                     actual: beforeFrame.selectorRaw)
        }

        // Host metadata analogue of the audited frame+4 = 0xFFFFFFFF cleanup store.
        let sentinel = try machine.markCleanupContinuationComplete(threadID: threadID,
                                                                    address: cleanupAddress)
        guard sentinel == UInt32.max else { throw RE4StageJ85Error.sentinelMismatch(sentinel) }
        guard RE4StageJ6StaticContextHelpers.getIP(selectorRaw: sentinel) == 0,
              machine.frame(threadID: threadID, address: cleanupAddress)?.callSiteIP == 0 else {
            throw RE4StageJ85Error.getIPMismatch(
                RE4StageJ6StaticContextHelpers.getIP(selectorRaw: sentinel) ?? UInt32.max)
        }
        let topAfterSentinel = machine.top(threadID: threadID)
        guard topAfterSentinel == cleanupAddress else {
            throw RE4StageJ85Error.cleanupFrameNotTSDTop(expected: cleanupAddress,
                                                          actual: topAfterSentinel)
        }

        // Calls only the J.6 host state machine. Neither raw target pointer is invoked.
        let resumed = machine.resume(threadID: threadID, exception: exception,
                                     syntheticStop: stop)
        let visits: [RE4StageJ6Phase2Visit]
        let disposition: RE4StageJ85ForcedResumeDisposition
        let installPlan: RE4StageJ6ContextInstallPlan?

        switch resumed {
        case .installContextPending(let plan, let phaseVisits):
            visits = phaseVisits
            installPlan = plan
            guard let first = visits.first,
                  first.frameAddress == cleanupAddress,
                  first.actions == .forcedCleanup,
                  first.decision == .continueUnwind,
                  first.stopCallbackReturn == 0 else {
                throw RE4StageJ85Error.firstVisitMismatch(visits.first?.frameAddress)
            }
            for visit in visits.dropFirst().dropLast() {
                guard visit.actions == .forcedCleanup,
                      visit.decision == .continueUnwind,
                      visit.stopCallbackReturn == 0 else {
                    throw RE4StageJ85Error.intermediateVisitMismatch(
                        visit.frameAddress, String(describing: visit.decision))
                }
            }
            guard let last = visits.last,
                  last.frameAddress == plan.frameAddress,
                  last.frameAddress != cleanupAddress,
                  last.actions == .forcedCleanup,
                  last.decision == .installCleanupContext(row: plan.lsdaRow ?? -1,
                                                          landingPadIndex: plan.landingPadIndex ?? UInt32.max),
                  last.stopCallbackReturn == 0,
                  plan.action == .forcedCleanup,
                  let row = plan.lsdaRow, (2...20).contains(row),
                  let index = plan.landingPadIndex, index == UInt32(row - 1),
                  plan.landingPadPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC,
                  plan.frameRetainedAtTSDTop,
                  !plan.controlTransferPerformed else {
                throw RE4StageJ85Error.nextCleanupMismatch(plan.frameAddress)
            }
            guard let nextFrame = machine.frame(threadID: threadID, address: plan.frameAddress),
                  nextFrame.personality == .extraProductListCleanupOnly,
                  nextFrame.selectorRaw == index,
                  nextFrame.callSiteIP == UInt32(row),
                  nextFrame.savedR7 == plan.savedR7,
                  nextFrame.savedSP == plan.savedSP,
                  nextFrame.continuationPC == plan.savedContinuationPC,
                  machine.top(threadID: threadID) == plan.frameAddress else {
                throw RE4StageJ85Error.nextCleanupMismatch(plan.frameAddress)
            }
            disposition = .nextCleanupInstalled(frameAddress: plan.frameAddress,
                                                row: row, landingPadIndex: index)

        case .endOfStack(let phaseVisits):
            visits = phaseVisits
            installPlan = nil
            guard let first = visits.first,
                  first.frameAddress == cleanupAddress,
                  first.actions == .forcedCleanup,
                  first.decision == .continueUnwind,
                  first.stopCallbackReturn == 0 else {
                throw RE4StageJ85Error.firstVisitMismatch(visits.first?.frameAddress)
            }
            for visit in visits.dropFirst() {
                guard visit.actions == .forcedCleanup,
                      visit.decision == .continueUnwind,
                      visit.stopCallbackReturn == 0 else {
                    throw RE4StageJ85Error.intermediateVisitMismatch(
                        visit.frameAddress, String(describing: visit.decision))
                }
            }
            disposition = .endOfStack

        case .fatalPhase2Error(let frameAddress, let phaseVisits):
            visits = phaseVisits
            installPlan = nil
            guard let frameAddress,
                  let failed = visits.last,
                  failed.frameAddress == frameAddress,
                  failed.actions == .forcedCleanup,
                  failed.decision == .fatalPhase2Error,
                  let stopCode = failed.stopCallbackReturn,
                  stopCode != 0 else {
                throw RE4StageJ85Error.unexpectedResumeResult(String(describing: resumed))
            }
            for visit in visits.dropLast() {
                guard visit.actions == .forcedCleanup,
                      visit.decision == .continueUnwind,
                      visit.stopCallbackReturn == 0 else {
                    throw RE4StageJ85Error.intermediateVisitMismatch(
                        visit.frameAddress, String(describing: visit.decision))
                }
            }
            disposition = .stopCallbackRejected(frameAddress: frameAddress,
                                                returnCode: stopCode)

        case .unresolvedCallSiteIndex(let frameAddress, let callSiteIP, let phaseVisits):
            visits = phaseVisits
            installPlan = nil
            guard let first = visits.first,
                  first.frameAddress == cleanupAddress,
                  first.actions == .forcedCleanup,
                  first.decision == .continueUnwind,
                  first.stopCallbackReturn == 0,
                  let last = visits.last,
                  last.frameAddress == frameAddress,
                  last.actions == .forcedCleanup,
                  last.decision == .unresolvedCallSiteIndex(callSiteIP),
                  last.stopCallbackReturn == 0 else {
                throw RE4StageJ85Error.unexpectedResumeResult(String(describing: resumed))
            }
            for visit in visits.dropFirst().dropLast() {
                guard visit.actions == .forcedCleanup,
                      visit.decision == .continueUnwind,
                      visit.stopCallbackReturn == 0 else {
                    throw RE4StageJ85Error.intermediateVisitMismatch(
                        visit.frameAddress, String(describing: visit.decision))
                }
            }
            disposition = .unresolvedCallSite(frameAddress: frameAddress,
                                               callSiteIP: callSiteIP)

        case .corruptFrameChain(let missing, let phaseVisits):
            visits = phaseVisits
            installPlan = nil
            guard let first = phaseVisits.first,
                  first.frameAddress == cleanupAddress,
                  phaseVisits.allSatisfy({ $0.actions == .forcedCleanup &&
                                          $0.decision == .continueUnwind &&
                                          $0.stopCallbackReturn == 0 }) else {
                throw RE4StageJ85Error.unexpectedResumeResult(String(describing: resumed))
            }
            disposition = .corruptFrameChain(missingFrame: missing)

        case .missingSyntheticStopCallback(let raw, _):
            throw RE4StageJ85Error.missingSyntheticStopCallback(raw)
        }

        let completed = machine.frame(threadID: threadID, address: cleanupAddress)
        return RE4StageJ85ForcedResumeSnapshot(
            completedCleanupFrameAddress: cleanupAddress,
            stopFunctionRaw: rawStopFunction,
            stopParameter: stopParameter,
            selectorBeforeCleanup: beforeFrame.selectorRaw,
            selectorAfterCleanup: sentinel,
            getIPAfterCleanup: 0,
            tsdTopBeforeCleanup: topBefore,
            tsdTopAfterSentinelWrite: topAfterSentinel,
            resumeVisits: visits,
            callbackVisitAddresses: visits.map(\.frameAddress),
            callbackReturnCodes: visits.compactMap(\.stopCallbackReturn),
            disposition: disposition,
            nextCleanupInstallPlan: installPlan,
            modelTSDTopAfterResume: machine.top(threadID: threadID),
            completedFrameRemainsRegistered: completed != nil,
            completedFrameRetainsSentinel: completed?.selectorRaw == UInt32.max,
            targetStopFunctionInvoked: false,
            targetResumeFunctionInvoked: false,
            guestInstructionsExecuted: false,
            guestMemoryWrites: 0,
            cpuContextApplied: false,
            controlTransferPerformed: false)
    }
}
