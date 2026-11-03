import Foundation

// Stage J.8.7: host-only reconstruction of the pinned 8C148 ARMv6 SJLJ
// stop-callback ABI and pthread-TSD frame-top transitions. No raw function
// pointer or pthread API is invoked.

public enum RE4StageJ87Error: Error, Equatable {
    case zeroStopFunction
    case zeroExceptionPointer
    case zeroContextPointer
    case missingFrame(UInt32)
}

public struct RE4StageJ87StopCallbackInvocation: Equatable {
    public let callbackAddressRaw: UInt32
    public let version: UInt32
    public let actionsRaw: UInt32
    public let exceptionClassLow: UInt32
    public let exceptionClassHigh: UInt32
    public let exceptionObjectPointer: UInt32
    public let contextPointer: UInt32
    public let stopParameter: UInt32

    /// AAPCS32 core-register assignment for the first three logical arguments.
    public var registerArgumentsR0ToR3: [UInt32] {
        [version, actionsRaw, exceptionClassLow, exceptionClassHigh]
    }

    /// Remaining pointer arguments, in ascending stack-argument order.
    public var stackArguments: [UInt32] {
        [exceptionObjectPointer, contextPointer, stopParameter]
    }

    public static let forcedCleanupActions: UInt32 = 0x0A
    public static let interfaceVersion: UInt32 = 1

    public static func make(
        exception: RE4StageJ6SJLJException,
        exceptionPointer: UInt32,
        contextPointer: UInt32
    ) throws -> Self {
        guard exception.private1 != 0 else { throw RE4StageJ87Error.zeroStopFunction }
        guard exceptionPointer != 0 else { throw RE4StageJ87Error.zeroExceptionPointer }
        guard contextPointer != 0 else { throw RE4StageJ87Error.zeroContextPointer }
        return Self(
            callbackAddressRaw: exception.private1,
            version: interfaceVersion,
            actionsRaw: forcedCleanupActions,
            exceptionClassLow: exception.exceptionClassLow,
            exceptionClassHigh: exception.exceptionClassHigh,
            exceptionObjectPointer: exceptionPointer,
            contextPointer: contextPointer,
            stopParameter: exception.private2)
    }

    /// The provider treats zero as continue and any nonzero value as fatal
    /// phase-2 error (reason code 2) in _unwind_phase2_forced.
    public func disposition(forCallbackReturn code: Int32) -> RE4StageJ87CallbackDisposition {
        code == 0 ? .continueForcedUnwind : .fatalPhase2Error(returnCode: code, unwindReason: 2)
    }
}

public enum RE4StageJ87CallbackDisposition: Equatable {
    case continueForcedUnwind
    case fatalPhase2Error(returnCode: Int32, unwindReason: UInt32)
}

public struct RE4StageJ87SJLJFrame: Equatable {
    public let address: UInt32
    public let previousFrame: UInt32
}

public enum RE4StageJ87ForcedWalkResult: Equatable {
    case endOfStack(visited: [UInt32], tsdTopAtReturn: UInt32)
    case installContext(frame: UInt32, visited: [UInt32], tsdTopAfterInstall: UInt32)
}

public enum RE4StageJ87FrameDecision: Equatable {
    case continueUnwind
    case installContext
}

/// Faithful metadata model of the observed provider operations:
/// Register: frame->prev = pthread_getspecific(key); pthread_setspecific(key, frame)
/// Unregister: pthread_setspecific(key, frame->prev)
/// Forced walk: follow frame->prev; InstallContext sets key to selected frame;
/// end-of-stack does not clear the key. Caller-side Unregister is separate.
public final class RE4StageJ87SJLJTSDModel {
    private var keyCreated = false
    private var frames: [UInt32: RE4StageJ87SJLJFrame] = [:]
    public private(set) var top: UInt32 = 0

    public init() {}

    public func createKey() { keyCreated = true }
    public var isKeyCreated: Bool { keyCreated }

    @discardableResult
    public func register(address: UInt32) throws -> RE4StageJ87SJLJFrame {
        guard keyCreated else { throw RE4StageJ87Error.zeroStopFunction }
        guard address != 0 else { throw RE4StageJ87Error.missingFrame(address) }
        let frame = RE4StageJ87SJLJFrame(address: address, previousFrame: top)
        frames[address] = frame
        top = address
        return frame
    }

    /// Mirrors the machine code literally: it takes the supplied frame's
    /// predecessor and writes that value to the TSD key. It does not search
    /// for the frame or silently repair a mismatched top.
    @discardableResult
    public func unregister(address: UInt32) throws -> UInt32 {
        guard let frame = frames[address] else { throw RE4StageJ87Error.missingFrame(address) }
        top = frame.previousFrame
        return top
    }

    public func frame(address: UInt32) -> RE4StageJ87SJLJFrame? { frames[address] }

    public func forcedWalk(
        decision: (RE4StageJ87SJLJFrame) -> RE4StageJ87FrameDecision
    ) throws -> RE4StageJ87ForcedWalkResult {
        var cursor = top
        var visited: [UInt32] = []
        var seen = Set<UInt32>()
        while cursor != 0 {
            guard !seen.contains(cursor), let frame = frames[cursor] else {
                throw RE4StageJ87Error.missingFrame(cursor)
            }
            seen.insert(cursor)
            visited.append(cursor)
            switch decision(frame) {
            case .continueUnwind:
                cursor = frame.previousFrame
            case .installContext:
                top = frame.address
                return .installContext(frame: frame.address,
                                       visited: visited,
                                       tsdTopAfterInstall: top)
            }
        }
        // Exact provider boundary: no pthread_setspecific(key, 0) on EOS.
        return .endOfStack(visited: visited, tsdTopAtReturn: top)
    }
}
