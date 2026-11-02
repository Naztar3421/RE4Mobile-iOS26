import Foundation

// MARK: - ABI metadata (addresses are data only; this module never branches to them)

public enum RE4StageJ4FunctionPointerState: String, Equatable {
    case arm = "ARM"
    case thumb = "Thumb"
}

public enum RE4StageJ4InvocationDescriptor: Equatable {
    case functionWithArgument
    case functionWithoutArgument
    case objectFunctionAtOffset(UInt32)
    case unsupportedKind(UInt32)
}

public struct RE4StageJ4DestructorCallPlan: Equatable {
    public let registrationID: UInt64
    public let kind: UInt32
    public let functionPointerRaw: UInt32
    public let functionAddress: UInt32
    public let functionState: RE4StageJ4FunctionPointerState
    public let argument: UInt32
    public let dsoHandle: UInt32
    public let invocation: RE4StageJ4InvocationDescriptor
}

public struct RE4StageJ4AtexitRegistrationResult: Equatable {
    /// Provider returns 0 on successful append and -1 on allocation failure.
    public let returnCode: Int32
    public let registrationID: UInt64?
}

public struct RE4StageJ4RegistrationRecordSnapshot: Equatable {
    public let registrationID: UInt64
    public let nodeID: UInt64
    public let nodeIsStatic: Bool
    public let recordIndex: Int
    public let kind: UInt32
    public let functionPointerRaw: UInt32
    public let argument: UInt32
    public let dsoHandle: UInt32
}

public struct RE4StageJ4RegistryNodeSnapshot: Equatable {
    public let nodeID: UInt64
    public let isStatic: Bool
    public let recordCount: Int
    public let registrationIDs: [UInt64]
    public let allocationBytes: Int
}

public enum RE4StageJ4RegistryEvent: Equatable {
    case staticNodeCreated(nodeID: UInt64)
    case dynamicNodeAllocated(nodeID: UInt64, bytes: Int)
    case dynamicNodePrepended(nodeID: UInt64)
    case dynamicNodeFreed(nodeID: UInt64)
    case recordAppended(registrationID: UInt64, nodeID: UInt64, index: Int)
    case recordKindCleared(registrationID: UInt64)
    case callbackEntered(registrationID: UInt64)
    case callbackReturned(registrationID: UInt64)
    case restartFromCurrentRoot
}

public enum RE4StageJ4MutexEvent: String, Equatable {
    case lock
    case unlock
}

public struct RE4StageJ4FinalizeResult: Equatable {
    /// Supported call forms are descriptions only; no Guest function pointer is invoked.
    public let invocations: [RE4StageJ4DestructorCallPlan]
    /// Every claimed record, including unsupported kinds, has its original kind cleared.
    public let claimedRegistrationIDs: [UInt64]
    public let restartCount: Int
    public let remainingPendingCount: Int
}

/// Provider-specific host-only model for the iOS 4.2.1 / 8C148 libSystem C++
/// registration registry. It is intentionally single-threaded; `isThreaded` controls
/// only the lock/unlock protocol recorded by the model. Test callbacks are injected
/// host closures that may mutate this model to test re-registration. Raw Guest callback
/// addresses are never dereferenced or invoked.
public final class RE4StageJ4ProviderRegistry {
    public static let recordSize = 16
    public static let nodeHeaderSize = 8
    public static let recordsPerNode = 32
    public static let dynamicNodeSize = 0x208
    public static let cxaAtexitKind: UInt32 = 2

    private struct Record {
        let id: UInt64
        var kind: UInt32
        let functionPointerRaw: UInt32
        let argument: UInt32
        let dsoHandle: UInt32
    }

    private final class Node {
        let id: UInt64
        let isStatic: Bool
        var records: [Record] = []
        var next: Node?

        init(id: UInt64, isStatic: Bool) {
            self.id = id
            self.isStatic = isStatic
        }
    }

    public let isThreaded: Bool
    private var root: Node?
    private var staticFirstNode: Node?
    private var nextRegistrationID: UInt64 = 1
    private var nextNodeID: UInt64 = 1

    public private(set) var newRegistrationFlag = false
    public private(set) var mutexIsHeld = false
    public private(set) var events: [RE4StageJ4RegistryEvent] = []
    public private(set) var mutexEvents: [RE4StageJ4MutexEvent] = []
    public private(set) var dynamicNodeAllocationSizes: [Int] = []
    public private(set) var dynamicNodeFreedIDs: [UInt64] = []

    public init(isThreaded: Bool) {
        self.isThreaded = isThreaded
    }

    public var registrationCount: Int {
        nodeSnapshotsNewestFirst.reduce(0) { $0 + $1.recordCount }
    }

    public var pendingCount: Int {
        allRecordSnapshots.reduce(0) { $0 + ($1.kind == 0 ? 0 : 1) }
    }

    public var nodeSnapshotsNewestFirst: [RE4StageJ4RegistryNodeSnapshot] {
        var result: [RE4StageJ4RegistryNodeSnapshot] = []
        var node = root
        while let current = node {
            result.append(RE4StageJ4RegistryNodeSnapshot(
                nodeID: current.id,
                isStatic: current.isStatic,
                recordCount: current.records.count,
                registrationIDs: current.records.map(\.id),
                allocationBytes: current.isStatic ? 0 : Self.dynamicNodeSize
            ))
            node = current.next
        }
        return result
    }

    public var allRecordSnapshots: [RE4StageJ4RegistrationRecordSnapshot] {
        var result: [RE4StageJ4RegistrationRecordSnapshot] = []
        var node = root
        while let current = node {
            for (index, record) in current.records.enumerated() {
                result.append(snapshot(record, in: current, index: index))
            }
            node = current.next
        }
        return result
    }

    public func recordSnapshot(registrationID: UInt64) -> RE4StageJ4RegistrationRecordSnapshot? {
        var node = root
        while let current = node {
            if let index = current.records.firstIndex(where: { $0.id == registrationID }) {
                return snapshot(current.records[index], in: current, index: index)
            }
            node = current.next
        }
        return nil
    }

    /// Models `___cxa_atexit`: it always submits kind=2, followed by function,
    /// argument and DSO words. Zero DSO is stored as data; it is not a wildcard
    /// until it is supplied as the argument to `___cxa_finalize`.
    @discardableResult
    public func register(functionPointerRaw: UInt32,
                         argument: UInt32,
                         dsoHandle: UInt32,
                         allocatorSucceeds: Bool = true,
                         beforeRootRevalidation: (() -> Void)? = nil) -> RE4StageJ4AtexitRegistrationResult {
        registerRecord(kind: Self.cxaAtexitKind,
                       functionPointerRaw: functionPointerRaw,
                       argument: argument,
                       dsoHandle: dsoHandle,
                       allocatorSucceeds: allocatorSucceeds,
                       beforeRootRevalidation: beforeRootRevalidation)
    }

    /// Lower-level fixture entry point for exercising the three callback kinds
    /// visible in `___cxa_finalize`. Actual `___cxa_atexit` registrations use kind=2.
    @discardableResult
    public func registerRecord(kind: UInt32,
                               functionPointerRaw: UInt32,
                               argument: UInt32,
                               dsoHandle: UInt32,
                               allocatorSucceeds: Bool = true,
                               beforeRootRevalidation: (() -> Void)? = nil) -> RE4StageJ4AtexitRegistrationResult {
        acquireMutex()
        if root == nil {
            let initial = Node(id: allocateNodeID(), isStatic: true)
            root = initial
            staticFirstNode = initial
            events.append(.staticNodeCreated(nodeID: initial.id))
        }

        var didRunInterleaveHook = false
        while let observedRoot = root {
            if observedRoot.records.count < Self.recordsPerNode {
                let result = append(kind: kind,
                                    functionPointerRaw: functionPointerRaw,
                                    argument: argument,
                                    dsoHandle: dsoHandle,
                                    to: observedRoot)
                releaseMutex()
                return result
            }

            // The provider drops the mutex while allocating a 0x208-byte node.
            releaseMutex()
            guard allocatorSucceeds else {
                return RE4StageJ4AtexitRegistrationResult(returnCode: -1, registrationID: nil)
            }

            let fresh = Node(id: allocateNodeID(), isStatic: false)
            dynamicNodeAllocationSizes.append(Self.dynamicNodeSize)
            events.append(.dynamicNodeAllocated(nodeID: fresh.id, bytes: Self.dynamicNodeSize))

            if !didRunInterleaveHook {
                didRunInterleaveHook = true
                beforeRootRevalidation?()
            }

            acquireMutex()
            if root === observedRoot {
                fresh.next = observedRoot
                root = fresh
                events.append(.dynamicNodePrepended(nodeID: fresh.id))
                let result = append(kind: kind,
                                    functionPointerRaw: functionPointerRaw,
                                    argument: argument,
                                    dsoHandle: dsoHandle,
                                    to: fresh)
                releaseMutex()
                return result
            }

            // Another registration changed the root while allocation was outside
            // the lock. The provider frees its candidate and retries from the new root.
            releaseMutex()
            dynamicNodeFreedIDs.append(fresh.id)
            events.append(.dynamicNodeFreed(nodeID: fresh.id))
            acquireMutex()
        }

        // root can only be nil here if an external test fixture corrupted state.
        releaseMutex()
        return RE4StageJ4AtexitRegistrationResult(returnCode: -1, registrationID: nil)
    }

    /// Models the provider traversal. `dsoHandle == 0` disables DSO filtering;
    /// any nonzero value requires exact equality. The provider copies the record,
    /// clears its original kind, unlocks around the callback, then checks the
    /// re-registration flag and restarts at the current root when needed.
    ///
    /// `onSyntheticCallback` is test-harness behavior only. It must not call, emulate,
    /// or dereference any address from the IPA/shared cache. It may call `register`
    /// to model a callback that registers another host-side synthetic record.
    public func finalize(dsoHandle: UInt32,
                        onSyntheticCallback: ((RE4StageJ4DestructorCallPlan) -> Void)? = nil) -> RE4StageJ4FinalizeResult {
        var invocations: [RE4StageJ4DestructorCallPlan] = []
        var claimedIDs: [UInt64] = []
        var restartCount = 0

        acquireMutex()
        var currentNode = root
        var recordIndex = (currentNode?.records.count ?? 0) - 1

        while let node = currentNode {
            if recordIndex < 0 {
                currentNode = node.next
                recordIndex = (currentNode?.records.count ?? 0) - 1
                continue
            }

            let candidate = node.records[recordIndex]
            let dsoMatches = dsoHandle == 0 || candidate.dsoHandle == dsoHandle
            if candidate.kind != 0 && dsoMatches {
                // Save a complete copy before consuming the provider's original record.
                let saved = candidate
                node.records[recordIndex].kind = 0
                claimedIDs.append(saved.id)
                events.append(.recordKindCleared(registrationID: saved.id))
                newRegistrationFlag = false

                let plan = makePlan(saved)
                releaseMutex()
                if plan.invocation != .unsupportedKind(saved.kind) {
                    invocations.append(plan)
                    events.append(.callbackEntered(registrationID: saved.id))
                    onSyntheticCallback?(plan)
                    events.append(.callbackReturned(registrationID: saved.id))
                }
                acquireMutex()

                if newRegistrationFlag {
                    restartCount += 1
                    events.append(.restartFromCurrentRoot)
                    currentNode = root
                    recordIndex = (currentNode?.records.count ?? 0) - 1
                    continue
                }
            }

            recordIndex -= 1
        }

        releaseMutex()
        return RE4StageJ4FinalizeResult(
            invocations: invocations,
            claimedRegistrationIDs: claimedIDs,
            restartCount: restartCount,
            remainingPendingCount: pendingCount
        )
    }

    private func append(kind: UInt32,
                        functionPointerRaw: UInt32,
                        argument: UInt32,
                        dsoHandle: UInt32,
                        to node: Node) -> RE4StageJ4AtexitRegistrationResult {
        guard nextRegistrationID < UInt64.max else {
            return RE4StageJ4AtexitRegistrationResult(returnCode: -1, registrationID: nil)
        }
        let id = nextRegistrationID
        nextRegistrationID += 1
        let index = node.records.count
        node.records.append(Record(id: id,
                                   kind: kind,
                                   functionPointerRaw: functionPointerRaw,
                                   argument: argument,
                                   dsoHandle: dsoHandle))
        newRegistrationFlag = true
        events.append(.recordAppended(registrationID: id, nodeID: node.id, index: index))
        return RE4StageJ4AtexitRegistrationResult(returnCode: 0, registrationID: id)
    }

    private func acquireMutex() {
        guard isThreaded else { return }
        precondition(!mutexIsHeld, "Synthetic provider mutex was acquired recursively")
        mutexIsHeld = true
        mutexEvents.append(.lock)
    }

    private func releaseMutex() {
        guard isThreaded else { return }
        precondition(mutexIsHeld, "Synthetic provider mutex was released while not held")
        mutexIsHeld = false
        mutexEvents.append(.unlock)
    }

    private func allocateNodeID() -> UInt64 {
        let id = nextNodeID
        nextNodeID += 1
        return id
    }

    private func snapshot(_ record: Record, in node: Node, index: Int) -> RE4StageJ4RegistrationRecordSnapshot {
        RE4StageJ4RegistrationRecordSnapshot(
            registrationID: record.id,
            nodeID: node.id,
            nodeIsStatic: node.isStatic,
            recordIndex: index,
            kind: record.kind,
            functionPointerRaw: record.functionPointerRaw,
            argument: record.argument,
            dsoHandle: record.dsoHandle
        )
    }

    private func makePlan(_ record: Record) -> RE4StageJ4DestructorCallPlan {
        let thumb = record.functionPointerRaw & 1 != 0
        let state: RE4StageJ4FunctionPointerState = thumb ? .thumb : .arm
        let address = thumb
            ? (record.functionPointerRaw & ~UInt32(1))
            : (record.functionPointerRaw & ~UInt32(3))
        let invocation: RE4StageJ4InvocationDescriptor
        switch record.kind {
        case 1: invocation = .functionWithoutArgument
        case 2: invocation = .functionWithArgument
        case 3: invocation = .objectFunctionAtOffset(0x0C)
        default: invocation = .unsupportedKind(record.kind)
        }
        return RE4StageJ4DestructorCallPlan(
            registrationID: record.id,
            kind: record.kind,
            functionPointerRaw: record.functionPointerRaw,
            functionAddress: address,
            functionState: state,
            argument: record.argument,
            dsoHandle: record.dsoHandle,
            invocation: invocation
        )
    }
}

// MARK: - Provider-specific std::ios_base::Init reference counter model

public enum RE4StageJ4IOSBaseInitEvent: Equatable {
    case atomicIncrement(oldValue: UInt32, newValue: UInt32)
    case synchronizedWithStdioSetTrue
    case narrowStandardStreamsConstructed
    case wideStandardStreamsConstructed
    case secondAtomicIncrementAfterOneTimeSetup(oldValue: UInt32, newValue: UInt32)
    case atomicDecrement(oldValue: UInt32, newValue: UInt32)
    case standardStreamFlushed(String)
}

/// Host-only state model for the exact C2/D2 counter gates found in the pinned
/// `libstdc++.6.dylib`. Counter operations are deterministic state transitions here;
/// the ARM LDREX/STREX implementation is evidenced by disassembly but is not executed
/// or stress-tested on the host.
public final class RE4StageJ4IOSBaseInitModel {
    public static let flushTargets = ["std::cout", "std::cerr", "std::clog",
                                      "std::wcout", "std::wcerr", "std::wclog"]

    public private(set) var referenceCount: UInt32
    public private(set) var synchronizedWithStdioWasSet = false
    public private(set) var oneTimeStreamInitializationPasses = 0
    public private(set) var flushPasses = 0

    public init(initialReferenceCount: UInt32 = 0) {
        self.referenceCount = initialReferenceCount
    }

    /// Mirrors InitC2: atomic +1; if the old count was zero, set the sync flag,
    /// construct narrow and wide standard streams, then perform the second atomic +1
    /// visible near the end of the one-time initialization path.
    public func constructInstance() -> [RE4StageJ4IOSBaseInitEvent] {
        let oldValue = referenceCount
        referenceCount = referenceCount &+ 1
        var events: [RE4StageJ4IOSBaseInitEvent] = [
            .atomicIncrement(oldValue: oldValue, newValue: referenceCount)
        ]
        guard oldValue == 0 else { return events }

        synchronizedWithStdioWasSet = true
        oneTimeStreamInitializationPasses += 1
        events.append(.synchronizedWithStdioSetTrue)
        events.append(.narrowStandardStreamsConstructed)
        events.append(.wideStandardStreamsConstructed)

        let secondOldValue = referenceCount
        referenceCount = referenceCount &+ 1
        events.append(.secondAtomicIncrementAfterOneTimeSetup(
            oldValue: secondOldValue,
            newValue: referenceCount
        ))
        return events
    }

    /// Mirrors InitD2: atomic -1; flush six output streams only when the
    /// pre-decrement value was exactly 2. No host stream is actually flushed.
    public func destroyInstance() -> [RE4StageJ4IOSBaseInitEvent] {
        let oldValue = referenceCount
        referenceCount = referenceCount &- 1
        var events: [RE4StageJ4IOSBaseInitEvent] = [
            .atomicDecrement(oldValue: oldValue, newValue: referenceCount)
        ]
        guard oldValue == 2 else { return events }

        flushPasses += 1
        events.append(contentsOf: Self.flushTargets.map(RE4StageJ4IOSBaseInitEvent.standardStreamFlushed))
        return events
    }
}