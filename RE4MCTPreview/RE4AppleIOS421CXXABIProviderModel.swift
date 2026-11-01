import Foundation

/// Data-only model of iOS 4.2.1 / 8C148 libSystem.B.dylib atexit behavior.
/// Callback addresses are never invoked. Callback returns are injected as registration data.
public struct RE4AppleIOS421AtexitProviderModel {
    public struct RegistrationInput: Equatable {
        public let functionPointerRaw: UInt32
        public let argument: UInt32
        public let dsoHandle: UInt32
        public init(functionPointerRaw: UInt32, argument: UInt32, dsoHandle: UInt32) {
            self.functionPointerRaw = functionPointerRaw
            self.argument = argument
            self.dsoHandle = dsoHandle
        }
    }

    public struct CallPlan: Equatable {
        public let registrationID: UInt64
        public let kind: UInt32
        public let functionPointerRaw: UInt32
        public let functionAddress: UInt32
        public let instructionSet: RE4CXXFunctionPointerState
        public let argument: UInt32
        public let dsoHandle: UInt32
        public let releasesRegistryMutexBeforeCallback: Bool
    }

    public struct NodeInfo: Equatable {
        public let id: Int
        public let isStatic: Bool
        public let nextID: Int?
        public let count: Int
        public let allocationBytes: Int
    }

    private struct Entry {
        let id: UInt64
        var kind: UInt32
        let function: UInt32
        let argument: UInt32
        let dso: UInt32
    }
    private struct Node {
        let id: Int
        let isStatic: Bool
        let nextID: Int?
        var entries: [Entry]
    }

    public static let recordBytes = 16
    public static let headerBytes = 8
    public static let recordsPerNode = 32
    public static let dynamicNodeBytes = 0x208
    public static let cxaAtexitKind: UInt32 = 2

    private var nodes = [Node(id: 0, isStatic: true, nextID: nil, entries: [])]
    private var rootID = 0
    private var nextNodeID = 1
    private var nextRegistrationID: UInt64 = 1
    public private(set) var newRegistrationFlag = false

    public init() {}

    public var registrationCount: Int { nodes.reduce(0) { $0 + $1.entries.count } }
    public var pendingCount: Int { nodes.reduce(0) { $0 + $1.entries.filter { $0.kind != 0 }.count } }
    public var consumedCount: Int { registrationCount - pendingCount }
    public var nodeCount: Int { nodes.count }
    public var dynamicNodeCount: Int { nodes.count - 1 }

    @discardableResult
    public mutating func register(_ input: RegistrationInput) throws -> UInt64 {
        guard nextRegistrationID < UInt64.max else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        if nodes[rootID].entries.count == Self.recordsPerNode {
            let id = nextNodeID
            nextNodeID += 1
            nodes.append(Node(id: id, isStatic: false, nextID: rootID, entries: []))
            rootID = id
        }
        let id = nextRegistrationID
        nextRegistrationID += 1
        nodes[rootID].entries.append(Entry(
            id: id, kind: Self.cxaAtexitKind,
            function: input.functionPointerRaw, argument: input.argument, dso: input.dsoHandle
        ))
        newRegistrationFlag = true
        return id
    }

    public func nodeInfoNewestFirst() -> [NodeInfo] {
        var result: [NodeInfo] = []
        var cursor: Int? = rootID
        while let id = cursor {
            let node = nodes[id]
            result.append(NodeInfo(
                id: id, isStatic: node.isStatic, nextID: node.nextID,
                count: node.entries.count,
                allocationBytes: node.isStatic ? 0 : Self.dynamicNodeBytes
            ))
            cursor = node.nextID
        }
        return result
    }

    public func kind(of registrationID: UInt64) -> UInt32? {
        for node in nodes {
            if let entry = node.entries.first(where: { $0.id == registrationID }) {
                return entry.kind
            }
        }
        return nil
    }

    /// finalizeDSO == 0 selects every DSO. A nonzero value selects exact equality.
    /// Injected callback-return registrations are data only; no closure/function runs.
    public mutating func simulateFinalize(
        finalizeDSO: UInt32,
        callbackReturnRegistrations: [UInt64: [RegistrationInput]] = [:]
    ) throws -> [CallPlan] {
        var result: [CallPlan] = []
        var applied = Set<UInt64>()
        var nodeCursor: Int? = rootID
        var recordCursor = nodes[rootID].entries.count - 1

        while let nodeID = nodeCursor {
            if recordCursor < 0 {
                nodeCursor = nodes[nodeID].nextID
                if let next = nodeCursor {
                    recordCursor = nodes[next].entries.count - 1
                }
                continue
            }

            let index = recordCursor
            recordCursor -= 1
            let entry = nodes[nodeID].entries[index]
            guard entry.kind != 0 else { continue }
            guard finalizeDSO == 0 || entry.dso == finalizeDSO else { continue }

            // Copy the registration record, then clear the original kind before callback.
            nodes[nodeID].entries[index].kind = 0
            newRegistrationFlag = false
            let thumb = entry.function & 1 != 0
            result.append(CallPlan(
                registrationID: entry.id,
                kind: entry.kind,
                functionPointerRaw: entry.function,
                functionAddress: thumb ? (entry.function & ~UInt32(1)) : (entry.function & ~UInt32(3)),
                instructionSet: thumb ? .thumb : .arm,
                argument: entry.argument,
                dsoHandle: entry.dso,
                releasesRegistryMutexBeforeCallback: true
            ))

            // A callback return is modeled as a deterministic data injection only.
            if !applied.contains(entry.id), let added = callbackReturnRegistrations[entry.id] {
                applied.insert(entry.id)
                for item in added {
                    _ = try register(item)
                }
            }

            // The provider clears _new_registration before callback and restarts at root
            // after callback if a new registration was added during that callback.
            if newRegistrationFlag {
                nodeCursor = rootID
                recordCursor = nodes[rootID].entries.count - 1
            }
        }
        return result
    }

    public static func runSyntheticSelfTest() throws -> String {
        var boundary = Self()
        for i in 0..<32 {
            _ = try boundary.register(.init(
                functionPointerRaw: UInt32(0x1000 + i * 4),
                argument: UInt32(i), dsoHandle: 0x1000
            ))
        }
        let full = boundary.nodeInfoNewestFirst()
        guard boundary.nodeCount == 1, full.count == 1, full[0].isStatic,
              full[0].count == 32, full[0].nextID == nil else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        let id33 = try boundary.register(.init(
            functionPointerRaw: 0x2000, argument: 33, dsoHandle: 0x1000
        ))
        let over = boundary.nodeInfoNewestFirst()
        guard id33 == 33, over.count == 2, over[0].count == 1,
              over[0].allocationBytes == 0x208, over[0].nextID == over[1].id,
              over[1].isStatic, over[1].count == 32 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }

        var many = Self()
        for i in 0..<65 {
            _ = try many.register(.init(
                functionPointerRaw: UInt32(0x3000 + i * 4),
                argument: UInt32(i), dsoHandle: 0xA11
            ))
        }
        guard many.nodeInfoNewestFirst().map(\.count) == [1, 32, 32],
              many.dynamicNodeCount == 2 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        let lifo = try many.simulateFinalize(finalizeDSO: 0xA11)
        guard lifo.map(\.registrationID) == (1...65).reversed().map(UInt64.init),
              many.pendingCount == 0, many.consumedCount == 65 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }

        var dso = Self()
        _ = try dso.register(.init(functionPointerRaw: 0x4000, argument: 1, dsoHandle: 0x1000))
        _ = try dso.register(.init(functionPointerRaw: 0x4004, argument: 2, dsoHandle: 0x2000))
        _ = try dso.register(.init(functionPointerRaw: 0x4008, argument: 3, dsoHandle: 0))
        let exact = try dso.simulateFinalize(finalizeDSO: 0x1000)
        guard exact.map(\.registrationID) == [1], dso.pendingCount == 2,
              dso.kind(of: 1) == 0, dso.kind(of: 2) == 2, dso.kind(of: 3) == 2 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        let all = try dso.simulateFinalize(finalizeDSO: 0)
        guard all.map(\.registrationID) == [3, 2], all.map(\.dsoHandle) == [0, 0x2000],
              dso.pendingCount == 0 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }

        var reentrant = Self()
        _ = try reentrant.register(.init(functionPointerRaw: 0x5000, argument: 11, dsoHandle: 0x1000))
        _ = try reentrant.register(.init(functionPointerRaw: 0x5004, argument: 22, dsoHandle: 0x1000))
        let trace = try reentrant.simulateFinalize(finalizeDSO: 0x1000, callbackReturnRegistrations: [
            2: [.init(functionPointerRaw: 0x5008, argument: 33, dsoHandle: 0x1000)],
            3: [.init(functionPointerRaw: 0x500C, argument: 44, dsoHandle: 0x1000)]
        ])
        guard trace.map(\.registrationID) == [2, 3, 4, 1],
              trace.map(\.argument) == [22, 33, 44, 11],
              reentrant.pendingCount == 0, !reentrant.newRegistrationFlag else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }

        var fields = Self()
        let thumbID = try fields.register(.init(
            functionPointerRaw: 0x35E0AFE9, argument: 0xBEEF, dsoHandle: 0x1000
        ))
        let plan = try fields.simulateFinalize(finalizeDSO: 0x1000)
        guard plan.count == 1, plan[0].kind == 2,
              plan[0].functionPointerRaw == 0x35E0AFE9,
              plan[0].functionAddress == 0x35E0AFE8,
              plan[0].instructionSet == .thumb, plan[0].argument == 0xBEEF,
              plan[0].releasesRegistryMutexBeforeCallback,
              fields.kind(of: thumbID) == 0 else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }

        return "iOS 4.2.1 libSystem provider ABI regression tests PASS\n" +
            "32-record node boundary; dynamic 0x208-byte node at record 33: PASS\n" +
            "65-record global LIFO across three linked nodes: PASS\n" +
            "Nonzero exact DSO filter; finalize(0) includes all DSOs: PASS\n" +
            "Synthetic callback-return registrations trigger root restart: PASS\n" +
            "Original kind cleared before callback; kind-2 fields/Thumb bit preserved: PASS\n" +
            "Callback boundary is outside registry mutex when threaded; no callback invoked."
    }
}

/// The six output streams flushed by the observed 8C148 ios_base::Init destructor.
public enum RE4AppleIOS421OutputStream: String, Equatable {
    case cout, cerr, clog, wcout, wcerr, wclog
}

/// Host-only counter/event model for iOS 4.2.1 / 8C148 libstdc++.6.dylib ios_base::Init.
/// Atomic increment: only pre-increment old value 0 constructs standard streams.
/// Atomic decrement: only pre-decrement old value 2 flushes the six output streams.
/// No sentinel reference is added. Events are data only; this model does no real I/O.
public struct RE4AppleIOS421IOSBaseInitModel {
    public enum Event: Equatable {
        case synchronizedWithStdioEnabled
        case narrowStandardStreamsConstructed
        case wideStandardStreamsConstructed
        case standardStreamFlushed(RE4AppleIOS421OutputStream)
    }

    public private(set) var referenceCount: UInt32 = 0
    public private(set) var standardStreamsInitialized = false
    public private(set) var synchronizedWithStdio = false
    public private(set) var flushCount = 0

    public static let providerFlushOrder: [RE4AppleIOS421OutputStream] = [
        .cout, .cerr, .clog, .wcout, .wcerr, .wclog
    ]

    public init() {}

    public mutating func constructInstance() throws -> [Event] {
        guard referenceCount < UInt32.max else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        let oldCount = referenceCount
        referenceCount += 1
        guard oldCount == 0 else { return [] }
        synchronizedWithStdio = true
        standardStreamsInitialized = true
        return [
            .synchronizedWithStdioEnabled,
            .narrowStandardStreamsConstructed,
            .wideStandardStreamsConstructed
        ]
    }

    public mutating func destroyInstance() throws -> [Event] {
        guard referenceCount > 0 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let oldCount = referenceCount
        referenceCount -= 1
        guard oldCount == 2 else { return [] }
        flushCount += Self.providerFlushOrder.count
        return Self.providerFlushOrder.map(Event.standardStreamFlushed)
    }

    public static func runSyntheticSelfTest() throws -> String {
        var pair = Self()
        let first = try pair.constructInstance()
        guard first == [
            .synchronizedWithStdioEnabled,
            .narrowStandardStreamsConstructed,
            .wideStandardStreamsConstructed
        ], pair.referenceCount == 1, pair.standardStreamsInitialized,
           pair.synchronizedWithStdio else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let second = try pair.constructInstance()
        guard second.isEmpty, pair.referenceCount == 2 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let oldTwo = try pair.destroyInstance()
        guard oldTwo == Self.providerFlushOrder.map(Event.standardStreamFlushed),
              pair.referenceCount == 1, pair.flushCount == 6 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let oldOne = try pair.destroyInstance()
        guard oldOne.isEmpty, pair.referenceCount == 0, pair.flushCount == 6 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }

        var singleton = Self()
        _ = try singleton.constructInstance()
        let singleDestroy = try singleton.destroyInstance()
        guard singleDestroy.isEmpty, singleton.referenceCount == 0,
              singleton.flushCount == 0 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }

        return "iOS 4.2.1 libstdc++ ios_base::Init provider regression tests PASS\n" +
            "Atomic increment; only old-value 0 constructs streams: PASS\n" +
            "No unsupported sentinel reference increment: PASS\n" +
            "Atomic decrement; only pre-decrement old-value 2 flushes: PASS\n" +
            "Flush order cout/cerr/clog/wcout/wcerr/wclog: PASS\n" +
            "Single-instance old-value 1 destructor does not flush: PASS\n" +
            "Conceptual events only; no stdio or Guest provider function was called."
    }
}
