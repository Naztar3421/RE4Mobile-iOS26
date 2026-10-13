import Foundation

public enum RE4GuestRuntimeError: Error, LocalizedError {
    case invalidMemoryRange(address: UInt32, count: Int)
    case heapExhausted
    case invalidRegister(Int)
    case unsupportedInstruction(pc: UInt32, word: UInt32)
    case stepLimit(limit: Int, pc: UInt32)
    case didNotReturn(pc: UInt32)

    public var errorDescription: String? {
        switch self {
        case .invalidMemoryRange(let address, let count):
            return String(format: "Guest memory range 0x%08X (+%d) is outside mapped guest memory.", address, count)
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

/// Bounds-checked, little-endian 32-bit guest address space.
/// All address access is copied through this object; it never returns host pointers.
public final class RE4GuestARMv6Memory: RE4GuestMemoryReading, RE4GuestMemoryMapping {
    public let size: Int
    public let stackTop: UInt32
    public let returnSentinel: UInt32
    private var bytes: [UInt8]
    private var heapCursor: UInt32

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

    private func checkedRange(_ address: UInt32, _ count: Int) throws -> Range<Int> {
        guard count >= 0 else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
        }
        let start = UInt64(address)
        let end = start + UInt64(count)
        guard end >= start, end <= UInt64(size) else {
            throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: count)
        }
        return Int(start)..<Int(end)
    }

    public func copyBytes(at guestAddress: UInt32, count: Int) throws -> Data {
        let range = try checkedRange(guestAddress, count)
        return Data(bytes[range])
    }

    public func writeBytes(at guestAddress: UInt32, data: Data) throws {
        let range = try checkedRange(guestAddress, data.count)
        bytes.replaceSubrange(range, with: data)
    }

    public func zeroBytes(at guestAddress: UInt32, count: Int) throws {
        let range = try checkedRange(guestAddress, count)
        for index in range { bytes[index] = 0 }
    }

    public func read8(_ address: UInt32) throws -> UInt8 {
        let r = try checkedRange(address, 1)
        return bytes[r.lowerBound]
    }

    public func read16(_ address: UInt32) throws -> UInt16 {
        let r = try checkedRange(address, 2), p = r.lowerBound
        return UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8)
    }

    public func read32(_ address: UInt32) throws -> UInt32 {
        let r = try checkedRange(address, 4), p = r.lowerBound
        return UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8) |
               (UInt32(bytes[p + 2]) << 16) | (UInt32(bytes[p + 3]) << 24)
    }

    public func write8(_ address: UInt32, _ value: UInt8) throws {
        let r = try checkedRange(address, 1)
        bytes[r.lowerBound] = value
    }

    public func write16(_ address: UInt32, _ value: UInt16) throws {
        let r = try checkedRange(address, 2), p = r.lowerBound
        bytes[p] = UInt8(value & 0xFF)
        bytes[p + 1] = UInt8((value >> 8) & 0xFF)
    }

    public func write32(_ address: UInt32, _ value: UInt32) throws {
        let r = try checkedRange(address, 4), p = r.lowerBound
        bytes[p] = UInt8(value & 0xFF)
        bytes[p + 1] = UInt8((value >> 8) & 0xFF)
        bytes[p + 2] = UInt8((value >> 16) & 0xFF)
        bytes[p + 3] = UInt8((value >> 24) & 0xFF)
    }

    public func readCString(_ address: UInt32, limit: Int = 8192) throws -> String {
        guard limit >= 0 else { throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: limit) }
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, 256))
        for offset in 0..<limit {
            let (at, overflow) = address.addingReportingOverflow(UInt32(offset))
            guard !overflow else { throw RE4GuestRuntimeError.invalidMemoryRange(address: address, count: limit) }
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

    public init(memory: RE4GuestARMv6Memory, instructionHook: InstructionHook? = nil) {
        self.memory = memory
        self.instructionHook = instructionHook
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
        let word = try memory.read32(pc)
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
        negative = false; zero = false; carry = false; overflow = false
        vfpS = [UInt32](repeating: 0, count: 32)
        for (index, value) in arguments.prefix(4).enumerated() { registers[index] = value }
        registers[13] = memory.stackTop
        registers[14] = memory.returnSentinel
        registers[15] = entry
        for _ in 0..<maxSteps {
            if registers[15] == memory.returnSentinel {
                return RE4GuestARMv6RunResult(steps: steps, registers: registers,
                                              programCounter: registers[15], returned: true)
            }
            _ = try step()
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
