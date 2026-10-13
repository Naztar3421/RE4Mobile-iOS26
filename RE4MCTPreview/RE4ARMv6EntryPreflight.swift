import Foundation

public enum RE4ARMv6InstructionClass: String {
    case branchExchange = "BX/BLX register"
    case branch = "B/BL relative"
    case blockTransfer = "LDM/STM block transfer"
    case singleTransfer = "LDR/STR single transfer"
    case extraTransfer = "LDRH/STRH/LDRSB/LDRSH family"
    case dataProcessing = "data-processing / miscellaneous"
    case softwareInterrupt = "SVC/software interrupt"
    case coprocessor = "coprocessor/VFP family"
    case unclassified = "unclassified instruction"
}

public struct RE4ARMv6InstructionRecord {
    public let address: UInt32
    public let word: UInt32
    public let condition: String
    public let instructionClass: RE4ARMv6InstructionClass
    public let corePath: String
    public let branchTarget: UInt32?
}

public enum RE4ARMv6EntryPreflight {
    private static let conditions = [
        "EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
        "HI", "LS", "GE", "LT", "GT", "LE", "AL", "NV"
    ]

    public static func classify(_ word: UInt32, at pc: UInt32) -> RE4ARMv6InstructionRecord {
        let condition = conditions[Int((word >> 28) & 0xF)]
        let branchTarget: UInt32?
        let kind: RE4ARMv6InstructionClass
        let corePath: String

        let registerBranch = word & 0x0FFFFFF0
        if registerBranch == 0x012FFF10 || registerBranch == 0x012FFF30 {
            kind = .branchExchange
            corePath = "CPU handler exists"
            branchTarget = nil
        } else if (word & 0x0F000000) == 0x0F000000 {
            kind = .softwareInterrupt
            corePath = "requires SVC/HLE implementation"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 5 {
            var displacement = Int32(word & 0x00FFFFFF)
            if (displacement & 0x00800000) != 0 {
                displacement |= Int32(bitPattern: 0xFF000000)
            }
            let target64 = Int64(pc) + 8 + (Int64(displacement) << 2)
            branchTarget = UInt32(truncatingIfNeeded: target64)
            kind = .branch
            corePath = "CPU handler exists"
        } else if ((word >> 25) & 7) == 4 {
            kind = .blockTransfer
            corePath = "CPU handler exists; address-mode correctness still needs trace tests"
            branchTarget = nil
        } else if ((word >> 26) & 3) == 1 {
            kind = .singleTransfer
            corePath = "CPU handler exists; addressing modes need instruction-level validation"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 0 &&
                  ((word >> 7) & 1) != 0 &&
                  ((word >> 4) & 1) != 0 &&
                  ((word >> 5) & 3) != 0 {
            kind = .extraTransfer
            corePath = "CPU handler exists"
            branchTarget = nil
        } else if ((word >> 26) & 3) == 0 {
            kind = .dataProcessing
            corePath = "generic path exists; instruction encoding requires audit"
            branchTarget = nil
        } else if ((word >> 25) & 7) == 6 || ((word >> 25) & 7) == 7 {
            kind = .coprocessor
            corePath = "NOT safe to execute: generic coprocessor path is not emulated"
            branchTarget = nil
        } else {
            kind = .unclassified
            corePath = "not verified by current interpreter"
            branchTarget = nil
        }

        return RE4ARMv6InstructionRecord(
            address: pc, word: word, condition: condition,
            instructionClass: kind, corePath: corePath, branchTarget: branchTarget
        )
    }

    public static func inspect(entryPoint: UInt32,
                               image: RE4MachO32Image,
                               memory: RE4GuestMemoryReading,
                               instructionCount: Int = 24) throws -> String {
        let count = max(1, min(instructionCount, 64))
        guard let segment = image.segments.first(where: {
            UInt64(entryPoint) >= UInt64($0.vmAddress) &&
            UInt64(entryPoint) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }), !segment.isPageZero, (segment.initialProtection & 4) != 0 else {
            throw RE4ARMv6EntryPreflightError.entryNotInExecutableSegment(entryPoint)
        }
        var records: [RE4ARMv6InstructionRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let address64 = UInt64(entryPoint) + UInt64(index) * 4
            guard address64 + 4 <= UInt64(UInt32.max) + 1 else {
                throw RE4ARMv6EntryPreflightError.addressOverflow
            }
            let address = UInt32(address64)
            let inExecutableSegment = image.segments.contains {
                !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
                UInt64(address) >= UInt64($0.vmAddress) &&
                UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
            }
            guard inExecutableSegment else { break }
            let data = try memory.copyBytes(at: address, count: 4)
            guard data.count == 4 else { throw RE4ARMv6EntryPreflightError.shortRead(address) }
            let b = [UInt8](data)
            let word = UInt32(b[0]) | (UInt32(b[1]) << 8) |
                (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            records.append(classify(word, at: address))
        }

        var lines = [
            "ARMv6 entry-point static preflight PASS",
            String(format: "Entry PC: 0x%08X", entryPoint),
            "Instructions inspected: \(records.count)",
            "Execution performed: NO",
            "",
            "[Instruction words]"
        ]
        for r in records {
            let target = r.branchTarget.map { String(format: " target=0x%08X", $0) } ?? ""
            lines.append(String(format: "0x%08X  0x%08X  %@  %@%@",
                                r.address, r.word, r.condition, r.instructionClass.rawValue, target))
            lines.append("    Core path: \(r.corePath)")
        }
        let unsafe = records.filter {
            $0.instructionClass == .coprocessor ||
            $0.instructionClass == .softwareInterrupt ||
            $0.instructionClass == .unclassified
        }.count
        lines += [
            "",
            "Instructions needing review: \(unsafe) of \(records.count)",
            "This is static inspection only; no entry point, HLE import, or initializer was executed."
        ]
        return lines.joined(separator: "\n")
    }


    private static let entryRegisterNames = [
        "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
        "r8", "r9", "r10", "r11", "r12", "sp", "lr", "pc"
    ]
    private static let entryDataOpNames = [
        "AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC",
        "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN"
    ]

    private static func entryReadWord(_ address: UInt32, memory: RE4GuestMemoryReading) throws -> UInt32 {
        let data = try memory.copyBytes(at: address, count: 4)
        guard data.count == 4 else { throw RE4ARMv6EntryPreflightError.shortRead(address) }
        let b = [UInt8](data)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func entryRegName(_ index: UInt32) -> String {
        index < 16 ? entryRegisterNames[Int(index)] : "r\(index)"
    }

    private static func entryImmOperand(_ word: UInt32) -> UInt32 {
        let value = word & 0xFF
        let rotation = ((word >> 8) & 0xF) * 2
        return rotation == 0 ? value : (value >> rotation) | (value << (32 - rotation))
    }

    private static func entryOperandText(_ word: UInt32) -> String {
        if word & (1 << 25) != 0 {
            return String(format: "#0x%X", entryImmOperand(word))
        }
        let rm = entryRegName(word & 0xF)
        let shiftType = (word >> 5) & 3
        let shiftAmount = (word >> 7) & 0x1F
        if shiftAmount == 0 && shiftType == 0 { return rm }
        let shiftNames = ["LSL", "LSR", "ASR", "ROR"]
        let amount = shiftAmount == 0 && shiftType != 0 ? 32 : shiftAmount
        return "\(rm), \(shiftNames[Int(shiftType)]) #\(amount)"
    }

    private static func entryDescribe(_ word: UInt32, at pc: UInt32) -> String {
        let branchRegister = word & 0x0FFFFFF0
        if branchRegister == 0x012FFF10 { return "BX \(entryRegName(word & 0xF))" }
        if branchRegister == 0x012FFF30 { return "BLX \(entryRegName(word & 0xF))" }
        if (word & 0x0F000000) == 0x0F000000 {
            return String(format: "SVC #0x%X", word & 0x00FFFFFF)
        }
        if ((word >> 25) & 7) == 5 {
            var displacement = Int32(word & 0x00FFFFFF)
            if (displacement & 0x00800000) != 0 { displacement |= Int32(bitPattern: 0xFF000000) }
            let target = UInt32(truncatingIfNeeded: Int64(pc) + 8 + (Int64(displacement) << 2))
            let name = (word & (1 << 24)) != 0 ? "BL" : "B"
            let condition = conditions[Int((word >> 28) & 0xF)]
            return String(format: "%@%@ 0x%08X", name, condition == "AL" ? "" : condition, target)
        }
        if ((word >> 26) & 3) == 1 {
            let load = word & (1 << 20) != 0
            let byte = word & (1 << 22) != 0
            let pre = word & (1 << 24) != 0
            let up = word & (1 << 23) != 0
            let writeback = word & (1 << 21) != 0
            let rn = entryRegName((word >> 16) & 0xF)
            let rd = entryRegName((word >> 12) & 0xF)
            let operation = (load ? "LDR" : "STR") + (byte ? "B" : "")
            let offset: String?
            if word & (1 << 25) == 0 {
                let amount = word & 0xFFF
                offset = amount == 0 ? nil : String(format: "%@#0x%X", up ? "" : "-", amount)
            } else {
                offset = "\(up ? "" : "-")\(entryRegName(word & 0xF))"
            }
            if pre {
                return "\(operation) \(rd), [\(rn)\(offset.map { ", " + $0 } ?? "")]\(writeback ? "!" : "")"
            }
            return "\(operation) \(rd), [\(rn)]\(offset.map { ", " + $0 } ?? "")"
        }
        if ((word >> 26) & 3) == 0 {
            let opcode = Int((word >> 21) & 0xF)
            let name = entryDataOpNames[opcode]
            let rn = entryRegName((word >> 16) & 0xF)
            let rd = entryRegName((word >> 12) & 0xF)
            let operand = entryOperandText(word)
            if [8, 9, 10, 11].contains(opcode) { return "\(name) \(rn), \(operand)" }
            if opcode == 13 || opcode == 15 { return "\(name) \(rd), \(operand)" }
            return "\(name) \(rd), \(rn), \(operand)"
        }
        return String(format: ".word 0x%08X", word)
    }

    private static func entryLiteralAddress(_ word: UInt32, pc: UInt32) -> UInt32? {
        guard ((word >> 26) & 3) == 1,
              word & (1 << 25) == 0,
              word & (1 << 24) != 0,
              word & (1 << 20) != 0,
              ((word >> 16) & 0xF) == 15 else { return nil }
        let base = UInt64(pc) + 8
        let offset = UInt64(word & 0xFFF)
        let address = word & (1 << 23) != 0
            ? base + offset
            : (base >= offset ? base - offset : UInt64.max)
        return address <= UInt64(UInt32.max) ? UInt32(address) : nil
    }

    private static func entryOperandValue(_ word: UInt32, registers: [Int: UInt32]) -> UInt32? {
        if word & (1 << 25) != 0 { return entryImmOperand(word) }
        let rm = Int(word & 0xF)
        guard let source = registers[rm] else { return nil }
        let type = (word >> 5) & 3
        let amount = (word >> 7) & 0x1F
        switch type {
        case 0: return amount == 0 ? source : source << amount
        case 1: return amount == 0 ? 0 : source >> amount
        case 2:
            if amount == 0 { return (source & 0x80000000) == 0 ? 0 : UInt32.max }
            return UInt32(bitPattern: Int32(bitPattern: source) >> amount)
        default:
            return amount == 0 ? (source >> 1) | (source << 31) : (source >> amount) | (source << (32 - amount))
        }
    }


    private static func entryShiftedRegisterOffset(_ word: UInt32, registers: [Int: UInt32]) -> UInt32? {
        guard word & (1 << 25) != 0, word & (1 << 4) == 0 else { return nil }
        let rm = Int(word & 0xF)
        guard let value = registers[rm] else { return nil }
        let shiftType = (word >> 5) & 3
        let amount = (word >> 7) & 0x1F
        switch shiftType {
        case 0: return amount == 0 ? value : value << amount
        case 1: return amount == 0 ? 0 : value >> amount
        case 2:
            if amount == 0 { return (value & 0x80000000) == 0 ? 0 : UInt32.max }
            return UInt32(bitPattern: Int32(bitPattern: value) >> amount)
        default:
            // RRX requires the carry flag, which static analysis deliberately does not guess.
            if amount == 0 { return nil }
            return (value >> amount) | (value << (32 - amount))
        }
    }

    /// Statically traces a simple sequential entry path, annotating PC-relative literals and
    /// indirect transfer targets without changing CPU state or executing any guest instruction.
    public static func inspectEntryControlFlow(entryPoint: UInt32,
                                               image: RE4MachO32Image,
                                               memory: RE4GuestMemoryReading,
                                               maxInstructions: Int = 64) throws -> String {
        let limit = min(max(maxInstructions, 1), 96)
        guard let _ = image.segments.first(where: {
            !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
            UInt64(entryPoint) >= UInt64($0.vmAddress) &&
            UInt64(entryPoint) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }) else {
            throw RE4ARMv6EntryPreflightError.entryNotInExecutableSegment(entryPoint)
        }

        var lines = [String]()
        var registers: [Int: UInt32] = [:]
        var literalRefs: [UInt32: UInt32] = [:]
        var indexedLoads: [UInt32: UInt32] = [:]
        var transfers = [String]()
        var instructionCount = 0
        var stopBX: UInt32?
        var pc = entryPoint

        for _ in 0..<limit {
            guard image.segments.contains(where: {
                !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
                UInt64(pc) >= UInt64($0.vmAddress) &&
                UInt64(pc) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
            }) else { break }

            let word = try entryReadWord(pc, memory: memory)
            let decoded = entryDescribe(word, at: pc)
            var annotations = [String]()

            if let literal = entryLiteralAddress(word, pc: pc) {
                let value = try entryReadWord(literal, memory: memory)
                literalRefs[literal] = value
                registers[Int((word >> 12) & 0xF)] = value
                annotations.append(String(format: "literal[0x%08X] = 0x%08X", literal, value))
            } else if ((word >> 26) & 3) == 0 {
                let opcode = Int((word >> 21) & 0xF)
                let rn = Int((word >> 16) & 0xF)
                let rd = Int((word >> 12) & 0xF)
                if opcode == 13, let operand = entryOperandValue(word, registers: registers) {
                    registers[rd] = operand
                } else if opcode == 4, let operand = entryOperandValue(word, registers: registers) {
                    let left: UInt32?
                    if rn == 15 {
                        left = pc &+ 8
                    } else {
                        left = registers[rn]
                    }
                    if let left {
                        let value = left &+ operand
                        registers[rd] = value
                        annotations.append(String(format: "statically inferred value/address = 0x%08X", value))
                    }
                }
            } else if ((word >> 26) & 3) == 1,
                      word & (1 << 20) != 0,   // LDR
                      word & (1 << 22) == 0,   // word, not LDRB
                      word & (1 << 24) != 0,   // pre-indexed address
                      word & (1 << 21) == 0 {  // no write-back in this static subset
                let rn = Int((word >> 16) & 0xF)
                let rd = Int((word >> 12) & 0xF)
                let base: UInt32? = rn == 15 ? pc &+ 8 : registers[rn]
                let offset: UInt32?
                if word & (1 << 25) == 0 {
                    offset = word & 0xFFF
                } else {
                    offset = entryShiftedRegisterOffset(word, registers: registers)
                }

                if let base, let offset {
                    let address64 = word & (1 << 23) != 0
                        ? UInt64(base) + UInt64(offset)
                        : (UInt64(base) >= UInt64(offset) ? UInt64(base) - UInt64(offset) : UInt64.max)
                    if address64 <= UInt64(UInt32.max) {
                        let address = UInt32(address64)
                        let value = try entryReadWord(address, memory: memory)
                        registers[rd] = value
                        if rn == 15 && word & (1 << 25) != 0 {
                            indexedLoads[address] = value
                            annotations.append(String(format: "PC-indexed LDR effective address = 0x%08X; loaded 0x%08X", address, value))
                        } else {
                            annotations.append(String(format: "static dereference [0x%08X] = 0x%08X", address, value))
                        }
                    } else {
                        registers.removeValue(forKey: rd)
                        annotations.append("static LDR address overflow; destination register marked unknown")
                    }
                } else {
                    registers.removeValue(forKey: rd)
                    annotations.append("static LDR base/offset unknown; destination register marked unknown")
                }
            }

            let branchRegister = word & 0x0FFFFFF0
            if branchRegister == 0x012FFF30, (word >> 28) == 0xE {
                let rm = Int(word & 0xF)
                if let target = registers[rm] {
                    transfers.append(String(format: "BLX at 0x%08X -> 0x%08X", pc, target))
                    annotations.append(String(format: "static indirect call target = 0x%08X", target))
                } else {
                    transfers.append(String(format: "BLX at 0x%08X -> unknown register %@", pc, entryRegName(UInt32(rm))))
                }
                for index in [0, 1, 2, 3, 12] { registers.removeValue(forKey: index) }
            }
            if branchRegister == 0x012FFF10, (word >> 28) == 0xE {
                let rm = Int(word & 0xF)
                if let target = registers[rm] {
                    transfers.append(String(format: "BX at 0x%08X -> 0x%08X", pc, target))
                    annotations.append(String(format: "static indirect branch target = 0x%08X", target))
                } else {
                    transfers.append(String(format: "BX at 0x%08X -> unknown register %@", pc, entryRegName(UInt32(rm))))
                }
                lines.append(String(format: "0x%08X  0x%08X  %@", pc, word, decoded))
                for annotation in annotations { lines.append("    " + annotation) }
                instructionCount += 1
                stopBX = pc
                break
            }
            if ((word >> 25) & 7) == 5 {
                var displacement = Int32(word & 0x00FFFFFF)
                if (displacement & 0x00800000) != 0 { displacement |= Int32(bitPattern: 0xFF000000) }
                let target = UInt32(truncatingIfNeeded: Int64(pc) + 8 + (Int64(displacement) << 2))
                let isLink = word & (1 << 24) != 0
                annotations.append(String(format: "branch edge = 0x%08X (not followed)", target))
                let labels = image.symbols.filter {
                    !$0.isUndefined && !$0.name.isEmpty && $0.value == target
                }.map(\.name).sorted()
                if !labels.isEmpty {
                    annotations.append("defined target symbol(s): " + labels.joined(separator: ", "))
                }
                if isLink && ((word >> 28) & 0xF) == 0xE {
                    // The callee may clobber the ARM caller-saved registers; don't carry stale values forward.
                    for index in [0, 1, 2, 3, 12] { registers.removeValue(forKey: index) }
                }
            }
            lines.append(String(format: "0x%08X  0x%08X  %@", pc, word, decoded))
            for annotation in annotations { lines.append("    " + annotation) }
            instructionCount += 1
            pc = pc &+ 4
        }

        var report = [
            "ARMv6 entry control-flow preflight PASS",
            String(format: "Entry PC: 0x%08X", entryPoint),
            "Sequential instructions decoded: \(instructionCount)",
            "Guest execution performed: NO",
            "HLE dispatch performed: NO",
            "",
            "[Entry path: decoded operands]"
        ]
        report += lines
        report += ["", "[Referenced PC-relative literal-pool words]"]
        if literalRefs.isEmpty {
            report.append("(none referenced by the inspected path)")
        } else {
            for address in literalRefs.keys.sorted() {
                report.append(String(format: "0x%08X: 0x%08X (data, not an instruction)", address, literalRefs[address]!))
            }
        }
        report += ["", "[PC-indexed/register-offset load targets]"]
        if indexedLoads.isEmpty {
            report.append("(none resolved)")
        } else {
            for address in indexedLoads.keys.sorted() {
                report.append(String(format: "0x%08X: loaded 0x%08X", address, indexedLoads[address]!))
                if let segment = image.segments.first(where: {
                    !$0.isPageZero && UInt64(address) >= UInt64($0.vmAddress) &&
                    UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
                }) {
                    let section = segment.sections.first(where: {
                        UInt64(address) >= UInt64($0.address) &&
                        UInt64(address) + 4 <= UInt64($0.address) + UInt64($0.size)
                    })
                    report.append("    segment: \(segment.name)" + (section.map { ", section: \($0.segmentName),\($0.name)" } ?? ", no named section"))
                }
            }
        }
        report += ["", "[Statically inferred indirect transfers]"]
        report += transfers.isEmpty ? ["(none resolved)"] : transfers
        if let stopBX {
            report.append(String(format: "Linear fall-through stopped at unconditional BX 0x%08X; target not followed.", stopBX))
        } else {
            report.append("Stopped at instruction limit or executable-segment boundary.")
        }
        if !registers.isEmpty {
            report += ["", "[Remaining statically known registers]"]
            for index in registers.keys.sorted() {
                report.append(String(format: "%@ = 0x%08X", entryRegName(UInt32(index)), registers[index]!))
            }
        }
        report += ["", "Static data-flow approximation only. It does not reproduce loop conditions, execute instructions, call HLE, or apply Mach-O fixups."]
        return report.joined(separator: "\n")
    }


    /// Inspect a statically inferred indirect-call target without executing it.
    public static func inspectAddress(_ address: UInt32,
                                      label: String,
                                      image: RE4MachO32Image,
                                      memory: RE4GuestMemoryReading,
                                      maxInstructions: Int = 64) throws -> String {
        guard let segment = image.segments.first(where: {
            !$0.isPageZero && ($0.initialProtection & 4) != 0 &&
            UInt64(address) >= UInt64($0.vmAddress) &&
            UInt64(address) + 4 <= UInt64($0.vmAddress) + UInt64($0.vmSize)
        }) else {
            throw RE4ARMv6EntryPreflightError.entryNotInExecutableSegment(address)
        }

        let exactSymbols = image.symbols.filter {
            !$0.isUndefined && $0.value == address && !$0.name.isEmpty
        }.sorted { $0.name < $1.name }
        let nearby = image.symbols.filter {
            !$0.isUndefined && !$0.name.isEmpty && $0.value != 0 &&
            UInt64($0.value) + 0x1000 >= UInt64(address) &&
            UInt64($0.value) <= UInt64(address) + 0x1000
        }.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.name < $1.name
        }

        var lines = [
            "ARMv6 indirect target static audit PASS",
            "Target label: \(label)",
            String(format: "Target address: 0x%08X", address),
            "Guest execution performed: NO",
            "HLE dispatch performed: NO",
            "Pointer/fixup application performed: NO",
            "Executable segment: \(segment.name)",
            "",
            "[Exact defined symbols]"
        ]
        if exactSymbols.isEmpty {
            lines.append("(no exact symbol-table name at this address)")
        } else {
            for symbol in exactSymbols.prefix(16) {
                lines.append(String(format: "%@ value=0x%08X type=0x%02X section=%u desc=0x%04X",
                                    symbol.name, symbol.value, symbol.type, symbol.section, symbol.description))
            }
        }
        lines += ["", "[Nearby defined symbol labels (±0x1000) — not function boundaries]"]
        if nearby.isEmpty {
            lines.append("(none in symbol table window)")
        } else {
            for symbol in nearby.prefix(40) {
                let relation = symbol.value == address ? "target" : (symbol.value < address ? "before" : "after")
                lines.append(String(format: "%@ 0x%08X %@", relation, symbol.value, symbol.name))
            }
            if nearby.count > 40 { lines.append("… plus \(nearby.count - 40) more") }
        }
        lines += ["", "[Target instruction path]"]
        lines.append(try inspectEntryControlFlow(
            entryPoint: address, image: image, memory: memory, maxInstructions: maxInstructions
        ))
        lines.append("")
        lines.append("Static target audit only: symbol values may be absent/stripped and are not proof of a function boundary. The target was not called.")
        return lines.joined(separator: "\n")
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x05000000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let report = try inspect(entryPoint: image.entryPoint!, image: image, memory: memory, instructionCount: 3)
        let targetReport = try inspectAddress(image.entryPoint!, label: "synthetic entry",
                                              image: image, memory: memory, maxInstructions: 3)
        let first = classify(0xE3A00001, at: 0x1270)
        let second = classify(0xE2800002, at: 0x1274)
        let third = classify(0xE12FFF1E, at: 0x1278)
        let flow = try inspectEntryControlFlow(entryPoint: image.entryPoint!, image: image, memory: memory, maxInstructions: 8)
        // Synthetic register-offset load: MOV r0,#0x18; LDR r1,[pc,r0]; BX lr.
        // It reads a marker word from 0x12A4 in zero-filled synthetic guest memory.
        let markerInstructions = Data([
            0x18, 0x00, 0xA0, 0xE3, // 0x1280 MOV r0,#0x18
            0x00, 0x10, 0x9F, 0xE7, // 0x1284 LDR r1,[pc,r0] (PC=0x128C, +0x18=0x12A4)
            0x1E, 0xFF, 0x2F, 0xE1  // 0x1288 BX lr
        ])
        try memory.writeBytes(at: 0x1280, data: markerInstructions)
        try memory.writeBytes(at: 0x12A4, data: Data([0x78, 0x56, 0x34, 0x12]))
        let indexedFlow = try inspectEntryControlFlow(entryPoint: 0x1280, image: image, memory: memory, maxInstructions: 8)
        guard indexedFlow.contains("PC-indexed LDR effective address = 0x000012A4; loaded 0x12345678"),
              indexedFlow.contains("0x000012A4: loaded 0x12345678"),
              flow.contains("ADD r0, r0, #0x2"),
              flow.contains("BX lr"),
              flow.contains("Guest execution performed: NO"),
              first.instructionClass == .dataProcessing,
              second.instructionClass == .dataProcessing,
              third.instructionClass == .branchExchange,
              report.contains("0x00001270  0xE3A00001") &&
              report.contains("0x00001274  0xE2800002") &&
              report.contains("0x00001278  0xE12FFF1E") &&
              report.contains("Execution performed: NO"),
              targetReport.contains("ARMv6 indirect target static audit PASS"),
              targetReport.contains("Guest execution performed: NO"),
              targetReport.contains("[Target instruction path]") else {
            throw RE4ARMv6EntryPreflightError.selfTestFailed
        }
        return "ARMv6 entry-point preflight self-test PASS\nMOV/ADD/BX instruction words decoded at expected guest VAs.\nInstruction conditions and classes reported.\nStatic only: CPU state and guest memory were not executed."
    }
}

public enum RE4ARMv6EntryPreflightError: Error, LocalizedError {
    case entryNotInExecutableSegment(UInt32)
    case shortRead(UInt32)
    case addressOverflow
    case selfTestFailed

    public var errorDescription: String? {
        switch self {
        case .entryNotInExecutableSegment(let pc):
            return String(format: "Entry PC 0x%08X is not inside an executable mapped segment.", pc)
        case .shortRead(let pc):
            return String(format: "Could not read a complete instruction at 0x%08X.", pc)
        case .addressOverflow: return "Instruction inspection address overflow."
        case .selfTestFailed: return "Synthetic ARMv6 entry preflight self-test failed."
        }
    }
}
