import Foundation

// Stage J.8.2: explicit metadata bridge from the J.6 SJLJ phase-2 install
// request into the J.7 / J.8.1 #101 cleanup-context plan.
// The bridge consumes value types only. It never applies a context or transfers control.

public enum RE4StageJ82BridgeError: Error, CustomStringConvertible {
    case phase2DidNotRequestInstall
    case unsupportedAction(RE4StageJ6UnwindActions)
    case missingLSDArow
    case missingLandingPadIndex
    case rowOutOfRange(Int)
    case rowIndexMismatch(row: Int, expected: UInt32, actual: UInt32)
    case unexpectedFrameAddress(UInt32)
    case savedContinuationMismatch(expected: UInt32, actual: UInt32)
    case landingPadMismatch(expected: UInt32, actual: UInt32?)
    case frameNotRetained
    case controlTransferAlreadyPerformed
    case unresolvedPhase2(UInt32?, UInt32?)
    case bridgeInvariant(String)

    public var description: String {
        switch self {
        case .phase2DidNotRequestInstall:
            return "J.6 phase 2 did not return INSTALL_CONTEXT metadata."
        case .unsupportedAction(let action):
            return "Unsupported J.6 cleanup action flags: 0x\(String(action.rawValue, radix: 16))."
        case .missingLSDArow:
            return "J.6 install plan has no LSDA row."
        case .missingLandingPadIndex:
            return "J.6 install plan has no landing-pad index."
        case .rowOutOfRange(let row):
            return "J.6 LSDA row \(row) is outside the bounded #101 cleanup rows 2...20."
        case .rowIndexMismatch(let row, let expected, let actual):
            return String(format: "J.6 row %d expects landingPadIndex %u, got %u.", row, expected, actual)
        case .unexpectedFrameAddress(let address):
            return String(format: "J.6 install frame address 0x%08X is invalid.", address)
        case .savedContinuationMismatch(let expected, let actual):
            return String(format: "J.6 saved continuation expected 0x%08X, got 0x%08X.", expected, actual)
        case .landingPadMismatch(let expected, let actual):
            if let actual {
                return String(format: "J.6 landing-pad PC expected 0x%08X, got 0x%08X.", expected, actual)
            }
            return String(format: "J.6 install plan has no landing-pad PC; expected 0x%08X.", expected)
        case .frameNotRetained:
            return "J.6 INSTALL_CONTEXT plan does not retain the selected frame at TSD top."
        case .controlTransferAlreadyPerformed:
            return "J.6 plan claims that control transfer was already performed."
        case .unresolvedPhase2(let frame, let ip):
            return "J.6 phase 2 is unresolved at frame \(frame.map { String(format: "0x%08X", $0) } ?? "unknown"), callSiteIP \(ip.map(String.init) ?? "unknown")."
        case .bridgeInvariant(let field):
            return "J.8.2 bridge invariant failed: \(field)."
        }
    }
}

/// Cross-stage record which preserves the original J.6 result and the derived J.7
/// plan. exceptionPointer is deliberately explicit because J.6 install metadata
/// carries saved registers/PC but not the exception object's address for GR0.
public struct RE4StageJ82ContextHandoff: Equatable {
    public let phase2Plan: RE4StageJ6ContextInstallPlan
    public let j7Plan: RE4StageJ7CleanupContextPlan
    public let exceptionPointerSuppliedForGR0: UInt32
    public let phase2VisitAddresses: [UInt32]
    public let finalTSDTopAddress: UInt32
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ82SJLJContextBridge {
    public static let cleanupContinuationPC: UInt32 = RE4StageJ7LandingPadContextModel.cleanupContinuationPC

    /// Converts the J.6 phase-2 result for Res4 initializer #101 into a J.7 plan.
    /// Only normal ordinary cleanup and forced cleanup are in the audited profile.
    public static func makeHandoff(from phase2: RE4StageJ6Phase2Result,
                                   exceptionPointer: UInt32,
                                   finalTSDTopAddress: UInt32,
                                   j7Model: RE4StageJ7LandingPadContextModel) throws -> RE4StageJ82ContextHandoff {
        let plan: RE4StageJ6ContextInstallPlan
        let visits: [RE4StageJ6Phase2Visit]
        switch phase2 {
        case .installContextPending(let installPlan, let phase2Visits):
            plan = installPlan
            visits = phase2Visits
        case .unresolvedCallSiteIndex(let frame, let ip, _):
            throw RE4StageJ82BridgeError.unresolvedPhase2(frame, ip)
        default:
            throw RE4StageJ82BridgeError.phase2DidNotRequestInstall
        }

        guard plan.action == .ordinaryCleanup || plan.action == .forcedCleanup else {
            throw RE4StageJ82BridgeError.unsupportedAction(plan.action)
        }
        guard let row = plan.lsdaRow else { throw RE4StageJ82BridgeError.missingLSDArow }
        guard (2...20).contains(row) else { throw RE4StageJ82BridgeError.rowOutOfRange(row) }
        guard let index = plan.landingPadIndex else { throw RE4StageJ82BridgeError.missingLandingPadIndex }
        let expectedIndex = UInt32(row - 1)
        guard index == expectedIndex else {
            throw RE4StageJ82BridgeError.rowIndexMismatch(row: row, expected: expectedIndex, actual: index)
        }
        guard plan.frameAddress != 0, finalTSDTopAddress == plan.frameAddress else {
            throw RE4StageJ82BridgeError.unexpectedFrameAddress(plan.frameAddress)
        }
        guard plan.savedContinuationPC == cleanupContinuationPC else {
            throw RE4StageJ82BridgeError.savedContinuationMismatch(expected: cleanupContinuationPC,
                                                                    actual: plan.savedContinuationPC)
        }
        guard plan.landingPadPC == cleanupContinuationPC else {
            throw RE4StageJ82BridgeError.landingPadMismatch(expected: cleanupContinuationPC,
                                                            actual: plan.landingPadPC)
        }
        guard plan.frameRetainedAtTSDTop else { throw RE4StageJ82BridgeError.frameNotRetained }
        guard !plan.controlTransferPerformed else { throw RE4StageJ82BridgeError.controlTransferAlreadyPerformed }

        guard visits.last?.frameAddress == plan.frameAddress,
              visits.last?.decision == .installCleanupContext(row: row, landingPadIndex: index) else {
            throw RE4StageJ82BridgeError.bridgeInvariant("final visit must be the selected #101 INSTALL_CONTEXT frame")
        }

        let j7Plan = try j7Model.contextPlan(row: row,
                                             frameAddress: plan.frameAddress,
                                             savedR7: plan.savedR7,
                                             savedSP: plan.savedSP,
                                             unwindExceptionPointer: exceptionPointer)
        try RE4StageJ8SyntheticContextIntegrityGuard.validatePlan(j7Plan)

        return RE4StageJ82ContextHandoff(
            phase2Plan: plan,
            j7Plan: j7Plan,
            exceptionPointerSuppliedForGR0: exceptionPointer,
            phase2VisitAddresses: visits.map(\.frameAddress),
            finalTSDTopAddress: finalTSDTopAddress,
            controlTransferPerformed: false)
    }
}
