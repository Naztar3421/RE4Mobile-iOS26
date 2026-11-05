import Foundation

// Stage J.8.6: host-only orchestration of repeated J.8.5 forced Resume cycles.
// It composes already-audited J.6/J.7/J.8.2/J.8.5 models. It does not execute
// any target callback, unwinder, pthread TSD operation, Guest instruction,
// Guest Memory write, CPU restore, or control transfer.

public enum RE4StageJ86Error: Error, CustomStringConvertible {
    case missingSyntheticStopCallback(UInt32)
    case invalidCleanupLimit(Int)
    case repeatedCleanupFrame(UInt32)
    case nextHandoffMismatch(UInt32)

    public var description: String {
        switch self {
        case .missingSyntheticStopCallback(let token):
            return String(format: "J.8.6 requires a host stop closure for raw token 0x%08X.", token)
        case .invalidCleanupLimit(let limit):
            return "J.8.6 cleanup-frame limit must be positive; got \(limit)."
        case .repeatedCleanupFrame(let address):
            return String(format: "J.8.6 detected a repeated cleanup frame 0x%08X.", address)
        case .nextHandoffMismatch(let address):
            return String(format: "J.8.6 could not rebuild a valid J.8.2 handoff for frame 0x%08X.", address)
        }
    }
}

public struct RE4StageJ86ForcedResumeCycle: Equatable {
    public let completedCleanupFrameAddress: UInt32
    public let snapshot: RE4StageJ85ForcedResumeSnapshot
    public let stopEvents: [RE4StageJ6ForcedStopEvent]
}

public enum RE4StageJ86ForcedResumeTerminal: Equatable {
    case endOfStack
    case stopCallbackRejected(frameAddress: UInt32, returnCode: Int32)
    case unresolvedCallSite(frameAddress: UInt32, callSiteIP: UInt32?)
    case corruptFrameChain(missingFrame: UInt32)
    case cleanupLimitReached(nextCleanupFrameAddress: UInt32)
}

public struct RE4StageJ86ForcedResumeChainSnapshot: Equatable {
    public let initialCleanupFrameAddress: UInt32
    public let cycles: [RE4StageJ86ForcedResumeCycle]
    public let allStopEvents: [RE4StageJ6ForcedStopEvent]
    public let terminal: RE4StageJ86ForcedResumeTerminal
    public let completedCleanupFrameAddresses: [UInt32]
    public let finalModelTSDTop: UInt32
    public let targetStopFunctionInvoked: Bool
    public let targetResumeFunctionInvoked: Bool
    public let guestInstructionsExecuted: Bool
    public let guestMemoryWrites: Int
    public let cpuContextApplied: Bool
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ86ForcedResumeChainModel {
    /// Continues from a caller-supplied first forced-cleanup handoff. After each
    /// J.8.5 cycle installs the next #101 cleanup frame, the same pinned J.8.2
    /// bridge creates a fresh J.7 handoff for the following cycle. The exception
    /// pointer is supplied explicitly and reused as the same synthetic exception
    /// object across the chain; it is never inferred from private_2.
    public static func completeChain(
        machine: RE4StageJ6SJLJStateMachine,
        threadID: UInt64,
        initialHandoff: RE4StageJ83HandoffInput,
        exception: RE4StageJ6SJLJException,
        exceptionPointer: UInt32,
        j7Model: RE4StageJ7LandingPadContextModel,
        syntheticStop: ((RE4StageJ6ForcedStopEvent) -> Int32)?,
        maxCleanupFrames: Int = 32
    ) throws -> RE4StageJ86ForcedResumeChainSnapshot {
        guard maxCleanupFrames > 0 else {
            throw RE4StageJ86Error.invalidCleanupLimit(maxCleanupFrames)
        }
        guard let stop = syntheticStop else {
            throw RE4StageJ86Error.missingSyntheticStopCallback(exception.private1)
        }
        let initialAddress = initialHandoff.j7Plan.frameAddress
        var handoff = initialHandoff
        var cycles: [RE4StageJ86ForcedResumeCycle] = []
        var allEvents: [RE4StageJ6ForcedStopEvent] = []
        var completed = Set<UInt32>()

        while true {
            let cleanupAddress = handoff.j7Plan.frameAddress
            guard !completed.contains(cleanupAddress) else {
                throw RE4StageJ86Error.repeatedCleanupFrame(cleanupAddress)
            }
            let start = allEvents.count
            let result = try RE4StageJ85ForcedResumeCompletionModel.completeCleanupAndResume(
                machine: machine,
                threadID: threadID,
                handoff: handoff,
                exception: exception,
                syntheticStop: { event in
                    allEvents.append(event)
                    return stop(event)
                })
            let stepEvents = Array(allEvents.dropFirst(start))
            guard stepEvents.map(\.frameAddress) == result.callbackVisitAddresses,
                  stepEvents.allSatisfy({
                      $0.stopFunctionRaw == exception.private1 &&
                      $0.stopParameter == exception.private2 && $0.reason == 10
                  }) else {
                throw RE4StageJ86Error.nextHandoffMismatch(cleanupAddress)
            }
            cycles.append(RE4StageJ86ForcedResumeCycle(
                completedCleanupFrameAddress: cleanupAddress,
                snapshot: result,
                stopEvents: stepEvents))
            completed.insert(cleanupAddress)

            switch result.disposition {
            case .endOfStack:
                return snapshot(initialAddress: initialAddress, cycles: cycles,
                                events: allEvents, terminal: .endOfStack,
                                machine: machine, threadID: threadID)

            case .stopCallbackRejected(let address, let code):
                return snapshot(initialAddress: initialAddress, cycles: cycles,
                                events: allEvents,
                                terminal: .stopCallbackRejected(frameAddress: address,
                                                               returnCode: code),
                                machine: machine, threadID: threadID)

            case .unresolvedCallSite(let address, let callSiteIP):
                return snapshot(initialAddress: initialAddress, cycles: cycles,
                                events: allEvents,
                                terminal: .unresolvedCallSite(frameAddress: address,
                                                              callSiteIP: callSiteIP),
                                machine: machine, threadID: threadID)

            case .corruptFrameChain(let missing):
                return snapshot(initialAddress: initialAddress, cycles: cycles,
                                events: allEvents,
                                terminal: .corruptFrameChain(missingFrame: missing),
                                machine: machine, threadID: threadID)

            case .nextCleanupInstalled:
                guard let nextPlan = result.nextCleanupInstallPlan,
                      nextPlan.frameAddress == result.modelTSDTopAfterResume,
                      machine.top(threadID: threadID) == nextPlan.frameAddress else {
                    throw RE4StageJ86Error.nextHandoffMismatch(result.modelTSDTopAfterResume)
                }
                if completed.count >= maxCleanupFrames {
                    return snapshot(initialAddress: initialAddress, cycles: cycles,
                                    events: allEvents,
                                    terminal: .cleanupLimitReached(
                                        nextCleanupFrameAddress: nextPlan.frameAddress),
                                    machine: machine, threadID: threadID)
                }
                let nextPhase2 = RE4StageJ6Phase2Result.installContextPending(
                    plan: nextPlan, visits: result.resumeVisits)
                let nextHandoff: RE4StageJ82ContextHandoff
                do {
                    nextHandoff = try RE4StageJ82SJLJContextBridge.makeHandoff(
                        from: nextPhase2,
                        exceptionPointer: exceptionPointer,
                        finalTSDTopAddress: machine.top(threadID: threadID),
                        j7Model: j7Model)
                } catch {
                    throw RE4StageJ86Error.nextHandoffMismatch(nextPlan.frameAddress)
                }
                handoff = RE4StageJ83HandoffInput(
                    phase2Plan: nextHandoff.phase2Plan,
                    j7Plan: nextHandoff.j7Plan,
                    finalTSDTopAddress: nextHandoff.finalTSDTopAddress,
                    controlTransferPerformed: nextHandoff.controlTransferPerformed)
            }
        }
    }

    private static func snapshot(
        initialAddress: UInt32,
        cycles: [RE4StageJ86ForcedResumeCycle],
        events: [RE4StageJ6ForcedStopEvent],
        terminal: RE4StageJ86ForcedResumeTerminal,
        machine: RE4StageJ6SJLJStateMachine,
        threadID: UInt64
    ) -> RE4StageJ86ForcedResumeChainSnapshot {
        RE4StageJ86ForcedResumeChainSnapshot(
            initialCleanupFrameAddress: initialAddress,
            cycles: cycles,
            allStopEvents: events,
            terminal: terminal,
            completedCleanupFrameAddresses: cycles.map(\.completedCleanupFrameAddress),
            finalModelTSDTop: machine.top(threadID: threadID),
            targetStopFunctionInvoked: false,
            targetResumeFunctionInvoked: false,
            guestInstructionsExecuted: false,
            guestMemoryWrites: 0,
            cpuContextApplied: false,
            controlTransferPerformed: false)
    }
}
