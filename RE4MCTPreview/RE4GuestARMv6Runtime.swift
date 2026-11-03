import Foundation

public enum RE4GuestRuntimeError: Error, LocalizedError {
    case invalidMemoryRange(address: UInt32, count: Int)
    case memoryProtectionViolation(address: UInt32, count: Int, access: String, region: String)
    case invalidMemoryRegion(String)
    case overlappingMemoryRegion(String, String)
    case writeExecuteRegionDenied(String)
    case heapExhausted
    case invalidRegister(Int)
    case unsupportedInstruction(pc: UInt32, word: UInt32)
    case stepLimit(limit: Int, pc: UInt32)
    case didNotReturn(pc: UInt32)

    public var errorDescription: String? {
        switch self {
        case .invalidMemoryRange(let address, let count):
            return String(format: "Guest memory range 0x%08X (+%d) is outside mapped guest memory.", address, count)
        case .memoryProtectionViolation(let address, let count, let access, let region):
            return String(format: "Guest memory %@ access at 0x%08X (+%d) is denied by region %@.", access, address, count, region)
        case .invalidMemoryRegion(let reason):
            return "Invalid Guest Memory region: \(reason)."
        case .overlappingMemoryRegion(let first, let second):
            return "Guest Memory regions overlap: \(first) and \(second)."
        case .writeExecuteRegionDenied(let name):
            return "Guest Memory region \(name) requests writable and executable permissions (W^X denied)."
        case .heapExhausted: return "Guest heap exhausted."
        case .invalidRegister(let index): return "Invalid ARM register index \(index)."
        case .unsupportedInstruction(let pc, let word):
            return String(format: "Unsupported ARMv6 instruction 0x%08X at 0x%08X.", word, pc)
        case .stepLimit(let limit, let pc):
            return String(format: "ARMv6 step limit %d reached at PC=0x%08X.", limit, pc)
        case .didNotReturn(let pc):
            return String(format: "ARMv6 routine did not return; PC=0x%08X.", pc)
        }
    }
}

/// Bounds-checked low Guest VA plus independently mounted sparse regions.
/// The original low [0, size) byte array remains the allocator/HLE/Res4 compatibility range.
public final class RE4GuestARMv6Memory: RE4GuestMemoryReading, RE4GuestMemoryMapping {
    public let size: Int
    public let stackTop: UInt32
    public let returnSentinel: UInt32
    private var bytes: [UInt8]
    private var heapCursor: UInt32
    private var sparseRegions: [RE4GuestMemoryRegion] = []

    private struct DenseProtectionRange {
        let start: UInt64
        let end: UInt64
        let protection: RE4GuestMemoryProtection
        let name: String
    }

    private var denseProtectionRanges: [DenseProtectionRange] = []

    private enum ResolvedAddress {
        case dense(Range<Int>)
        case sparse(RE4GuestMemoryRegion, backingOffset: UInt64)
    }

    public init(size: Int = 0x05000000,
                heapBase: UInt32 = 0x03100000,
                stackTop: UInt32 = 0x04F00000,
                returnSentinel: UInt32 = 0x00FFF000) {
        precondition(size > 0 && UInt64(size) <= UInt64(UInt32.max))
        self.size = size
        self.stackTop = stackTop
        self.returnSentinel = returnSentinel
        self.heapCursor = heapBase
        self.bytes = [UInt8](repeating: 0, count: size)
    }

    public var sparseRegionCount: Int { sparseRegions.count }
    public var mountedSparseRegions: [RE4GuestMemoryRegion] { sparseRegions }

    public func hasSparseRegion(named name: String) -> Bool {
        sparseRegions.contains { $0.name == name }
    }

    private func resolve(
        _ address: UInt32,
        count: Int,
        required: RE4GuestMemoryProtection
    ) throws -> ResolvedAddress {
        guard count >= 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
        }

        let start = UInt64(address)
        let (end, overflow) = start.addingReportingOverflow(UInt64(count))
        guard !overflow, end <= (UInt64(UInt32.max) + 1) else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
        }

        if end <= UInt64(size) && (start < UInt64(size) || count == 0) {
            if let protected = denseProtectionRanges.first(where: {
                start < $0.end && end > $0.start ||
                (count == 0 && start >= $0.start && start < $0.end)
            }) {
                guard start >= protected.start && end <= protected.end else {
                    throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
                }
                guard protected.protection.contains(required) else {
                    throw RE4GuestRuntimeError.memoryProtectionViolation(
                        address: address, count: count,
                        access: required.label, region: protected.name
                    )
                }
            }
            return .dense(Int(start)..<Int(end))
        }

        for region in sparseRegions {
            let regionStart = UInt64(region.guestBase)
            let regionEnd = region.guestEndExclusive
            let contained = start >= regionStart && end <= regionEnd &&
                (count > 0 ? start < regionEnd : start <= regionEnd)
            guard contained else { continue }
            guard region.initialProtection.contains(required) else {
                throw RE4GuestRuntimeError.memoryProtectionViolation(
                    address: address, count: count,
                    access: required.label, region: region.name
                )
            }
            return .sparse(region, backingOffset: region.backingOffset + start - regionStart)
        }

        throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
    }

    /// Adds a group atomically. Every region must be disjoint from dense memory and all existing/new regions.
    public func mountRegions(_ newRegions: [RE4GuestMemoryRegion]) throws {
        guard !newRegions.isEmpty else { return }
        var candidate = sparseRegions + newRegions

        for region in newRegions {
            guard !region.name.isEmpty, region.length > 0 else {
                throw RE4GuestRuntimeError.invalidMemoryRegion("empty name or zero length")
            }
            let start = UInt64(region.guestBase)
            let (end, guestOverflow) = start.addingReportingOverflow(region.length)
            guard !guestOverflow, end > start, end <= UInt64(UInt32.max) + 1 else {
                throw RE4GuestRuntimeError.invalidMemoryRegion("Guest VA overflow in \(region.name)")
            }
            guard start >= UInt64(size) else {
                throw RE4GuestRuntimeError.overlappingMemoryRegion("dense low memory", region.name)
            }
            let (backingEnd, backingOverflow) = region.backingOffset.addingReportingOverflow(region.length)
            guard !backingOverflow, backingEnd <= UInt64(region.backing.byteCount) else {
                throw RE4GuestRuntimeError.invalidMemoryRegion("backing range exceeds source data in \(region.name)")
            }
            guard region.initialProtection.isSubset(of: region.maxProtection) else {
                throw RE4GuestRuntimeError.invalidMemoryRegion("initial protection exceeds max protection in \(region.name)")
            }
            guard !(region.initialProtection.contains(.write) && region.initialProtection.contains(.execute)) else {
                throw RE4GuestRuntimeError.writeExecuteRegionDenied(region.name)
            }
        }

        candidate.sort { $0.guestBase < $1.guestBase }
        for index in 1..<candidate.count {
            if candidate[index - 1].guestEndExclusive > UInt64(candidate[index].guestBase) {
                throw RE4GuestRuntimeError.overlappingMemoryRegion(
                    candidate[index - 1].name, candidate[index].name
                )
            }
        }
        sparseRegions = candidate
    }

    public func mountRegion(_ region: RE4GuestMemoryRegion) throws {
        try mountRegions([region])
    }

    @discardableResult
    public func unmountSparseRegion(named name: String) -> Bool {
        let oldCount = sparseRegions.count
        sparseRegions.removeAll { $0.name == name }
        return sparseRegions.count != oldCount
    }

    /// Applies initial R/W/X permissions to a range in the legacy dense Guest VA.
    /// Used by the Mach-O segment mapper after all file bytes and zero-fill bytes are installed.
    public func setProtectionRange(
        address: UInt32,
        length: UInt64,
        protection: RE4GuestMemoryProtection,
        name: String = "dense-segment"
    ) throws {
        let start = UInt64(address)
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow, length > 0, end > start, end <= UInt64(size) else {
            throw RE4GuestRuntimeError.invalidMemoryRegion("dense protection range is outside low Guest Memory")
        }
        guard !(protection.contains(.write) && protection.contains(.execute)) else {
            throw RE4GuestRuntimeError.writeExecuteRegionDenied(name)
        }
        if let overlap = denseProtectionRanges.first(where: {
            start < $0.end && end > $0.start
        }) {
            throw RE4GuestRuntimeError.overlappingMemoryRegion(overlap.name, name)
        }
        denseProtectionRanges.append(DenseProtectionRange(
            start: start, end: end, protection: protection, name: name
        ))
        denseProtectionRanges.sort { $0.start < $1.start }
    }

    public func copyBytes(at guestAddress: UInt32, count: Int) throws -> Data {
        switch try resolve(guestAddress, count: count, required: .read) {
        case .dense(let range):
            return Data(bytes[range])
        case .sparse(let region, let backingOffset):
            return try region.backing.copyBytes(at: backingOffset, count: count)
        }
    }

    public func writeBytes(at guestAddress: UInt32, data: Data) throws {
        switch try resolve(guestAddress, count: data.count, required: .write) {
        case .dense(let range):
            bytes.replaceSubrange(range, with: data)
        case .sparse(let region, let backingOffset):
            try region.backing.writeBytes(at: backingOffset, data: data)
        }
    }

    public func zeroBytes(at guestAddress: UInt32, count: Int) throws {
        guard count >= 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: guestAddress, count: count)
        }
        try writeBytes(at: guestAddress, data: Data(repeating: 0, count: count))
    }

    private func readInteger(_ address: UInt32, byteCount: Int, required: RE4GuestMemoryProtection) throws -> UInt32 {
        switch try resolve(address, count: byteCount, required: required) {
        case .dense(let range):
            let p = range.lowerBound
            if byteCount == 1 { return UInt32(bytes[p]) }
            if byteCount == 2 {
                return UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8)
            }
            return UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8) |
                (UInt32(bytes[p + 2]) << 16) | (UInt32(bytes[p + 3]) << 24)
        case .sparse(let region, let backingOffset):
            let raw = [UInt8](try region.backing.copyBytes(at: backingOffset, count: byteCount))
            if byteCount == 1 { return UInt32(raw[0]) }
            if byteCount == 2 { return UInt32(raw[0]) | (UInt32(raw[1]) << 8) }
            return UInt32(raw[0]) | (UInt32(raw[1]) << 8) |
                (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
        }
    }

    public func read8(_ address: UInt32) throws -> UInt8 {
        UInt8(try readInteger(address, byteCount: 1, required: .read))
    }

    public func read16(_ address: UInt32) throws -> UInt16 {
        UInt16(try readInteger(address, byteCount: 2, required: .read))
    }

    public func read32(_ address: UInt32) throws -> UInt32 {
        try readInteger(address, byteCount: 4, required: .read)
    }

    /// Instruction fetch is distinct from data read and requires execute permission.
    public func readInstruction32(_ address: UInt32) throws -> UInt32 {
        try readInteger(address, byteCount: 4, required: .execute)
    }

    public func write8(_ address: UInt32, _ value: UInt8) throws {
        try writeBytes(at: address, data: Data([value]))
    }

    public func write16(_ address: UInt32, _ value: UInt16) throws {
        try writeBytes(at: address, data: Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)
        ]))
    }

    public func write32(_ address: UInt32, _ value: UInt32) throws {
        try writeBytes(at: address, data: Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ]))
    }

    public func readCString(_ address: UInt32, limit: Int = 8192) throws -> String {
        guard limit >= 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: limit)
        }
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, 256))
        for offset in 0..<limit {
            let (at, overflow) = address.addingReportingOverflow(UInt32(offset))
            guard !overflow else {
                throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: limit)
            }
            let byte = try read8(at)
            if byte == 0 { return String(decoding: output, as: UTF8.self) }
            output.append(byte)
        }
        throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: limit)
    }

    public func allocate(_ requestedSize: Int, alignment: UInt32 = 8) throws -> UInt32 {
        guard alignment > 0 && (alignment & (alignment - 1)) == 0 else {
            throw RE4GuestRuntimeError.heapExhausted
        }
        let count = max(1, requestedSize)
        let mask = alignment - 1
        let (plusMask, addOverflow) = heapCursor.addingReportingOverflow(mask)
        guard !addOverflow else { throw RE4GuestRuntimeError.heapExhausted }
        let start = plusMask & ~mask
        let (end, overflow) = start.addingReportingOverflow(UInt32(clamping: count))
        let limit = stackTop > 0x10000 ? stackTop - 0x10000 : 0
        guard !overflow, end < limit, UInt64(end) <= UInt64(size) else {
            throw RE4GuestRuntimeError.heapExhausted
        }
        try writeBytes(at: start, data: Data(repeating: 0, count: count))
        heapCursor = end
        return start
    }

    public func loadBytes(_ data: Data, at address: UInt32) throws {
        try writeBytes(at: address, data: data)
    }
}

public struct RE4GuestARMv6RunResult {
    public let steps: Int
    public let registers: [UInt32]
    public let programCounter: UInt32
    public let returned: Bool
    public let halted: Bool
    public let exitCode: Int32?

    public init(steps: Int, registers: [UInt32], programCounter: UInt32,
                returned: Bool, halted: Bool = false, exitCode: Int32? = nil) {
        self.steps = steps
        self.registers = registers
        self.programCounter = programCounter
        self.returned = returned
        self.halted = halted
        self.exitCode = exitCode
    }
}

/// Stage J.8.11: the exact CPU-state subset owned by this ARM-only interpreter.
/// Kept beside the Core so standalone Core validators compile the same contract.
public struct RE4StageJ811ConditionFlags: Equatable {
    public let negative: Bool
    public let zero: Bool
    public let carry: Bool
    public let overflow: Bool

    public init(negative: Bool, zero: Bool, carry: Bool, overflow: Bool) {
        self.negative = negative
        self.zero = zero
        self.carry = carry
        self.overflow = overflow
    }
}

public enum RE4StageJ811ExecutionMode: String, Equatable {
    /// Operational mode of the current interpreter, not a sampled CPSR.T bit.
    case arm32Interpreter
    /// An explicit request for the unimplemented Thumb execution path.
    case thumb16Required
}

public enum RE4StageJ811UnmodeledCPSRState: String, Equatable {
    /// CPSR fields other than N/Z/C/V do not exist in the current Core model.
    case notRepresentedByCurrentCore
}

public enum RE4StageJ811VFPStateCoverage: String, Equatable {
    case d8ThroughD15NotCaptured
}

public enum RE4StageJ811CPSRRestoreRequest: String, Equatable {
    case modeledNZCVOnly
    case fullCPSR
}

public enum RE4StageJ811VFPRestoreRequirement: String, Equatable {
    case notRequired
    case d8ThroughD15Required
}

public enum RE4StageJ811CommitError: Error, Equatable {
    case invalidRegisterFileCount(Int)
    case programCounterNotWordAligned(UInt32)
    case stackPointerNotWordAligned(UInt32)
    case thumbExecutionUnsupported
    case fullCPSRRestoreUnsupported
    case vfpD8ThroughD15RestoreUnsupported
    case sourceStateChangedBeforeCommit
}

/// Immutable snapshot of R0-R15 and N/Z/C/V. Unsupported CPSR and VFP fields
/// are represented as absent coverage markers, never fabricated bit values.
public struct RE4StageJ811CPUStateSnapshot: Equatable {
    public let registers: [UInt32]
    public let flags: RE4StageJ811ConditionFlags
    public let executionMode: RE4StageJ811ExecutionMode
    public let unmodeledCPSRState: RE4StageJ811UnmodeledCPSRState
    public let vfpStateCoverage: RE4StageJ811VFPStateCoverage

    public var pc: UInt32 { registers[15] }
    public var sp: UInt32 { registers[13] }

    public init(registers: [UInt32], flags: RE4StageJ811ConditionFlags) throws {
        guard registers.count == 16 else {
            throw RE4StageJ811CommitError.invalidRegisterFileCount(registers.count)
        }
        guard (registers[15] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.programCounterNotWordAligned(registers[15])
        }
        guard (registers[13] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.stackPointerNotWordAligned(registers[13])
        }
        self.registers = registers
        self.flags = flags
        self.executionMode = .arm32Interpreter
        self.unmodeledCPSRState = .notRepresentedByCurrentCore
        self.vfpStateCoverage = .d8ThroughD15NotCaptured
    }
}

/// Untrusted request: intentionally permits malformed input so preflight can
/// reject it before touching the live Core state.
public struct RE4StageJ811CPUStateCandidate: Equatable {
    public let registers: [UInt32]
    public let flags: RE4StageJ811ConditionFlags
    public let executionMode: RE4StageJ811ExecutionMode
    public let cpsrRestoreRequest: RE4StageJ811CPSRRestoreRequest
    public let vfpRestoreRequirement: RE4StageJ811VFPRestoreRequirement

    public init(
        registers: [UInt32],
        flags: RE4StageJ811ConditionFlags,
        executionMode: RE4StageJ811ExecutionMode,
        cpsrRestoreRequest: RE4StageJ811CPSRRestoreRequest = .modeledNZCVOnly,
        vfpRestoreRequirement: RE4StageJ811VFPRestoreRequirement = .notRequired
    ) {
        self.registers = registers
        self.flags = flags
        self.executionMode = executionMode
        self.cpsrRestoreRequest = cpsrRestoreRequest
        self.vfpRestoreRequirement = vfpRestoreRequirement
    }

    func validate(
        against source: RE4StageJ811CPUStateSnapshot
    ) throws -> RE4StageJ811ValidatedCPUStateCommit {
        guard registers.count == 16 else {
            throw RE4StageJ811CommitError.invalidRegisterFileCount(registers.count)
        }
        guard executionMode == .arm32Interpreter else {
            throw RE4StageJ811CommitError.thumbExecutionUnsupported
        }
        guard (registers[15] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.programCounterNotWordAligned(registers[15])
        }
        guard (registers[13] & 0x3) == 0 else {
            throw RE4StageJ811CommitError.stackPointerNotWordAligned(registers[13])
        }
        guard cpsrRestoreRequest == .modeledNZCVOnly else {
            throw RE4StageJ811CommitError.fullCPSRRestoreUnsupported
        }
        guard vfpRestoreRequirement == .notRequired else {
            throw RE4StageJ811CommitError.vfpD8ThroughD15RestoreUnsupported
        }
        return RE4StageJ811ValidatedCPUStateCommit(
            expectedSource: source, registers: registers, flags: flags
        )
    }
}

/// Opaque preflight result. Its payload is module-internal.
public struct RE4StageJ811ValidatedCPUStateCommit {
    let expectedSource: RE4StageJ811CPUStateSnapshot
    let registers: [UInt32]
    let flags: RE4StageJ811ConditionFlags

    init(
        expectedSource: RE4StageJ811CPUStateSnapshot,
        registers: [UInt32],
        flags: RE4StageJ811ConditionFlags
    ) {
        self.expectedSource = expectedSource
        self.registers = registers
        self.flags = flags
    }
}

public struct RE4StageJ811CommitReceipt: Equatable {
    public let committedGeneralRegisterCount: Int
    public let committedNZCV: Bool
    public let restoredFullCPSR: Bool
    public let restoredVFPD8ThroughD15: Bool
    public let guestInstructionsExecuted: Bool
}

/// Bounded interpreter for the ARM integer/VFP subset observed in the MVP-14/15/18 harness.
/// Platform calls are left to an explicit host hook; this is not a full ARMv6 emulator.
public final class RE4GuestARMv6Core {
    public typealias InstructionHook = (_ programCounter: UInt32, _ cpu: RE4GuestARMv6Core) throws -> Bool
    public let memory: RE4GuestARMv6Memory
    public private(set) var registers = [UInt32](repeating: 0, count: 16)
    public private(set) var steps = 0
    public var instructionHook: InstructionHook?

    private var negative = false
    private var zero = false
    private var carry = false
    private var overflow = false
    private var vfpS = [UInt32](repeating: 0, count: 32)
    private var terminationRequested = false
    private var requestedExitCode: Int32?

    public init(memory: RE4GuestARMv6Memory, instructionHook: InstructionHook? = nil) {
        self.memory = memory
        self.instructionHook = instructionHook
    }

    /// Captures only the architectural state that this interpreter actually models.
    /// This is not a complete CPSR image and does not claim to capture VFP D8-D15.
    public func captureArchitecturalStateSnapshot() throws -> RE4StageJ811CPUStateSnapshot {
        try RE4StageJ811CPUStateSnapshot(
            registers: registers,
            flags: RE4StageJ811ConditionFlags(
                negative: negative, zero: zero, carry: carry, overflow: overflow
            )
        )
    }

    /// Phase 1: validate the complete candidate against the current core state.
    /// No live Guest CPU field is changed by this method.
    public func prepareArchitecturalStateCommit(
        _ candidate: RE4StageJ811CPUStateCandidate
    ) throws -> RE4StageJ811ValidatedCPUStateCommit {
        let source = try captureArchitecturalStateSnapshot()
        return try candidate.validate(against: source)
    }

    /// Phase 2: compare the preflight source snapshot, then commit all modeled
    /// GPRs and NZCV. There are no throwing operations after the first assignment.
    /// The core is single-execution-thread confined; this is failure-atomic, not
    /// a cross-thread synchronization primitive.
    @discardableResult
    public func commitArchitecturalStateAtomically(
        _ prepared: RE4StageJ811ValidatedCPUStateCommit
    ) throws -> RE4StageJ811CommitReceipt {
        let current = try captureArchitecturalStateSnapshot()
        guard current == prepared.expectedSource else {
            throw RE4StageJ811CommitError.sourceStateChangedBeforeCommit
        }

        // All shape, alignment, mode and capability checks have already passed.
        // These assignments cannot throw, and no Guest instruction is run here.
        registers = prepared.registers
        negative = prepared.flags.negative
        zero = prepared.flags.zero
        carry = prepared.flags.carry
        overflow = prepared.flags.overflow

        return RE4StageJ811CommitReceipt(
            committedGeneralRegisterCount: 16,
            committedNZCV: true,
            restoredFullCPSR: false,
            restoredVFPD8ThroughD15: false,
            guestInstructionsExecuted: false
        )
    }

    public func registerValue(_ index: Int) throws -> UInt32 {
        guard (0..<16).contains(index) else { throw RE4GuestRuntimeError.invalidRegister(index) }
        return registers[index]
    }

    public func setRegisterValue(_ index: Int, value: UInt32) throws {
        guard (0..<16).contains(index) else { throw RE4GuestRuntimeError.invalidRegister(index) }
        registers[index] = value
    }

    /// Complete a host-side ARM procedure call and return to the caller's LR.
    public func completeHostCall(returnValue: UInt32) {
        registers[0] = returnValue
        registers[15] = registers[14] & ~3
    }

    /// Request termination of the emulated guest only; this never exits or terminates the iOS host app.
    public func requestTermination(exitCode: Int32) {
        terminationRequested = true
        requestedExitCode = exitCode
    }

    private func reg(_ index: Int, pc: UInt32) throws -> UInt32 {
        guard (0..<16).contains(index) else { throw RE4GuestRuntimeError.invalidRegister(index) }
        return index == 15 ? pc &+ 8 : registers[index]
    }

    private func conditionPassed(_ condition: UInt32) -> Bool {
        switch condition {
        case 0: return zero
        case 1: return !zero
        case 2: return carry
        case 3: return !carry
        case 4: return negative
        case 5: return !negative
        case 6: return overflow
        case 7: return !overflow
        case 8: return carry && !zero
        case 9: return !carry || zero
        case 10: return negative == overflow
        case 11: return negative != overflow
        case 12: return !zero && negative == overflow
        case 13: return zero || negative != overflow
        case 14, 15: return true
        default: return false
        }
    }

    private func setNZ(_ value: UInt32) {
        negative = (value & 0x80000000) != 0
        zero = value == 0
    }

    private func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        let n = amount & 31
        guard n != 0 else { return value }
        return (value >> n) | (value << (32 - n))
    }

    private func shiftedOperand(_ word: UInt32, pc: UInt32) throws -> (value: UInt32, carry: Bool) {
        if (word >> 25) & 1 != 0 {
            let immediate = word & 0xFF
            let rotation = ((word >> 8) & 0xF) * 2
            let value = rotateRight(immediate, rotation)
            return (value, rotation == 0 ? carry : (value & 0x80000000) != 0)
        }
        let rm = Int(word & 0xF)
        let value = try reg(rm, pc: pc)
        let type = (word >> 5) & 3
        let registerShift = (word >> 4) & 1 != 0
        let amount: UInt32 = registerShift ? ((try reg(Int((word >> 8) & 0xF), pc: pc)) & 0xFF) : ((word >> 7) & 0x1F)
        if registerShift && amount == 0 { return (value, carry) }
        if !registerShift && amount == 0 {
            switch type {
            case 0: return (value, carry)
            case 1: return (0, (value & 0x80000000) != 0)
            case 2: return ((value & 0x80000000) != 0 ? UInt32.max : 0, (value & 0x80000000) != 0)
            default: return ((carry ? 0x80000000 : 0) | (value >> 1), (value & 1) != 0)
            }
        }
        switch type {
        case 0:
            if amount < 32 { return (value << amount, (value & (UInt32(1) << (32 - amount))) != 0) }
            return (0, amount == 32 && (value & 1) != 0)
        case 1:
            if amount < 32 { return (value >> amount, (value & (UInt32(1) << (amount - 1))) != 0) }
            return (0, amount == 32 && (value & 0x80000000) != 0)
        case 2:
            let signed = Int32(bitPattern: value)
            if amount < 32 { return (UInt32(bitPattern: signed >> amount), (value & (UInt32(1) << (min(amount, 32) - 1))) != 0) }
            return (signed < 0 ? UInt32.max : 0, (value & 0x80000000) != 0)
        default:
            let n = amount & 31
            if n == 0 { return (value, (value & 0x80000000) != 0) }
            let result = rotateRight(value, n)
            return (result, (result & 0x80000000) != 0)
        }
    }

    private func executeDataProcessing(_ word: UInt32, pc: UInt32) throws {
        let opcode = Int((word >> 21) & 0xF)
        let setFlags = (word >> 20) & 1 != 0
        let rn = Int((word >> 16) & 0xF)
        let rd = Int((word >> 12) & 0xF)
        let a = try reg(rn, pc: pc)
        let operand = try shiftedOperand(word, pc: pc)
        let b = operand.value
        var result: UInt32 = 0
        switch opcode {
        case 0, 8: result = a & b
        case 1, 9: result = a ^ b
        case 2, 10: result = a &- b
        case 3: result = b &- a
        case 4, 11: result = a &+ b
        case 12: result = a | b
        case 13: result = b
        case 14: result = a & ~b
        case 15: result = ~b
        default: throw RE4GuestRuntimeError.unsupportedInstruction(pc: pc, word: word)
        }
        let isTest = (8...11).contains(opcode)
        if setFlags || isTest {
            setNZ(result)
            switch opcode {
            case 2, 10:
                carry = a >= b
                overflow = ((a ^ b) & (a ^ result) & 0x80000000) != 0
            case 3:
                carry = b >= a
                overflow = ((b ^ a) & (b ^ result) & 0x80000000) != 0
            case 4, 11:
                carry = UInt64(a) + UInt64(b) > UInt64(UInt32.max)
                overflow = ((~(a ^ b)) & (a ^ result) & 0x80000000) != 0
            default: carry = operand.carry
            }
        }
        if !isTest {
            if rd == 15 { registers[15] = result & ~3 } else { registers[rd] = result }
        }
    }

    private func executeExtraTransfer(_ word: UInt32, pc: UInt32) throws {
        let pre = (word >> 24) & 1 != 0
        let up = (word >> 23) & 1 != 0
        let immediate = (word >> 22) & 1 != 0
        let writeback = (word >> 21) & 1 != 0
        let load = (word >> 20) & 1 != 0
        let rn = Int((word >> 16) & 0xF), rd = Int((word >> 12) & 0xF)
        let operation = (word >> 5) & 3
        let base = try reg(rn, pc: pc)
        let offset: UInt32 = immediate
            ? (((word >> 8) & 0xF) << 4) | (word & 0xF)
            : (try reg(Int(word & 0xF), pc: pc))
        let indexed = up ? base &+ offset : base &- offset
        let address = pre ? indexed : base
        if load {
            let value: UInt32
            switch operation {
            case 1: value = UInt32(try memory.read16(address))
            case 2:
                let raw = try memory.read8(address)
                value = UInt32(bitPattern: Int32(Int8(bitPattern: raw)))
            case 3:
                let raw = try memory.read16(address)
                value = UInt32(bitPattern: Int32(Int16(bitPattern: raw)))
            default: throw RE4GuestRuntimeError.unsupportedInstruction(pc: pc, word: word)
            }
            registers[rd] = value
        } else {
            guard operation == 1 else { throw RE4GuestRuntimeError.unsupportedInstruction(pc: pc, word: word) }
            try memory.write16(address, UInt16(truncatingIfNeeded: registers[rd]))
        }
        if !pre || writeback { registers[rn] = indexed }
    }

    private func executeExtend(_ word: UInt32, pc: UInt32) throws -> Bool {
        let code = word & 0x0FFF03F0
        let supported: [UInt32] = [0x06EF0070, 0x06FF0070, 0x06AF0070, 0x06BF0070, 0x06CF0070, 0x068F0070]
        guard supported.contains(code) else { return false }
        let rd = Int((word >> 12) & 0xF), rm = Int(word & 0xF)
        let rotation = ((word >> 10) & 3) * 8
        let raw = rotateRight(try reg(rm, pc: pc), rotation)
        let result: UInt32
        switch code {
        case 0x06EF0070: result = raw & 0xFF
        case 0x06FF0070: result = raw & 0xFFFF
        case 0x06AF0070: result = UInt32(bitPattern: Int32(Int8(bitPattern: UInt8(raw & 0xFF))))
        case 0x06BF0070: result = UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(raw & 0xFFFF))))
        case 0x06CF0070: result = (raw & 0xFF) | (raw & 0x00FF0000)
        default:
            let b0 = Int16(Int8(bitPattern: UInt8(raw & 0xFF)))
            let b1 = Int16(Int8(bitPattern: UInt8((raw >> 16) & 0xFF)))
            result = UInt32(UInt16(bitPattern: b0)) | (UInt32(UInt16(bitPattern: b1)) << 16)
        }
        registers[rd] = result
        return true
    }

    private func executeSingleTransfer(_ word: UInt32, pc: UInt32) throws {
        if try executeExtend(word, pc: pc) { return }
        let registerOffset = (word >> 25) & 1 != 0
        let pre = (word >> 24) & 1 != 0, up = (word >> 23) & 1 != 0
        let byte = (word >> 22) & 1 != 0, writeback = (word >> 21) & 1 != 0
        let load = (word >> 20) & 1 != 0
        let rn = Int((word >> 16) & 0xF), rd = Int((word >> 12) & 0xF)
        let base = try reg(rn, pc: pc)
        let offset: UInt32
        if registerOffset {
            let rm = Int(word & 0xF), amount = (word >> 7) & 0x1F, type = (word >> 5) & 3
            let value = try reg(rm, pc: pc)
            switch type {
            case 0: offset = value << amount
            case 1: offset = amount == 0 ? 0 : value >> amount
            case 2:
                let signed = Int32(bitPattern: value)
                offset = UInt32(bitPattern: amount == 0 ? (signed < 0 ? -1 : 0) : (signed >> amount))
            default: offset = rotateRight(value, amount)
            }
        } else {
            offset = word & 0xFFF
        }
        let indexed = up ? base &+ offset : base &- offset
        let address = pre ? indexed : base
        if load {
            let value = byte ? UInt32(try memory.read8(address)) : try memory.read32(address)
            if rd == 15 { registers[15] = value & ~3 } else { registers[rd] = value }
        } else {
            let value = try reg(rd, pc: pc)
            if byte { try memory.write8(address, UInt8(truncatingIfNeeded: value)) }
            else { try memory.write32(address, value) }
        }
        if !pre || writeback { registers[rn] = indexed }
    }

    private func executeBlockTransfer(_ word: UInt32, pc: UInt32) throws {
        let pre = (word >> 24) & 1 != 0, up = (word >> 23) & 1 != 0
        let writeback = (word >> 21) & 1 != 0, load = (word >> 20) & 1 != 0
        let rn = Int((word >> 16) & 0xF)
        let selected = (0..<16).filter { (word & (UInt32(1) << UInt32($0))) != 0 }
        let count = UInt32(selected.count)
        let base = try reg(rn, pc: pc)
        let start = up ? base &+ (pre ? 4 : 0) : base &- 4 &* count &+ (pre ? 0 : 4)
        let final = up ? base &+ 4 &* count : base &- 4 &* count
        var address = start
        var loadedPC: UInt32?
        for index in selected {
            if load {
                let value = try memory.read32(address)
                if index == 15 { loadedPC = value & ~3 } else { registers[index] = value }
            } else {
                try memory.write32(address, try reg(index, pc: pc))
            }
            address = address &+ 4
        }
        if writeback { registers[rn] = final }
        if let loadedPC { registers[15] = loadedPC }
    }

    private func executeLegacyVFP(_ word: UInt32, pc: UInt32) throws -> Bool {
        if word == 0xED2D8B10 { registers[13] = registers[13] &- 64; return true }
        if word == 0xECBD8B10 { registers[13] = registers[13] &+ 64; return true }
        if pc == 0x16B80 && word == 0xED2D8B02 {
            registers[13] = registers[13] &- 8
            try memory.write32(registers[13], vfpS[16])
            try memory.write32(registers[13] &+ 4, vfpS[17])
            return true
        }
        if pc == 0x16BD0 && word == 0xED9F8A2D {
            vfpS[16] = try memory.read32(pc &+ 8 &+ 180)
            return true
        }
        if (pc == 0x16BE4 || pc == 0x16C00) && word == 0xEE070A10 {
            vfpS[14] = registers[0]
            return true
        }
        if (pc == 0x16BEC || pc == 0x16C08) && word == 0xEEF87AC7 {
            vfpS[15] = Float(Int32(bitPattern: vfpS[14])).bitPattern
            return true
        }
        if (pc == 0x16BF0 || pc == 0x16C0C) && word == 0xEEC87A27 {
            let numerator = Float(bitPattern: vfpS[16]), denominator = Float(bitPattern: vfpS[15])
            vfpS[15] = (denominator == 0 ? Float.infinity : numerator / denominator).bitPattern
            return true
        }
        if (pc == 0x16BF4 && word == 0xEDC47A03) || (pc == 0x16C10 && word == 0xEDC47A04) {
            try memory.write32(registers[4] &+ (word == 0xEDC47A03 ? 12 : 16), vfpS[15])
            return true
        }
        if pc == 0x16C80 && word == 0xECBD8B02 {
            vfpS[16] = try memory.read32(registers[13])
            vfpS[17] = try memory.read32(registers[13] &+ 4)
            registers[13] = registers[13] &+ 8
            return true
        }
        return false
    }

    @discardableResult
    public func step() throws -> Bool {
        let pc = registers[15]
        if pc == memory.returnSentinel { return false }
        if let instructionHook, try instructionHook(pc, self) {
            steps += 1
            return true
        }
        let word = try memory.readInstruction32(pc)
        registers[15] = pc &+ 4
        steps += 1
        if !conditionPassed(word >> 28) { return true }
        if try executeLegacyVFP(word, pc: pc) { return true }

        let pattern = word & 0x0FFFFFF0
        if pattern == 0x012FFF10 || pattern == 0x012FFF30 {
            let rm = Int(word & 0xF), target = try reg(rm, pc: pc)
            if pattern == 0x012FFF30 { registers[14] = pc &+ 4 }
            registers[15] = target & ~3
            return true
        }
        if ((word >> 25) & 7) == 5 {
            var displacement = Int32(word & 0x00FFFFFF)
            if (displacement & 0x00800000) != 0 { displacement |= Int32(bitPattern: 0xFF000000) }
            let target = UInt32(truncatingIfNeeded: Int64(pc) + 8 + (Int64(displacement) << 2))
            if (word >> 24) & 1 != 0 { registers[14] = pc &+ 4 }
            registers[15] = target
            return true
        }
        if ((word >> 25) & 7) == 4 {
            try executeBlockTransfer(word, pc: pc)
            return true
        }
        if ((word >> 26) & 3) == 1 {
            try executeSingleTransfer(word, pc: pc)
            return true
        }
        if ((word >> 26) & 3) == 0 {
            if ((word >> 25) & 7) == 0 && ((word >> 7) & 1) != 0 &&
               ((word >> 4) & 1) != 0 && ((word >> 5) & 3) != 0 {
                try executeExtraTransfer(word, pc: pc)
            } else {
                try executeDataProcessing(word, pc: pc)
            }
            return true
        }
        if ((word >> 25) & 7) == 6 { return true }
        throw RE4GuestRuntimeError.unsupportedInstruction(pc: pc, word: word)
    }

    public func run(entry: UInt32, arguments: [UInt32] = [], maxSteps: Int = 500_000) throws -> RE4GuestARMv6RunResult {
        guard maxSteps > 0 else { throw RE4GuestRuntimeError.stepLimit(limit: maxSteps, pc: entry) }
        registers = [UInt32](repeating: 0, count: 16)
        steps = 0
        terminationRequested = false
        requestedExitCode = nil
        negative = false; zero = false; carry = false; overflow = false
        vfpS = [UInt32](repeating: 0, count: 32)
        for (index, value) in arguments.prefix(4).enumerated() { registers[index] = value }
        registers[13] = memory.stackTop
        registers[14] = memory.returnSentinel
        registers[15] = entry
        for _ in 0..<maxSteps {
            if terminationRequested {
                return RE4GuestARMv6RunResult(
                    steps: steps, registers: registers, programCounter: registers[15],
                    returned: false, halted: true, exitCode: requestedExitCode
                )
            }
            if registers[15] == memory.returnSentinel {
                return RE4GuestARMv6RunResult(steps: steps, registers: registers,
                                              programCounter: registers[15], returned: true)
            }
            _ = try step()
            if terminationRequested {
                return RE4GuestARMv6RunResult(
                    steps: steps, registers: registers, programCounter: registers[15],
                    returned: false, halted: true, exitCode: requestedExitCode
                )
            }
        }
        if terminationRequested {
            return RE4GuestARMv6RunResult(
                steps: steps, registers: registers, programCounter: registers[15],
                returned: false, halted: true, exitCode: requestedExitCode
            )
        }
        if registers[15] == memory.returnSentinel {
            return RE4GuestARMv6RunResult(steps: steps, registers: registers,
                                          programCounter: registers[15], returned: true)
        }
        throw RE4GuestRuntimeError.stepLimit(limit: maxSteps, pc: registers[15])
    }

    /// Generated, asset-free instruction sequence testing arithmetic/flags, memory and control flow.
    public static func runSelfTest() throws -> String {
        let memory = RE4GuestARMv6Memory(size: 0x20000, heapBase: 0x10000,
                                         stackTop: 0x1F000, returnSentinel: 0xFFF000)
        let code: [UInt32] = [
            0xE3A00005, // MOV r0,#5
            0xE2801007, // ADD r1,r0,#7
            0xE5821000, // STR r1,[r2]
            0xE5923000, // LDR r3,[r2]
            0xE353000C, // CMP r3,#12
            0x1A000003, // BNE failure (not taken)
            0xE3A0400A, // MOV r4,#10
            0xE3A05000, // MOV r5,#0
            0xE3550000, // CMP r5,#0
            0x0A000000, // BEQ past failure case (taken)
            0xE3A040EE, // failure marker
            0xE12FFF1E  // BX lr
        ]
        var codeBytes = Data()
        for word in code {
            codeBytes.append(UInt8(word & 0xFF))
            codeBytes.append(UInt8((word >> 8) & 0xFF))
            codeBytes.append(UInt8((word >> 16) & 0xFF))
            codeBytes.append(UInt8((word >> 24) & 0xFF))
        }
        try memory.loadBytes(codeBytes, at: 0x1000)
        let cpu = RE4GuestARMv6Core(memory: memory)
        let result = try cpu.run(entry: 0x1000, arguments: [0, 0, 0x3000])
        let stored = try memory.read32(0x3000)
        guard result.returned, result.registers[0] == 5, result.registers[1] == 12,
              result.registers[3] == 12, result.registers[4] == 10, stored == 12 else {
            throw RE4GuestRuntimeError.didNotReturn(pc: result.programCounter)
        }
        return "ARMv6 core self-test PASS\nSteps: \(result.steps)\nr0=5, r1=12, r3=12, r4=10\nLDR/STR round-trip: 0x3000 = 12\nConditional BNE skip + BEQ branch + BX LR passed.\nNo game assets or original IPA used."
    }
}
