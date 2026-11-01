import Foundation

/// The instruction-set state encoded in an ARM function pointer's low bit.
/// This is metadata only; this model never branches to the target.
public enum RE4CXXFunctionPointerState: String, Equatable {
    case arm = "ARM"
    case thumb = "Thumb"
}

/// A callback record returned by the synthetic __cxa_finalize planner.
/// functionPointerRaw is preserved exactly as registered, including bit 0.
public struct RE4CXXDestructorCallPlan: Equatable {
    public let registrationID: UInt64
    public let functionPointerRaw: UInt32
    public let functionAddress: UInt32
    public let functionState: RE4CXXFunctionPointerState
    public let argument: UInt32
    public let dsoHandle: UInt32
}

public struct RE4CXXAtexitRegistrationResult: Equatable {
    /// ABI convention: zero means success; any non-zero value means failure.
    public let returnCode: Int32
    public let registrationID: UInt64?
}

public enum RE4CXXDestructorRegistryError: Error, LocalizedError {
    case invalidCompletionSet
    case registrationNotClaimed(UInt64)
    case counterOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidCompletionSet:
            return "The completion set contains duplicate or unknown registration IDs."
        case .registrationNotClaimed(let id):
            return "Destructor registration \(id) was not claimed for finalization."
        case .counterOverflow:
            return "The synthetic destructor registry sequence counter overflowed."
        }
    }
}

/// A non-executing model of the Itanium-style __cxa_atexit / __cxa_finalize contract.
/// It stores callback addresses as data and returns call plans; it never calls a callback.
/// This is deliberately single-threaded and is not a production runtime registry.
public struct RE4CXXDestructorRegistry {
    public enum EntryState: String, Equatable {
        case pending
        case claimed
        case completed
    }

    private struct Entry {
        let id: UInt64
        let functionPointerRaw: UInt32
        let argument: UInt32
        let dsoHandle: UInt32
        var state: EntryState
    }

    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    public let capacity: Int

    public init(capacity: Int = Int.max) {
        self.capacity = max(0, capacity)
    }

    public var registrationCount: Int { entries.count }
    public var pendingCount: Int { entries.filter { $0.state == .pending }.count }
    public var claimedCount: Int { entries.filter { $0.state == .claimed }.count }
    public var completedCount: Int { entries.filter { $0.state == .completed }.count }

    /// Records a callback without invoking it. A null function pointer and a full
    /// registry are modeled as registration failures. The specific failure code (1)
    /// is a model choice; the ABI only requires a non-zero failure result.
    public mutating func register(functionPointer: UInt32,
                                  argument: UInt32,
                                  dsoHandle: UInt32) throws -> RE4CXXAtexitRegistrationResult {
        guard functionPointer != 0, entries.count < capacity else {
            return RE4CXXAtexitRegistrationResult(returnCode: 1, registrationID: nil)
        }
        guard nextID < UInt64.max else { throw RE4CXXDestructorRegistryError.counterOverflow }
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, functionPointerRaw: functionPointer,
                             argument: argument, dsoHandle: dsoHandle, state: .pending))
        return RE4CXXAtexitRegistrationResult(returnCode: 0, registrationID: id)
    }

    /// Preview only: returns pending callbacks in reverse registration order.
    /// nil means all DSO handles; .some(0) means only the null DSO handle.
    public func makeFinalizePlan(dsoHandle: UInt32? = nil) -> [RE4CXXDestructorCallPlan] {
        entries.reversed().compactMap { entry in
            guard entry.state == .pending,
                  dsoHandle == nil || entry.dsoHandle == dsoHandle else { return nil }
            return Self.makePlan(entry)
        }
    }

    /// Claims a point-in-time reverse-order plan before callbacks would be invoked.
    /// Claiming prevents a nested/repeated finalize from scheduling the same record twice.
    /// The caller must later call markCompleted after its external test harness reports
    /// that the callbacks have returned. This type itself never invokes them.
    public mutating func claimFinalizePlan(dsoHandle: UInt32? = nil) -> [RE4CXXDestructorCallPlan] {
        var claimed: [RE4CXXDestructorCallPlan] = []
        for index in entries.indices.reversed() {
            guard entries[index].state == .pending,
                  dsoHandle == nil || entries[index].dsoHandle == dsoHandle else { continue }
            entries[index].state = .claimed
            claimed.append(Self.makePlan(entries[index]))
        }
        return claimed
    }

    /// Marks already-claimed records complete. No function pointer is called here.
    public mutating func markCompleted(registrationIDs: [UInt64]) throws {
        let unique = Set(registrationIDs)
        guard unique.count == registrationIDs.count else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        for id in registrationIDs {
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw RE4CXXDestructorRegistryError.invalidCompletionSet
            }
            guard entries[index].state == .claimed else {
                throw RE4CXXDestructorRegistryError.registrationNotClaimed(id)
            }
        }
        for id in registrationIDs {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].state = .completed
            }
        }
    }

    public func state(of registrationID: UInt64) -> EntryState? {
        entries.first(where: { $0.id == registrationID })?.state
    }

    private static func makePlan(_ entry: Entry) -> RE4CXXDestructorCallPlan {
        let thumb = entry.functionPointerRaw & 1 != 0
        let state: RE4CXXFunctionPointerState = thumb ? .thumb : .arm
        let address = thumb
            ? (entry.functionPointerRaw & ~UInt32(1))
            : (entry.functionPointerRaw & ~UInt32(3))
        return RE4CXXDestructorCallPlan(
            registrationID: entry.id,
            functionPointerRaw: entry.functionPointerRaw,
            functionAddress: address,
            functionState: state,
            argument: entry.argument,
            dsoHandle: entry.dsoHandle
        )
    }

    /// Synthetic conformance checks. The plans are inspected as data; no callback runs.
    public static func runSyntheticSelfTest() throws -> String {
        var registry = RE4CXXDestructorRegistry(capacity: 4)
        let a = try registry.register(functionPointer: 0x0019E8F4, argument: 0,
                                      dsoHandle: 0x00001000)
        let b = try registry.register(functionPointer: 0x35E0AFE9, argument: 0xBEEF,
                                      dsoHandle: 0x00001000)
        let c = try registry.register(functionPointer: 0x00002000, argument: 0xCCCC,
                                      dsoHandle: 0x00002000)
        let d = try registry.register(functionPointer: 0x00003000, argument: 0xDDDD,
                                      dsoHandle: 0)
        guard [a, b, c, d].allSatisfy({ $0.returnCode == 0 && $0.registrationID != nil }) else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let aid = a.registrationID!, bid = b.registrationID!
        let cid = c.registrationID!, did = d.registrationID!

        let dsoPreview = registry.makeFinalizePlan(dsoHandle: 0x00001000)
        guard dsoPreview.map(\.registrationID) == [bid, aid],
              dsoPreview[0].functionPointerRaw == 0x35E0AFE9,
              dsoPreview[0].functionAddress == 0x35E0AFE8,
              dsoPreview[0].functionState == .thumb,
              dsoPreview[0].argument == 0xBEEF,
              dsoPreview[0].dsoHandle == 0x00001000,
              dsoPreview[1].functionState == .arm else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }

        let claimedDSO = registry.claimFinalizePlan(dsoHandle: 0x00001000)
        guard claimedDSO.map(\.registrationID) == [bid, aid],
              registry.claimFinalizePlan(dsoHandle: 0x00001000).isEmpty else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        try registry.markCompleted(registrationIDs: [bid, aid])
        guard registry.makeFinalizePlan(dsoHandle: 0x00001000).isEmpty else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }

        // A null DSO handle is distinct from the nil/all-DSOs selector.
        let nullDSO = registry.claimFinalizePlan(dsoHandle: 0)
        guard nullDSO.map(\.registrationID) == [did] else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        try registry.markCompleted(registrationIDs: [did])

        let remaining = registry.claimFinalizePlan(dsoHandle: nil)
        guard remaining.map(\.registrationID) == [cid] else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        try registry.markCompleted(registrationIDs: [cid])
        guard registry.claimFinalizePlan(dsoHandle: nil).isEmpty,
              registry.completedCount == 4 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }

        let full = try registry.register(functionPointer: 0x4000, argument: 0, dsoHandle: 0)
        guard full.returnCode != 0, full.registrationID == nil,
              registry.registrationCount == 4 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        return "C++ __cxa_atexit registry model self-test PASS\n" +
            "Registration result convention (0 success / non-zero failure): PASS\n" +
            "Reverse registration order and DSO-specific finalization: PASS\n" +
            "Null DSO handle distinct from finalize-all selector: PASS\n" +
            "Repeated/nested finalize does not re-claim pending records: PASS\n" +
            "ARM/Thumb raw callback pointer preservation: PASS\n" +
            "No callback was invoked; registry contains metadata only."
    }
}

/// Reference state machine for the historical libstdc++ ios_base::Init implementation
/// documented by GCC 3.4 ios_init.cc. It records conceptual side effects only and does
/// not construct streams, touch stdio, flush host output, or call Guest provider code.
/// The exact iOS 4.2.1 libstdc++.6.dylib implementation still requires binary confirmation.
public struct RE4LibstdcxxIOSBaseInitModel {
    public enum Event: Equatable {
        case synchronizedWithStdioEnabled
        case narrowStandardStreamsConstructed
        case wideStandardStreamsConstructed
        case standardStreamsFlushed
    }

    public let wideStreamsEnabledInReferenceProfile: Bool
    public private(set) var referenceCount: Int = 0
    public private(set) var activeInstances: Int = 0
    public private(set) var standardStreamsInitialized = false
    public private(set) var synchronizedWithStdio = false
    public private(set) var flushCount = 0

    public init(wideStreamsEnabledInReferenceProfile: Bool) {
        self.wideStreamsEnabledInReferenceProfile = wideStreamsEnabledInReferenceProfile
    }

    /// Models the GCC reference algorithm: increment the refcount; on 0 -> 1,
    /// initialize standard streams and add one permanent sentinel reference.
    public mutating func constructInstance() throws -> [Event] {
        guard referenceCount < Int.max - 1, activeInstances < Int.max else {
            throw RE4CXXDestructorRegistryError.counterOverflow
        }
        let oldCount = referenceCount
        referenceCount += 1
        activeInstances += 1
        guard oldCount == 0 else { return [] }

        synchronizedWithStdio = true
        standardStreamsInitialized = true
        referenceCount += 1 // sentinel: streams are never destroyed by Init::~Init
        var events: [Event] = [
            .synchronizedWithStdioEnabled,
            .narrowStandardStreamsConstructed
        ]
        if wideStreamsEnabledInReferenceProfile {
            events.append(.wideStandardStreamsConstructed)
        }
        return events
    }

    /// Models the destructor's old-refcount == 2 flush condition. It never destroys
    /// std::cin/cout/cerr/clog or their backing stream objects.
    public mutating func destroyInstance() throws -> [Event] {
        guard activeInstances > 0, referenceCount > 1 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let oldCount = referenceCount
        referenceCount -= 1
        activeInstances -= 1
        guard oldCount == 2 else { return [] }
        flushCount += 1
        return [.standardStreamsFlushed]
    }

    public static func runSyntheticSelfTest() throws -> String {
        var model = RE4LibstdcxxIOSBaseInitModel(wideStreamsEnabledInReferenceProfile: true)
        let first = try model.constructInstance()
        guard first == [
            .synchronizedWithStdioEnabled,
            .narrowStandardStreamsConstructed,
            .wideStandardStreamsConstructed
        ], model.referenceCount == 2, model.activeInstances == 1,
           model.standardStreamsInitialized, model.synchronizedWithStdio else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let second = try model.constructInstance()
        guard second.isEmpty, model.referenceCount == 3, model.activeInstances == 2 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let firstDestroy = try model.destroyInstance()
        guard firstDestroy.isEmpty, model.referenceCount == 2 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let lastDestroy = try model.destroyInstance()
        guard lastDestroy == [.standardStreamsFlushed],
              model.referenceCount == 1, model.activeInstances == 0,
              model.flushCount == 1, model.standardStreamsInitialized else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let laterInstance = try model.constructInstance()
        guard laterInstance.isEmpty, model.referenceCount == 2,
              model.standardStreamsInitialized else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        let laterDestroy = try model.destroyInstance()
        guard laterDestroy == [.standardStreamsFlushed],
              model.referenceCount == 1, model.flushCount == 2 else {
            throw RE4CXXDestructorRegistryError.invalidCompletionSet
        }
        return "libstdc++ ios_base::Init reference-state model self-test PASS\n" +
            "First construction initializes standard streams once and adds sentinel ref: PASS\n" +
            "Additional Init instances share the initialized streams: PASS\n" +
            "Last live instance flushes; standard stream objects remain alive: PASS\n" +
            "Wide-stream events are gated by an explicit profile flag: PASS\n" +
            "Conceptual events only; no stdio or Guest provider function was called."
    }
}
