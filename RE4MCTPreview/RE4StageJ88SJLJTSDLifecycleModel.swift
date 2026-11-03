import Foundation

// Stage J.8.8: host-only model of the complete pthread TSD lifecycle around
// __Unwind_SjLj_Resume and the caller-side #101 Unregister continuation.
// No pthread API, callback, provider routine, Guest memory or CPU state is used.

public enum RE4StageJ88Error: Error, Equatable {
    case keyNotCreated
    case keyAlreadyCreated
    case zeroFrameAddress
    case frameAlreadyLinked(UInt64, UInt32)
    case missingFrame(UInt64, UInt32)
    case corruptFrameChain(UInt64, UInt32)
    case callerUnregisterMismatch(expected: UInt32, actual: UInt32)
}

public struct RE4StageJ88Frame: Equatable {
    public let address: UInt32
    public let previousFrame: UInt32
}

public enum RE4StageJ88FrameDecision: Equatable {
    case continueUnwind
    case installContext
}

public enum RE4StageJ88ProviderResult: Equatable {
    case endOfStack(reason: UInt32)
    case installContext(frameAddress: UInt32)
}

public struct RE4StageJ88ResumeLifecycleSnapshot: Equatable {
    public let threadID: UInt64
    public let initialTSDTop: UInt32
    public let visitedFrameAddresses: [UInt32]
    public let providerResult: RE4StageJ88ProviderResult
    public let tsdTopAtProviderBoundary: UInt32
    public let resumeReturnedToCallSite: Bool
    public let callerUnregisterFrameAddress: UInt32?
    public let callerUnregisterExecuted: Bool
    public let tsdTopAfterCallerContinuation: UInt32
    public let controlTransferred: Bool
}

/// pthread_key_t is process-global; its value is thread-local. The model
/// therefore keeps one key-creation state and an independent top per thread.
public final class RE4StageJ88SJLJTSDLifecycleModel {
    private var keyCreated = false
    private var keyDestructorRaw: UInt32 = 0
    private var framesByThread: [UInt64: [UInt32: RE4StageJ88Frame]] = [:]
    private var topByThread: [UInt64: UInt32] = [:]

    public init() {}

    public var isKeyCreated: Bool { keyCreated }
    public var keyDestructor: UInt32? { keyCreated ? keyDestructorRaw : nil }

    /// The pinned provider calls pthread_key_create with a null destructor.
    public func createKey(destructorRaw: UInt32 = 0) throws {
        guard !keyCreated else { throw RE4StageJ88Error.keyAlreadyCreated }
        keyCreated = true
        keyDestructorRaw = destructorRaw
    }

    public func top(threadID: UInt64) -> UInt32 {
        topByThread[threadID] ?? 0
    }

    public func frame(threadID: UInt64, address: UInt32) -> RE4StageJ88Frame? {
        framesByThread[threadID]?[address]
    }

    /// Mirrors Register: prev = pthread_getspecific(key); frame->prev = prev;
    /// pthread_setspecific(key, frame).
    @discardableResult
    public func register(threadID: UInt64, address: UInt32) throws -> RE4StageJ88Frame {
        guard keyCreated else { throw RE4StageJ88Error.keyNotCreated }
        guard address != 0 else { throw RE4StageJ88Error.zeroFrameAddress }
        let oldTop = top(threadID: threadID)
        if oldTop == address || framesByThread[threadID]?[address] != nil {
            throw RE4StageJ88Error.frameAlreadyLinked(threadID, address)
        }
        let frame = RE4StageJ88Frame(address: address, previousFrame: oldTop)
        framesByThread[threadID, default: [:]][address] = frame
        topByThread[threadID] = address
        return frame
    }

    /// Mirrors Unregister literally: pthread_setspecific(key, frame->prev).
    /// It does not perform a top-of-chain search or compare current top first.
    @discardableResult
    public func unregister(threadID: UInt64, address: UInt32) throws -> UInt32 {
        guard keyCreated else { throw RE4StageJ88Error.keyNotCreated }
        guard let frame = framesByThread[threadID]?[address] else {
            throw RE4StageJ88Error.missingFrame(threadID, address)
        }
        topByThread[threadID] = frame.previousFrame
        return frame.previousFrame
    }

    /// Models provider phase 2 and optionally the #101 caller continuation.
    /// Provider boundary and caller-side Unregister are traced separately.
    public func resumeAndContinueCaller(
        threadID: UInt64,
        callerUnregisterFrameAddress: UInt32?,
        decision: (RE4StageJ88Frame) -> RE4StageJ88FrameDecision
    ) throws -> RE4StageJ88ResumeLifecycleSnapshot {
        guard keyCreated else { throw RE4StageJ88Error.keyNotCreated }
        let entryTop = top(threadID: threadID)
        var cursor = entryTop
        var visited: [UInt32] = []
        var seen = Set<UInt32>()

        while cursor != 0 {
            guard !seen.contains(cursor),
                  let frame = framesByThread[threadID]?[cursor] else {
                throw RE4StageJ88Error.corruptFrameChain(threadID, cursor)
            }
            seen.insert(cursor)
            visited.append(cursor)
            switch decision(frame) {
            case .continueUnwind:
                cursor = frame.previousFrame
            case .installContext:
                topByThread[threadID] = frame.address
                return RE4StageJ88ResumeLifecycleSnapshot(
                    threadID: threadID,
                    initialTSDTop: entryTop,
                    visitedFrameAddresses: visited,
                    providerResult: .installContext(frameAddress: frame.address),
                    tsdTopAtProviderBoundary: top(threadID: threadID),
                    resumeReturnedToCallSite: false,
                    callerUnregisterFrameAddress: callerUnregisterFrameAddress,
                    callerUnregisterExecuted: false,
                    tsdTopAfterCallerContinuation: top(threadID: threadID),
                    controlTransferred: true)
            }
        }

        // _URC_END_OF_STACK: no pthread_setspecific(key, 0) occurs here.
        let topAtProviderReturn = top(threadID: threadID)
        var callerUnregisterExecuted = false
        if let unregisterAddress = callerUnregisterFrameAddress {
            guard unregisterAddress == entryTop else {
                throw RE4StageJ88Error.callerUnregisterMismatch(
                    expected: entryTop, actual: unregisterAddress)
            }
            _ = try unregister(threadID: threadID, address: unregisterAddress)
            callerUnregisterExecuted = true
        }
        return RE4StageJ88ResumeLifecycleSnapshot(
            threadID: threadID,
            initialTSDTop: entryTop,
            visitedFrameAddresses: visited,
            providerResult: .endOfStack(reason: 5),
            tsdTopAtProviderBoundary: topAtProviderReturn,
            resumeReturnedToCallSite: true,
            callerUnregisterFrameAddress: callerUnregisterFrameAddress,
            callerUnregisterExecuted: callerUnregisterExecuted,
            tsdTopAfterCallerContinuation: top(threadID: threadID),
            controlTransferred: false)
    }
}
