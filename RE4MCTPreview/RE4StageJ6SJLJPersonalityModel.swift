import Foundation

// Stage J.6: host-only model of the pinned iOS 4.2.1 / 8C148 SJLJ flow and
// the one cleanup-only LSDA used by Res4 initializer #101.
// This file contains no Guest Memory adapter and never invokes an address from
// the IPA/shared cache. An install-context result is returned as metadata only.

public enum RE4StageJ6UnwindCode: Int32, Equatable {
    case noReason = 0
    case fatalPhase2Error = 2
    case fatalPhase1Error = 3
    case endOfStack = 5
    case handlerFound = 6
    case installContext = 7
    case continueUnwind = 8
}

public struct RE4StageJ6UnwindActions: OptionSet, Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let searchPhase = Self(rawValue: 1)
    public static let cleanupPhase = Self(rawValue: 2)
    public static let handlerFrame = Self(rawValue: 4)
    public static let forceUnwind = Self(rawValue: 8)

    public static let ordinaryCleanup: Self = [.cleanupPhase]
    public static let handlerCleanup: Self = [.cleanupPhase, .handlerFrame]
    public static let forcedCleanup: Self = [.cleanupPhase, .forceUnwind]
}

public enum RE4StageJ6LSDAError: Error, CustomStringConvertible, Equatable {
    case truncatedHeader
    case unsupportedLPStartEncoding(UInt8)
    case unsupportedTTypeEncoding(UInt8)
    case unsupportedCallSiteEncoding(UInt8)
    case invalidTableLength(UInt64)
    case truncatedULEB128
    case overflowingULEB128
    case malformedEntry
    case unexpectedTrailingBytes(Int)
    case wrongRowCount(Int)
    case nonCanonicalSelector(row: Int, value: UInt32)
    case nonZeroAction(row: Int, value: UInt32)

    public var description: String {
        switch self {
        case .truncatedHeader: return "LSDA header is truncated."
        case .unsupportedLPStartEncoding(let x): return String(format: "Unsupported LPStart encoding 0x%02X.", x)
        case .unsupportedTTypeEncoding(let x): return String(format: "Unsupported TType encoding 0x%02X.", x)
        case .unsupportedCallSiteEncoding(let x): return String(format: "Unsupported call-site encoding 0x%02X.", x)
        case .invalidTableLength(let n): return "Invalid or out-of-bounds call-site table length: \(n)."
        case .truncatedULEB128: return "Truncated ULEB128 value."
        case .overflowingULEB128: return "ULEB128 value exceeds the 32-bit target profile."
        case .malformedEntry: return "Call-site table does not contain complete (landing-pad-index, action) pairs."
        case .unexpectedTrailingBytes(let n): return "Unexpected trailing LSDA bytes: \(n)."
        case .wrongRowCount(let n): return "Expected 20 #101 rows; parsed \(n)."
        case .nonCanonicalSelector(let row, let value): return "#101 row \(row) has noncanonical landing-pad index \(value)."
        case .nonZeroAction(let row, let value): return "#101 row \(row) has nonzero action offset \(value); type/action tables are outside this profile."
        }
    }
}

public struct RE4StageJ6LSDAEntry: Equatable {
    /// One-based row / SJLJ call-site ordinal selected by __Unwind_GetIP.
    public let row: Int
    /// First ULEB128 value in this SJLJ row. This is an index/token, not a PC.
    public let landingPadIndex: UInt32
    /// Second ULEB128 value. All #101 rows are zero (no action-chain/type record).
    public let actionOffset: UInt32
}

public struct RE4StageJ6ExtraProductListLSDA: Equatable {
    public static let address: UInt32 = 0x001C0996
    public static let functionAddress: UInt32 = 0x00005188
    public static let personalityAddress: UInt32 = 0x374EF9F8
    public static let expectedRowCount = 20

    public let lpStartEncoding: UInt8
    public let typeTableEncoding: UInt8
    public let callSiteEncoding: UInt8
    public let rawCallSiteTableLength: UInt32
    public let entries: [RE4StageJ6LSDAEntry]

    public static func parse(_ bytes: Data) throws -> Self {
        let b = [UInt8](bytes)
        guard b.count >= 4 else { throw RE4StageJ6LSDAError.truncatedHeader }
        guard b[0] == 0xFF else { throw RE4StageJ6LSDAError.unsupportedLPStartEncoding(b[0]) }
        guard b[1] == 0xFF else { throw RE4StageJ6LSDAError.unsupportedTTypeEncoding(b[1]) }
        guard b[2] == 0x03 else { throw RE4StageJ6LSDAError.unsupportedCallSiteEncoding(b[2]) }

        var cursor = 3
        let tableLength = try readULEB128(b, cursor: &cursor)
        guard tableLength <= 4096,
              UInt64(cursor) + tableLength <= UInt64(b.count) else {
            throw RE4StageJ6LSDAError.invalidTableLength(tableLength)
        }
        let end = cursor + Int(tableLength)
        var entries: [RE4StageJ6LSDAEntry] = []
        while cursor < end {
            let landingPad = try readULEB128(b, cursor: &cursor, limit: end)
            let action = try readULEB128(b, cursor: &cursor, limit: end)
            entries.append(RE4StageJ6LSDAEntry(row: entries.count + 1,
                                               landingPadIndex: UInt32(landingPad),
                                               actionOffset: UInt32(action)))
        }
        guard cursor == end else { throw RE4StageJ6LSDAError.malformedEntry }
        guard entries.count == expectedRowCount else {
            throw RE4StageJ6LSDAError.wrongRowCount(entries.count)
        }
        let trailing = b.count - end
        guard trailing == 0 else { throw RE4StageJ6LSDAError.unexpectedTrailingBytes(trailing) }

        // Strict target profile: exact indexed sequence 0...19, actionOffset=0.
        for (i, entry) in entries.enumerated() {
            guard entry.landingPadIndex == UInt32(i) else {
                throw RE4StageJ6LSDAError.nonCanonicalSelector(row: i + 1,
                                                               value: entry.landingPadIndex)
            }
            guard entry.actionOffset == 0 else {
                throw RE4StageJ6LSDAError.nonZeroAction(row: i + 1,
                                                        value: entry.actionOffset)
            }
        }
        return Self(lpStartEncoding: b[0], typeTableEncoding: b[1],
                    callSiteEncoding: b[2], rawCallSiteTableLength: UInt32(tableLength),
                    entries: entries)
    }

    public func entry(forCallSiteIP ip: UInt32) -> RE4StageJ6LSDAEntry? {
        guard ip >= 1, ip <= UInt32(entries.count) else { return nil }
        return entries[Int(ip - 1)]
    }

    private static func readULEB128(_ bytes: [UInt8], cursor: inout Int,
                                    limit: Int? = nil) throws -> UInt64 {
        let stop = min(limit ?? bytes.count, bytes.count)
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<5 {
            guard cursor < stop else { throw RE4StageJ6LSDAError.truncatedULEB128 }
            let byte = bytes[cursor]
            cursor += 1
            let payload = UInt64(byte & 0x7F)
            if shift >= 32 || payload > (UInt64(UInt32.max) >> shift) {
                throw RE4StageJ6LSDAError.overflowingULEB128
            }
            result |= payload << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw RE4StageJ6LSDAError.overflowingULEB128
    }
}

public enum RE4StageJ6PersonalityDecision: Equatable {
    case continueUnwind
    case handlerFound
    case installCleanupContext(row: Int, landingPadIndex: UInt32)
    /// The target behavior for an out-of-profile selector is not established by
    /// the #101 audit. Preserve it as unresolved instead of fabricating return 8.
    case unresolvedCallSiteIndex(UInt32?)
    case fatalPhase1Error
    case fatalPhase2Error

    /// nil means the static evidence does not authorize assigning a provider return code.
    public var unwindCode: RE4StageJ6UnwindCode? {
        switch self {
        case .continueUnwind: return .continueUnwind
        case .handlerFound: return .handlerFound
        case .installCleanupContext: return .installContext
        case .unresolvedCallSiteIndex: return nil
        case .fatalPhase1Error: return .fatalPhase1Error
        case .fatalPhase2Error: return .fatalPhase2Error
        }
    }
}

/// Narrow personality model for the actual #101 `___gxx_personality_sj0` profile.
/// It implements only the pinned SJLJ indexed, cleanup-only LSDA. It deliberately
/// rejects other encodings, action chains, type tables and unknown action shapes.
public enum RE4StageJ6GxxPersonalityModel {
    public static let version: UInt32 = 1

    public static func evaluate(version: UInt32,
                                actions: RE4StageJ6UnwindActions,
                                callSiteIP: UInt32,
                                lsda: RE4StageJ6ExtraProductListLSDA) -> RE4StageJ6PersonalityDecision {
        guard version == Self.version else { return .fatalPhase1Error }
        let allowed = actions == .searchPhase || actions == .ordinaryCleanup ||
                      actions == .handlerCleanup || actions == .forcedCleanup
        guard allowed else { return actions.contains(.searchPhase) ? .fatalPhase1Error : .fatalPhase2Error }

        guard let entry = lsda.entry(forCallSiteIP: callSiteIP) else {
            // #101 contains only indices 1...20. Do not assume how this target's
            // personality handles an index outside the audited table.
            return .unresolvedCallSiteIndex(callSiteIP)
        }

        if actions == .searchPhase {
            // All #101 action offsets are zero and its TType table is omitted:
            // this cleanup-only frame cannot claim a typed/catch handler.
            return .continueUnwind
        }
        if actions == .handlerCleanup {
            // #101 is not a handler frame in phase 1; no typed handler is present.
            return .continueUnwind
        }
        if entry.landingPadIndex == 0 {
            return .continueUnwind
        }
        return .installCleanupContext(row: entry.row,
                                      landingPadIndex: entry.landingPadIndex)
    }
}

public enum RE4StageJ6FramePersonality: Equatable {
    case none
    case extraProductListCleanupOnly
    /// Test-only stand-in for an enclosing catcher; it is not a real provider/personality.
    case syntheticOuterHandler
}

public struct RE4StageJ6SJLJFrame: Equatable {
    public static let predecessorOffset: UInt32 = 0x00
    public static let selectorOffset: UInt32 = 0x04
    public static let personalityOffset: UInt32 = 0x18
    public static let lsdaOffset: UInt32 = 0x1C
    public static let savedR7Offset: UInt32 = 0x20
    public static let continuationPCOffset: UInt32 = 0x24
    public static let savedSPOffset: UInt32 = 0x28

    public let address: UInt32
    public let previousFrame: UInt32
    /// Raw word at frame+4; target __Unwind_GetIP returns this value + 1.
    public var selectorRaw: UInt32
    public let personality: RE4StageJ6FramePersonality
    public let personalityRaw: UInt32
    public let lsdaRaw: UInt32
    public let savedR7: UInt32
    public let continuationPC: UInt32
    public let savedSP: UInt32

    public var callSiteIP: UInt32? {
        // The pinned ARMv6 helper performs a 32-bit ADD; 0xFFFFFFFF wraps to zero.
        selectorRaw &+ 1
    }
}

public struct RE4StageJ6SJLJException: Equatable {
    public var exceptionClassLow: UInt32
    public var exceptionClassHigh: UInt32
    /// libgcc SJLJ private_1 at +0x0C. Zero = normal; nonzero = forced stop callback.
    public var private1: UInt32
    /// Normal: selected handler-frame address. Forced: stop callback parameter.
    public var private2: UInt32

    public init(exceptionClassLow: UInt32 = 0,
                exceptionClassHigh: UInt32 = 0,
                private1: UInt32 = 0,
                private2: UInt32 = 0) {
        self.exceptionClassLow = exceptionClassLow
        self.exceptionClassHigh = exceptionClassHigh
        self.private1 = private1
        self.private2 = private2
    }
}

public enum RE4StageJ6ResumeRoute: Equatable {
    case normalPhase2(handlerFrame: UInt32)
    case forcedPhase2(stopFunctionRaw: UInt32, stopParameter: UInt32)

    /// Correct contextual interpretation of the two SJLJ private words.
    public static func route(private1: UInt32, private2: UInt32) -> Self {
        private1 == 0
            ? .normalPhase2(handlerFrame: private2)
            : .forcedPhase2(stopFunctionRaw: private1, stopParameter: private2)
    }
}

public struct RE4StageJ6Phase1Visit: Equatable {
    public let frameAddress: UInt32
    public let callSiteIP: UInt32?
    public let decision: RE4StageJ6PersonalityDecision
}

public enum RE4StageJ6Phase1Result: Equatable {
    case handlerFound(frameAddress: UInt32, visits: [RE4StageJ6Phase1Visit])
    case endOfStack(visits: [RE4StageJ6Phase1Visit])
    case unresolvedCallSiteIndex(frameAddress: UInt32, callSiteIP: UInt32?, visits: [RE4StageJ6Phase1Visit])
    case fatalPhase1Error(frameAddress: UInt32, visits: [RE4StageJ6Phase1Visit])
    case corruptFrameChain(missingFrame: UInt32, visits: [RE4StageJ6Phase1Visit])
}

public struct RE4StageJ6ForcedStopEvent: Equatable {
    public let stopFunctionRaw: UInt32
    public let stopParameter: UInt32
    public let frameAddress: UInt32
    public let reason: UInt32 // _UA_FORCE_UNWIND = 10
}

public struct RE4StageJ6Phase2Visit: Equatable {
    public let frameAddress: UInt32
    public let actions: RE4StageJ6UnwindActions
    public let decision: RE4StageJ6PersonalityDecision
    public let stopCallbackReturn: Int32?
}

/// An install request is metadata only. For #101 J.1 did not reconstruct the
/// incoming landing-pad dispatch edge, so `landingPadPC` remains nil by design.
public struct RE4StageJ6ContextInstallPlan: Equatable {
    public let frameAddress: UInt32
    public let action: RE4StageJ6UnwindActions
    public let lsdaRow: Int?
    public let landingPadIndex: UInt32?
    public let savedR7: UInt32
    public let savedSP: UInt32
    public let savedContinuationPC: UInt32
    public let landingPadPC: UInt32?
    public let frameRetainedAtTSDTop: Bool
    public let controlTransferPerformed: Bool
}

public enum RE4StageJ6Phase2Result: Equatable {
    case installContextPending(plan: RE4StageJ6ContextInstallPlan, visits: [RE4StageJ6Phase2Visit])
    case endOfStack(visits: [RE4StageJ6Phase2Visit])
    case unresolvedCallSiteIndex(frameAddress: UInt32, callSiteIP: UInt32?, visits: [RE4StageJ6Phase2Visit])
    case fatalPhase2Error(frameAddress: UInt32?, visits: [RE4StageJ6Phase2Visit])
    case missingSyntheticStopCallback(stopFunctionRaw: UInt32, visits: [RE4StageJ6Phase2Visit])
    case corruptFrameChain(missingFrame: UInt32, visits: [RE4StageJ6Phase2Visit])
}

/// Synthetic TSD/frame registry and SJLJ phase state machine. This class models
/// registry metadata only; no pthread TSD, function pointer, CPU context or Guest
/// Memory is accessed.
public final class RE4StageJ6SJLJStateMachine {
    private var tops: [UInt64: UInt32] = [:]
    private var frames: [UInt64: [UInt32: RE4StageJ6SJLJFrame]] = [:]
    public let lsda: RE4StageJ6ExtraProductListLSDA

    public init(lsda: RE4StageJ6ExtraProductListLSDA) {
        self.lsda = lsda
    }

    @discardableResult
    public func register(threadID: UInt64,
                         address: UInt32,
                         selectorRaw: UInt32,
                         personality: RE4StageJ6FramePersonality,
                         savedR7: UInt32,
                         continuationPC: UInt32,
                         savedSP: UInt32) throws -> RE4StageJ6SJLJFrame {
        guard address != 0 else { throw RE4StageJ6StateError.zeroFrameAddress }
        guard !isActive(threadID: threadID, address: address) else {
            throw RE4StageJ6StateError.duplicateActiveFrame(address)
        }
        let previous = tops[threadID] ?? 0
        let personalityRaw: UInt32
        let lsdaRaw: UInt32
        switch personality {
        case .none:
            personalityRaw = 0; lsdaRaw = 0
        case .extraProductListCleanupOnly:
            personalityRaw = RE4StageJ6ExtraProductListLSDA.personalityAddress
            lsdaRaw = RE4StageJ6ExtraProductListLSDA.address
        case .syntheticOuterHandler:
            personalityRaw = 0xF00D0001; lsdaRaw = 0
        }
        let frame = RE4StageJ6SJLJFrame(address: address,
                                       previousFrame: previous,
                                       selectorRaw: selectorRaw,
                                       personality: personality,
                                       personalityRaw: personalityRaw,
                                       lsdaRaw: lsdaRaw,
                                       savedR7: savedR7,
                                       continuationPC: continuationPC,
                                       savedSP: savedSP)
        frames[threadID, default: [:]][address] = frame
        tops[threadID] = address
        return frame
    }

    public func top(threadID: UInt64) -> UInt32 { tops[threadID] ?? 0 }

    public func frame(threadID: UInt64, address: UInt32) -> RE4StageJ6SJLJFrame? {
        frames[threadID]?[address]
    }

    /// Host-only record of the #101 cleanup trampoline's frame+4 = 0xFFFFFFFF write.
    @discardableResult
    public func markCleanupContinuationComplete(threadID: UInt64, address: UInt32) throws -> UInt32 {
        guard isActive(threadID: threadID, address: address),
              var current = frames[threadID]?[address] else {
            throw RE4StageJ6StateError.unknownActiveFrame(address)
        }
        current.selectorRaw = UInt32.max
        frames[threadID]?[address] = current
        return current.selectorRaw
    }

    /// Mirrors __Unwind_SjLj_Unregister: TSD top becomes frame[0].
    @discardableResult
    public func unregister(threadID: UInt64, address: UInt32) throws -> UInt32 {
        guard let frame = frames[threadID]?[address], isActive(threadID: threadID, address: address) else {
            throw RE4StageJ6StateError.unknownActiveFrame(address)
        }
        tops[threadID] = frame.previousFrame == 0 ? nil : frame.previousFrame
        return frame.previousFrame
    }

    /// Mirrors __Unwind_SjLj_RaiseException's phase-1 walk. It clears both private
    /// words before search; a found handler is stored in private_2 (+0x10).
    public func raiseException(threadID: UInt64,
                               exception: inout RE4StageJ6SJLJException) -> RE4StageJ6Phase1Result {
        exception.private1 = 0
        exception.private2 = 0
        var cursor = tops[threadID] ?? 0
        var visits: [RE4StageJ6Phase1Visit] = []
        while cursor != 0 {
            guard let current = frames[threadID]?[cursor] else {
                return .corruptFrameChain(missingFrame: cursor, visits: visits)
            }
            let decision = phase1Decision(for: current)
            visits.append(RE4StageJ6Phase1Visit(frameAddress: cursor,
                                               callSiteIP: current.callSiteIP,
                                               decision: decision))
            switch decision {
            case .handlerFound:
                exception.private2 = current.address
                return .handlerFound(frameAddress: current.address, visits: visits)
            case .continueUnwind:
                cursor = current.previousFrame
            case .unresolvedCallSiteIndex(let ip):
                return .unresolvedCallSiteIndex(frameAddress: current.address, callSiteIP: ip, visits: visits)
            case .installCleanupContext, .fatalPhase1Error, .fatalPhase2Error:
                return .fatalPhase1Error(frameAddress: current.address, visits: visits)
            }
        }
        return .endOfStack(visits: visits)
    }

    /// Normal phase 2: reason/action=2 for ordinary frames, 6 for the handler frame.
    /// On INSTALL_CONTEXT, the pinned provider retains the current frame at TSD top,
    /// then restores the saved context and branches to the continuation. This host
    /// model records the context plan only; it does not restore registers or transfer control.
    public func phase2(threadID: UInt64, handlerFrame: UInt32) -> RE4StageJ6Phase2Result {
        var cursor = tops[threadID] ?? 0
        var visits: [RE4StageJ6Phase2Visit] = []
        while cursor != 0 {
            guard let current = frames[threadID]?[cursor] else {
                return .corruptFrameChain(missingFrame: cursor, visits: visits)
            }
            let actions: RE4StageJ6UnwindActions = current.address == handlerFrame
                ? .handlerCleanup : .ordinaryCleanup
            let decision: RE4StageJ6PersonalityDecision = current.callSiteIP == 0
                ? .continueUnwind : phase2Decision(for: current, actions: actions)
            visits.append(RE4StageJ6Phase2Visit(frameAddress: cursor,
                                               actions: actions,
                                               decision: decision,
                                               stopCallbackReturn: nil))
            switch decision {
            case .installCleanupContext(let row, let index):
                // 8C148 _unwind_phase2 calls pthread_setspecific(key, currentFrame);
                // INSTALL_CONTEXT does not unlink the current SJLJ frame.
                tops[threadID] = current.address
                let plan = RE4StageJ6ContextInstallPlan(
                    frameAddress: current.address, action: actions,
                    lsdaRow: row, landingPadIndex: index,
                    savedR7: current.savedR7, savedSP: current.savedSP,
                    savedContinuationPC: current.continuationPC,
                    landingPadPC: current.personality == .extraProductListCleanupOnly ? 0x000055A8 : nil,
                    frameRetainedAtTSDTop: true, controlTransferPerformed: false)
                return .installContextPending(plan: plan, visits: visits)
            case .continueUnwind:
                if current.address == handlerFrame {
                    return .fatalPhase2Error(frameAddress: current.address, visits: visits)
                }
                cursor = current.previousFrame
            case .unresolvedCallSiteIndex(let ip):
                return .unresolvedCallSiteIndex(frameAddress: current.address, callSiteIP: ip, visits: visits)
            case .handlerFound, .fatalPhase1Error, .fatalPhase2Error:
                return .fatalPhase2Error(frameAddress: current.address, visits: visits)
            }
        }
        return .endOfStack(visits: visits)
    }

    /// Forced phase 2: private_1 is the stop callback pointer and private_2 is its
    /// opaque parameter. The raw pointer is never called; the caller must supply a
    /// synthetic host closure to describe its result.
    public func phase2Forced(threadID: UInt64,
                             stopFunctionRaw: UInt32,
                             stopParameter: UInt32,
                             syntheticStop: ((RE4StageJ6ForcedStopEvent) -> Int32)?) -> RE4StageJ6Phase2Result {
        guard stopFunctionRaw != 0, let syntheticStop else {
            return .missingSyntheticStopCallback(stopFunctionRaw: stopFunctionRaw, visits: [])
        }
        var cursor = tops[threadID] ?? 0
        var visits: [RE4StageJ6Phase2Visit] = []
        while cursor != 0 {
            guard let current = frames[threadID]?[cursor] else {
                return .corruptFrameChain(missingFrame: cursor, visits: visits)
            }
            let stopResult = syntheticStop(RE4StageJ6ForcedStopEvent(
                stopFunctionRaw: stopFunctionRaw, stopParameter: stopParameter,
                frameAddress: current.address, reason: 10))
            if stopResult != 0 {
                visits.append(RE4StageJ6Phase2Visit(frameAddress: cursor,
                                                   actions: .forcedCleanup,
                                                   decision: .fatalPhase2Error,
                                                   stopCallbackReturn: stopResult))
                return .fatalPhase2Error(frameAddress: current.address, visits: visits)
            }
            let decision: RE4StageJ6PersonalityDecision = current.callSiteIP == 0
                ? .continueUnwind : phase2Decision(for: current, actions: .forcedCleanup)
            visits.append(RE4StageJ6Phase2Visit(frameAddress: cursor,
                                               actions: .forcedCleanup,
                                               decision: decision,
                                               stopCallbackReturn: stopResult))
            switch decision {
            case .installCleanupContext(let row, let index):
                tops[threadID] = current.address
                let plan = RE4StageJ6ContextInstallPlan(
                    frameAddress: current.address, action: .forcedCleanup,
                    lsdaRow: row, landingPadIndex: index,
                    savedR7: current.savedR7, savedSP: current.savedSP,
                    savedContinuationPC: current.continuationPC,
                    landingPadPC: current.personality == .extraProductListCleanupOnly ? 0x000055A8 : nil,
                    frameRetainedAtTSDTop: true, controlTransferPerformed: false)
                return .installContextPending(plan: plan, visits: visits)
            case .continueUnwind:
                cursor = current.previousFrame
            case .unresolvedCallSiteIndex(let ip):
                return .unresolvedCallSiteIndex(frameAddress: current.address, callSiteIP: ip, visits: visits)
            case .handlerFound, .fatalPhase1Error, .fatalPhase2Error:
                return .fatalPhase2Error(frameAddress: current.address, visits: visits)
            }
        }
        return .endOfStack(visits: visits)
    }

    public func resume(threadID: UInt64,
                       exception: RE4StageJ6SJLJException,
                       syntheticStop: ((RE4StageJ6ForcedStopEvent) -> Int32)? = nil) -> RE4StageJ6Phase2Result {
        switch RE4StageJ6ResumeRoute.route(private1: exception.private1,
                                          private2: exception.private2) {
        case .normalPhase2(let handlerFrame):
            return phase2(threadID: threadID, handlerFrame: handlerFrame)
        case .forcedPhase2(let stopFunctionRaw, let stopParameter):
            return phase2Forced(threadID: threadID,
                                stopFunctionRaw: stopFunctionRaw,
                                stopParameter: stopParameter,
                                syntheticStop: syntheticStop)
        }
    }

    private func phase1Decision(for frame: RE4StageJ6SJLJFrame) -> RE4StageJ6PersonalityDecision {
        switch frame.personality {
        case .none: return .continueUnwind
        case .extraProductListCleanupOnly:
            return RE4StageJ6GxxPersonalityModel.evaluate(version: 1,
                                                         actions: .searchPhase,
                                                         callSiteIP: frame.callSiteIP ?? UInt32.max, lsda: lsda)
        case .syntheticOuterHandler: return .handlerFound
        }
    }

    private func phase2Decision(for frame: RE4StageJ6SJLJFrame,
                                actions: RE4StageJ6UnwindActions) -> RE4StageJ6PersonalityDecision {
        switch frame.personality {
        case .none: return .continueUnwind
        case .extraProductListCleanupOnly:
            return RE4StageJ6GxxPersonalityModel.evaluate(version: 1,
                                                         actions: actions,
                                                         callSiteIP: frame.callSiteIP ?? UInt32.max, lsda: lsda)
        case .syntheticOuterHandler:
            if actions == .handlerCleanup { return .installCleanupContext(row: 0, landingPadIndex: 0) }
            return .continueUnwind
        }
    }

    private func isActive(threadID: UInt64, address: UInt32) -> Bool {
        var cursor = tops[threadID] ?? 0
        var visited = Set<UInt32>()
        while cursor != 0 && visited.insert(cursor).inserted {
            if cursor == address { return true }
            guard let frame = frames[threadID]?[cursor] else { return false }
            cursor = frame.previousFrame
        }
        return false
    }
}

public enum RE4StageJ6StateError: Error, CustomStringConvertible {
    case zeroFrameAddress
    case duplicateActiveFrame(UInt32)
    case unknownActiveFrame(UInt32)

    public var description: String {
        switch self {
        case .zeroFrameAddress: return "Frame address zero is reserved for end-of-chain."
        case .duplicateActiveFrame(let a): return String(format: "Frame 0x%08X is already active.", a)
        case .unknownActiveFrame(let a): return String(format: "Frame 0x%08X is not active.", a)
        }
    }
}

public enum RE4StageJ6StaticContextHelpers {
    /// Pinned helper at 0x358CF6A8: read the LSDA pointer at frame+0x1c.
    public static func getLanguageSpecificData(frame: RE4StageJ6SJLJFrame) -> UInt32 {
        frame.lsdaRaw
    }

    /// Pinned helper at 0x358CF6B0: the provider computes frame + 8 + 4*register.
    /// This returns only the target-relative offset; it does not read a frame word.
    public static func generalRegisterWordOffset(registerNumber: UInt32) -> UInt32? {
        let (scaled, overflow1) = registerNumber.multipliedReportingOverflow(by: 4)
        let (offset, overflow2) = scaled.addingReportingOverflow(8)
        return overflow1 || overflow2 ? nil : offset
    }

    /// Pinned helper at 0x358CF6D0: load frame+4, then add one.
    public static func getIP(selectorRaw: UInt32) -> UInt32? {
        selectorRaw &+ 1
    }

    /// Pinned helper at 0x358CF6F0: subtract one, then store at frame+4.
    public static func setIP(ip: UInt32) -> UInt32? {
        guard ip > 0 else { return nil }
        return ip - 1
    }

    /// Pinned helper at 0x358CF6FC returns zero for the target SJLJ provider.
    public static let regionStart: UInt32 = 0
}