import Foundation

public struct RE4MachO32InitializerControlFlowAuditResult {
    public let report: String
    public let dependencyCSV: String
    public let edgeCSV: String
    public let sjljCrosswalkCSV: String
}

/// Stage J.1: read-only ARM control-flow, initializer dependency, and SJLJ/LSDA crosswalk.
/// All instruction and metadata bytes are obtained through RE4GuestMemoryReading.copyBytes.
/// No guest instruction, initializer, personality routine, unwinder, or landing pad is executed.
public enum RE4MachO32InitializerControlFlowAudit {
    private enum PathKind: String, Hashable {
        case normal = "normal"
        case conditional = "conditional"
        case exceptionCleanup = "exception_cleanup"
    }

    private struct FunctionBounds {
        let start: UInt32
        let end: UInt32
        let symbol: String
    }

    private struct WorkItem: Hashable {
        let pc: UInt32
        let path: PathKind
    }

    private struct DependencySite: Hashable {
        let address: UInt32
        let symbol: String
        let path: PathKind
    }

    private struct Edge {
        let initializerIndex: Int
        let functionSymbol: String
        let source: UInt32
        let target: UInt32?
        let edgeType: String
        let condition: String
        let path: PathKind
        let detail: String
    }

    private struct CallSiteRecord {
        let tableIndex: Int
        let landingPadIndex: Int
        let action: Int
    }

    private struct CallSiteMatch {
        let callSiteIndex: Int
        let callAddress: UInt32
        let symbol: String
    }

    private struct SJLJFunctionResult {
        let function: FunctionBounds
        let lsdaAddress: UInt32?
        let registrationCall: UInt32?
        let resumeCall: UInt32?
        let cleanupStart: UInt32?
        let cleanupEnd: UInt32?
        let table: [CallSiteRecord]
        let matches: [CallSiteMatch]
        let cleanupImports: [DependencySite]
        let warnings: [String]
    }

    private struct InitializerState {
        var dependencies = Set<DependencySite>()
        var edges: [Edge] = []
        var unresolved = Set<String>()
        var functions: [UInt32: FunctionBounds] = [:]
        var functionSymbolRanges: [(UInt32, String)] = []
        var visited = Set<WorkItem>()
        var callStack = Set<UInt32>()
        var instructionCount = 0
        var budgetReached = false
        var maxDepthReached = 0
    }

    private enum AuditError: Error, LocalizedError {
        case initializerSectionMissing
        case malformed(String)
        case memoryReadFailed(UInt32)
        case selfTestFailed(String)

        var errorDescription: String? {
            switch self {
            case .initializerSectionMissing:
                return "Mach-O has no unambiguous __DATA,__mod_init_func initializer array."
            case .malformed(let detail):
                return "Malformed initializer control-flow audit input: \(detail)"
            case .memoryReadFailed(let address):
                return String(format: "Could not read Guest Memory at 0x%08X.", address)
            case .selfTestFailed(let detail):
                return "Stage J.1 synthetic self-test failed: \(detail)"
            }
        }
    }

    private static func readBytes(_ address: UInt32, _ count: Int,
                                  memory: RE4GuestMemoryReading) throws -> Data {
        do {
            let data = try memory.copyBytes(at: address, count: count)
            guard data.count == count else { throw AuditError.memoryReadFailed(address) }
            return data
        } catch {
            throw AuditError.memoryReadFailed(address)
        }
    }

    private static func readWord(_ address: UInt32,
                                 memory: RE4GuestMemoryReading) throws -> UInt32 {
        let data = try readBytes(address, 4, memory: memory)
        let b = [UInt8](data)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) |
            (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    private static func sections(_ image: RE4MachO32Image) -> [(Int, RE4MachO32Section)] {
        var result: [(Int, RE4MachO32Section)] = []
        var ordinal = 1
        for segment in image.segments {
            for section in segment.sections {
                result.append((ordinal, section))
                ordinal += 1
            }
        }
        return result
    }

    private static func textSection(_ image: RE4MachO32Image) -> (Int, RE4MachO32Section)? {
        sections(image).first { $0.1.segmentName == "__TEXT" && $0.1.name == "__text" }
    }

    private static func exceptSection(_ image: RE4MachO32Image) -> RE4MachO32Section? {
        image.segments.flatMap(\.sections).first { $0.name == "__gcc_except_tab" }
    }

    private static func functionSymbols(_ image: RE4MachO32Image) -> [(UInt32, String)] {
        guard let (sectionOrdinal, text) = textSection(image) else { return [] }
        let lower = UInt64(text.address)
        let upper = lower + UInt64(text.size)
        let pairs = image.symbols.compactMap { symbol -> (UInt32, String)? in
            let isSectionSymbol = symbol.type & 0x0E == 0x0E
            // N_FUN (0x24) STAB records are the compiler's explicit function boundaries
            // in this stripped-era ARM image; retain them alongside ordinary N_SECT symbols.
            let isFunctionStab = symbol.type == 0x24
            guard !symbol.isUndefined,
                  (isSectionSymbol || isFunctionStab),
                  Int(symbol.section) == sectionOrdinal,
                  UInt64(symbol.value) >= lower,
                  UInt64(symbol.value) < upper,
                  !symbol.name.isEmpty else { return nil }
            return (symbol.value, symbol.name)
        }
        let sorted = pairs.sorted {
            if $0.0 == $1.0 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }
        var unique: [(UInt32, String)] = []
        for pair in sorted where unique.last?.0 != pair.0 { unique.append(pair) }
        return unique
    }

    private static func functionBounds(at address: UInt32,
                                       image: RE4MachO32Image,
                                       symbols: [(UInt32, String)]) -> FunctionBounds? {
        guard let (_, text) = textSection(image) else { return nil }
        let textEnd64 = UInt64(text.address) + UInt64(text.size)
        guard UInt64(address) >= UInt64(text.address), UInt64(address) < textEnd64 else { return nil }
        var low = 0
        var high = symbols.count
        while low < high {
            let middle = (low + high) / 2
            if symbols[middle].0 <= address { low = middle + 1 }
            else { high = middle }
        }
        let index = low - 1
        guard index >= 0 else {
            return FunctionBounds(start: text.address, end: UInt32(min(textEnd64, UInt64(UInt32.max))), symbol: "<text-section-unlabelled>")
        }
        let start = symbols[index].0
        let end64 = index + 1 < symbols.count ? UInt64(symbols[index + 1].0) : textEnd64
        guard end64 > UInt64(start), end64 <= UInt64(UInt32.max) else { return nil }
        return FunctionBounds(start: start, end: UInt32(end64), symbol: symbols[index].1)
    }

    private static func inText(_ address: UInt32, _ image: RE4MachO32Image) -> Bool {
        guard let (_, text) = textSection(image) else { return false }
        return UInt64(address) >= UInt64(text.address) &&
            UInt64(address) + 4 <= UInt64(text.address) + UInt64(text.size)
    }

    private static func branchTarget(_ word: UInt32, pc: UInt32) -> UInt32? {
        var displacement = Int32(word & 0x00FF_FFFF)
        if displacement & 0x0080_0000 != 0 { displacement |= Int32(bitPattern: 0xFF00_0000) }
        let target = Int64(pc) + 8 + (Int64(displacement) << 2)
        guard target >= 0 && target <= Int64(UInt32.max) else { return nil }
        return UInt32(target)
    }

    private static func conditionName(_ condition: UInt32) -> String {
        let names = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
                     "HI", "LS", "GE", "LT", "GT", "LE", "AL", "NV"]
        return names[Int(condition & 0xF)]
    }

    private static func stubSymbols(_ image: RE4MachO32Image) -> [UInt32: String] {
        Dictionary(image.indirectImports.filter(\.isStub).map { ($0.slotAddress, $0.symbolName) },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func addEdge(_ state: inout InitializerState, index: Int,
                                function: FunctionBounds, source: UInt32,
                                target: UInt32?, type: String, condition: String,
                                path: PathKind, detail: String = "") {
        state.edges.append(Edge(initializerIndex: index, functionSymbol: function.symbol,
                                source: source, target: target, edgeType: type,
                                condition: condition, path: path, detail: detail))
    }

    private static func scanFunction(
        at entry: UInt32,
        path: PathKind,
        depth: Int,
        initializerIndex: Int,
        image: RE4MachO32Image,
        memory: RE4GuestMemoryReading,
        stubs: [UInt32: String],
        maxDepth: Int,
        maxInstructions: Int,
        state: inout InitializerState
    ) throws {
        guard let initialBounds = functionBounds(at: entry, image: image, symbols: state.functionSymbolRanges) else {
            state.unresolved.insert(String(format: "target 0x%08X is outside labelled __TEXT,__text", entry))
            return
        }
        if depth > maxDepth {
            state.unresolved.insert(String(format: "call-depth limit at 0x%08X", entry))
            return
        }
        if state.callStack.contains(initialBounds.start) { return }
        state.callStack.insert(initialBounds.start)
        state.functions[initialBounds.start] = initialBounds
        state.maxDepthReached = max(state.maxDepthReached, depth)

        var queue = [WorkItem(pc: entry, path: path)]
        var localVisited = Set<WorkItem>()
        while let item = queue.popLast() {
            if !localVisited.insert(item).inserted { continue }
            if state.visited.contains(item) { continue }

            guard let bounds = functionBounds(at: item.pc, image: image, symbols: state.functionSymbolRanges) else {
                state.unresolved.insert(String(format: "branch target 0x%08X has no text function range", item.pc))
                continue
            }
            state.functions[bounds.start] = bounds
            var pc = item.pc
            // A branch into a different symbol range is a separate bounded function scan.
            if pc < bounds.start || pc >= bounds.end { continue }

            while pc >= bounds.start && pc < bounds.end {
                let current = WorkItem(pc: pc, path: item.path)
                if state.visited.contains(current) { break }
                state.visited.insert(current)
                if state.instructionCount >= maxInstructions {
                    state.budgetReached = true
                    state.unresolved.insert("per-initializer instruction budget reached")
                    break
                }
                guard inText(pc, image) else { break }
                let word = try readWord(pc, memory: memory)
                state.instructionCount += 1
                let condition = (word >> 28) & 0xF
                let condText = conditionName(condition)
                let next = pc &+ 4

                // BX / BLX-register: target is register/data dependent and is never followed.
                let registerBranch = word & 0x0FFF_FFF0
                if registerBranch == 0x012F_FF10 {
                    let rm = word & 0xF
                    if rm == 14 {
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: nil, type: condition == 14 ? "return_bx_lr" : "conditional_return_bx_lr",
                                condition: condText, path: condition == 14 ? item.path : .conditional)
                    } else {
                        state.unresolved.insert(String(format: "BX r%u at 0x%08X has data-dependent target", rm, pc))
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: nil, type: "indirect_bx", condition: condText, path: item.path)
                    }
                    if condition == 14 { break }
                    if condition != 15 { queue.append(WorkItem(pc: next, path: item.path)) }
                    break
                }
                if registerBranch == 0x012F_FF30 {
                    state.unresolved.insert(String(format: "BLX register r%u at 0x%08X not followed", word & 0xF, pc))
                    addEdge(&state, index: initializerIndex, function: bounds,
                            source: pc, target: nil, type: "indirect_call_blx_register", condition: condText,
                            path: condition == 14 ? item.path : .conditional)
                    if condition != 14 { queue.append(WorkItem(pc: next, path: item.path)) }
                    break
                }

                // ARM B/BL immediate. A conditional B has two worklist successors.
                if ((word >> 25) & 7) == 5 {
                    if condition == 15 {
                        state.unresolved.insert(String(format: "BLX immediate at 0x%08X not followed (Thumb decoder unavailable)", pc))
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: nil, type: "blx_immediate_unresolved", condition: condText, path: item.path)
                        break
                    }
                    guard let target = branchTarget(word, pc: pc) else {
                        state.unresolved.insert(String(format: "branch target overflow at 0x%08X", pc))
                        break
                    }
                    let links = (word & (1 << 24)) != 0
                    if links {
                        let callPath: PathKind = condition == 14 ? item.path : .conditional
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: target, type: "direct_bl", condition: condText, path: callPath,
                                detail: stubs[target] ?? "local_or_external")
                        if let imported = stubs[target] {
                            state.dependencies.insert(DependencySite(address: pc, symbol: imported, path: callPath))
                        } else if inText(target, image) {
                            try scanFunction(at: target, path: callPath, depth: depth + 1,
                                             initializerIndex: initializerIndex, image: image,
                                             memory: memory, stubs: stubs, maxDepth: maxDepth,
                                             maxInstructions: maxInstructions, state: &state)
                        } else {
                            state.unresolved.insert(String(format: "direct BL at 0x%08X targets unmapped 0x%08X", pc, target))
                        }
                        queue.append(WorkItem(pc: next, path: item.path))
                        break
                    }

                    if condition == 14 {
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: target, type: "unconditional_b", condition: condText, path: item.path)
                        if let imported = stubs[target] {
                            state.dependencies.insert(DependencySite(address: pc, symbol: imported, path: item.path))
                            break
                        }
                        if inText(target, image) {
                            if let targetBounds = functionBounds(at: target, image: image, symbols: state.functionSymbolRanges), targetBounds.start != bounds.start {
                                try scanFunction(at: target, path: item.path, depth: depth,
                                                 initializerIndex: initializerIndex, image: image,
                                                 memory: memory, stubs: stubs, maxDepth: maxDepth,
                                                 maxInstructions: maxInstructions, state: &state)
                                break
                            }
                            queue.append(WorkItem(pc: target, path: item.path))
                            break
                        }
                        state.unresolved.insert(String(format: "unconditional B at 0x%08X leaves __text to 0x%08X", pc, target))
                        break
                    }

                    if let imported = stubs[target] {
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: target, type: "conditional_b_taken_import", condition: condText,
                                path: .conditional, detail: imported)
                        state.dependencies.insert(DependencySite(address: pc, symbol: imported, path: .conditional))
                    } else {
                        addEdge(&state, index: initializerIndex, function: bounds,
                                source: pc, target: target, type: "conditional_b_taken", condition: condText,
                                path: .conditional)
                        queue.append(WorkItem(pc: target, path: .conditional))
                    }
                    addEdge(&state, index: initializerIndex, function: bounds,
                            source: pc, target: next, type: "conditional_b_fallthrough", condition: condText,
                            path: item.path)
                    queue.append(WorkItem(pc: next, path: item.path))
                    break
                }

                // Conditional LDM/LDR/MOV-to-PC has an unknown taken target and a known fallthrough.
                if ((word >> 25) & 7) == 4,
                   word & (1 << 20) != 0,
                   word & (1 << 15) != 0 {
                    let isPopReturn = ((word >> 16) & 0xF) == 13 &&
                        word & (1 << 24) == 0 && word & (1 << 23) != 0 &&
                        word & (1 << 21) != 0
                    let edgeType = isPopReturn
                        ? (condition == 14 ? "return_pop_pc" : "conditional_return_pop_pc")
                        : (condition == 14 ? "indirect_ldm_pc_exit" : "conditional_indirect_ldm_pc_exit")
                    addEdge(&state, index: initializerIndex, function: bounds,
                            source: pc, target: nil, type: edgeType,
                            condition: condText, path: condition == 14 ? item.path : .conditional)
                    if !isPopReturn {
                        state.unresolved.insert(String(format: "LDM-to-PC at 0x%08X has stack-derived target", pc))
                    }
                    if condition == 14 { break }
                    queue.append(WorkItem(pc: next, path: item.path))
                    break
                }
                if ((word >> 26) & 3) == 1,
                   word & (1 << 20) != 0,
                   word & (1 << 22) == 0,
                   ((word >> 12) & 0xF) == 15 {
                    addEdge(&state, index: initializerIndex, function: bounds,
                            source: pc, target: nil, type: condition == 14 ? "indirect_ldr_pc_exit" : "conditional_indirect_ldr_pc_exit",
                            condition: condText, path: condition == 14 ? item.path : .conditional)
                    state.unresolved.insert(String(format: "LDR-to-PC at 0x%08X has data-derived target", pc))
                    if condition == 14 { break }
                    queue.append(WorkItem(pc: next, path: item.path))
                    break
                }
                // MOV pc,lr return.
                if ((word >> 26) & 3) == 0,
                   ((word >> 21) & 0xF) == 13,
                   ((word >> 12) & 0xF) == 15,
                   (word & 0xF) == 14 {
                    addEdge(&state, index: initializerIndex, function: bounds,
                            source: pc, target: nil, type: condition == 14 ? "return_mov_pc_lr" : "conditional_return_mov_pc_lr",
                            condition: condText, path: condition == 14 ? item.path : .conditional)
                    if condition == 14 { break }
                    queue.append(WorkItem(pc: next, path: item.path))
                    break
                }
                pc = next
            }
        }
        state.callStack.remove(initialBounds.start)
    }

    private static func readULEB(_ bytes: [UInt8], cursor: inout Int, limit: Int) -> Int? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit && cursor < bytes.count && shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                guard value <= UInt64(Int.max) else { return nil }
                return Int(value)
            }
            shift += 7
        }
        return nil
    }

    /// Old SJLJ personalities consume call-site rows as ULEB128 (landing-pad, action) pairs.
    /// Header encodings are retained for audit, but do not change the SJLJ pair decoding here.
    private static func parseSJLJCallSiteTable(_ bytes: [UInt8]) -> (encoding: UInt8, rows: [CallSiteRecord])? {
        guard bytes.count >= 4 else { return nil }
        var cursor = 0
        let lpStartEncoding = bytes[cursor]; cursor += 1
        guard lpStartEncoding == 0xFF else { return nil }
        let typeEncoding = bytes[cursor]; cursor += 1
        if typeEncoding != 0xFF {
            guard readULEB(bytes, cursor: &cursor, limit: bytes.count) != nil else { return nil }
        }
        guard cursor < bytes.count else { return nil }
        let encoding = bytes[cursor]; cursor += 1
        guard let tableLength = readULEB(bytes, cursor: &cursor, limit: bytes.count),
              tableLength >= 0, cursor + tableLength <= bytes.count else { return nil }
        let tableEnd = cursor + tableLength
        var rows: [CallSiteRecord] = []
        while cursor < tableEnd {
            guard let landingPad = readULEB(bytes, cursor: &cursor, limit: tableEnd),
                  let action = readULEB(bytes, cursor: &cursor, limit: tableEnd) else { return nil }
            rows.append(CallSiteRecord(tableIndex: rows.count + 1,
                                       landingPadIndex: landingPad + 1,
                                       action: action))
        }
        guard cursor == tableEnd else { return nil }
        return (encoding, rows)
    }

    private static func decodeARMImmediate(_ word: UInt32) -> UInt32 {
        let imm8 = word & 0xFF
        let rotate = ((word >> 8) & 0xF) * 2
        return rotate == 0 ? imm8 : (imm8 >> rotate) | (imm8 << (32 - rotate))
    }

    private static func ldrLiteral(_ word: UInt32, pc: UInt32) -> (register: UInt32, literal: UInt32)? {
        guard ((word >> 26) & 3) == 1,
              word & (1 << 24) != 0, word & (1 << 21) == 0,
              word & (1 << 20) != 0, word & (1 << 22) == 0,
              ((word >> 16) & 0xF) == 15 else { return nil }
        let offset = word & 0xFFF
        let base = UInt64(pc) + 8
        let address = (word & (1 << 23)) != 0 ? base + UInt64(offset) : base - UInt64(offset)
        guard address <= UInt64(UInt32.max) else { return nil }
        return (((word >> 12) & 0xF), UInt32(address))
    }

    private static func addPCRegister(_ word: UInt32, pc: UInt32) -> (destination: UInt32, source: UInt32)? {
        guard ((word >> 26) & 3) == 0,
              word & (1 << 25) == 0,
              ((word >> 21) & 0xF) == 4,
              ((word >> 16) & 0xF) == 15,
              ((word >> 12) & 0xF) == (word & 0xF),
              ((word >> 4) & 0xFF) == 0 else { return nil }
        let reg = word & 0xF
        let destination = (word >> 12) & 0xF
        _ = pc
        return (destination, reg)
    }

    private static func findLSDA(in bounds: FunctionBounds,
                                 before registration: UInt32,
                                 image: RE4MachO32Image,
                                 memory: RE4GuestMemoryReading) throws -> UInt32? {
        guard let section = exceptSection(image) else { return nil }
        let sectionStart = UInt64(section.address)
        let sectionEnd = sectionStart + UInt64(section.size)
        var literalRegisters: [UInt32: UInt32] = [:]
        var resolved: UInt32?
        var pc = bounds.start
        while pc < registration && pc < bounds.end {
            let word = try readWord(pc, memory: memory)
            if let ldr = ldrLiteral(word, pc: pc) {
                if ldr.literal >= bounds.start && UInt64(ldr.literal) + 4 <= UInt64(bounds.end) {
                    let literalValue = try readWord(ldr.literal, memory: memory)
                    literalRegisters[ldr.register] = literalValue
                }
            } else if let add = addPCRegister(word, pc: pc),
                      let displacement = literalRegisters[add.source] {
                let value = UInt64(pc) + 8 + UInt64(displacement)
                if value >= sectionStart && value < sectionEnd && value <= UInt64(UInt32.max) {
                    resolved = UInt32(value)
                }
            }
            pc &+= 4
        }
        return resolved
    }

    private static func isAddR0SPImmediate(_ word: UInt32) -> UInt32? {
        guard ((word >> 26) & 3) == 0,
              word & (1 << 25) != 0,
              ((word >> 21) & 0xF) == 4,
              ((word >> 16) & 0xF) == 13,
              ((word >> 12) & 0xF) == 0 else { return nil }
        return decodeARMImmediate(word)
    }

    private static func strSPImmediate(_ word: UInt32) -> (register: UInt32, offset: UInt32)? {
        guard ((word >> 26) & 3) == 1,
              word & (1 << 24) != 0,
              word & (1 << 21) == 0,
              word & (1 << 20) == 0,
              word & (1 << 22) == 0,
              ((word >> 16) & 0xF) == 13 else { return nil }
        let immediate = word & 0xFFF
        let offset = word & (1 << 23) != 0 ? immediate : (0 &- immediate)
        return ((word >> 12) & 0xF, offset)
    }

    private static func immediateDataOp(_ word: UInt32) -> (opcode: UInt32, rn: UInt32, rd: UInt32, value: UInt32)? {
        guard ((word >> 26) & 3) == 0, word & (1 << 25) != 0 else { return nil }
        return (((word >> 21) & 0xF), ((word >> 16) & 0xF),
                ((word >> 12) & 0xF), decodeARMImmediate(word))
    }

    }

    private static func findSJLJ(_ bounds: FunctionBounds,
                                 image: RE4MachO32Image,
                                 memory: RE4GuestMemoryReading,
                                 stubs: [UInt32: String]) throws -> SJLJFunctionResult? {
        guard let registerStub = stubs.first(where: { $0.value == "__Unwind_SjLj_Register" })?.key,
              let resumeStub = stubs.first(where: { $0.value == "__Unwind_SjLj_Resume" })?.key else { return nil }
        var registration: UInt32?
        var resume: UInt32?
        var pc = bounds.start
        while pc < bounds.end {
            let word = try readWord(pc, memory: memory)
            if ((word >> 25) & 7) == 5, (word & (1 << 24)) != 0,
               let target = branchTarget(word, pc: pc) {
                if target == registerStub { registration = pc }
                if target == resumeStub { resume = pc }
            }
            // Do not interpret the literal pool following the function's final pop-to-PC as code.
            let isUnconditionalLDMReturn = ((word >> 25) & 7) == 4 &&
                word & (1 << 20) != 0 && word & (1 << 15) != 0 &&
                ((word >> 28) & 0xF) == 14
            if isUnconditionalLDMReturn { break }
            pc &+= 4
        }
        guard let registerPC = registration else { return nil }
        let lsda = try findLSDA(in: bounds, before: registerPC, image: image, memory: memory)
        var warnings: [String] = []
        var table: [CallSiteRecord] = []
        if let lsda {
            do {
                guard let section = exceptSection(image) else { throw AuditError.malformed("missing __gcc_except_tab") }
                let available = Int(min(UInt64(512), UInt64(section.address) + UInt64(section.size) - UInt64(lsda)))
                let bytes = [UInt8](try readBytes(lsda, available, memory: memory))
                if let parsed = parseSJLJCallSiteTable(bytes) {
                    table = parsed.rows
                } else {
                    warnings.append(String(format: "LSDA 0x%08X header/table could not be parsed", lsda))
                    table = []
                }
            } catch {
                warnings.append("LSDA read failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("SJLJ register call found, but PC-relative LSDA literal pattern was not resolved")
        }

        // Locate the shared cleanup block: an unconditional B skips it to the instruction
        // immediately after the __Unwind_SjLj_Resume call.
        var cleanupStart: UInt32?
        var cleanupEnd: UInt32?
        if let resumePC = resume {
            let continuation = resumePC &+ 4
            var candidate: UInt32?
            var branchPC = bounds.start
            while branchPC < resumePC {
                let word = try readWord(branchPC, memory: memory)
                let condition = (word >> 28) & 0xF
                if ((word >> 25) & 7) == 5,
                   (word & (1 << 24)) == 0,
                   condition == 14,
                   branchTarget(word, pc: branchPC) == continuation {
                    candidate = branchPC
                }
                branchPC &+= 4
            }
            if let candidate {
                cleanupStart = candidate &+ 4
                cleanupEnd = continuation
            } else {
                warnings.append("Resume call found, but no unconditional branch-over-cleanup pattern was identified")
            }
        }

        // Recover SJLJ call_site values stored at [sp, contextBase+4] and match the next
        // direct BL to its LSDA dispatch row. This is bounded local constant propagation.
        var matches: [CallSiteMatch] = []
        if let contextBase = try findSJLJContextBase(bounds, before: registerPC, memory: memory) {
            let callSiteOffset = contextBase &+ 4
            var constants: [UInt32: UInt32] = [:]
            var pendingCallSite: Int?
            pc = registerPC &+ 4
            let scanEnd = cleanupStart ?? bounds.end
            while pc < scanEnd {
                let word = try readWord(pc, memory: memory)
                if let op = immediateDataOp(word) {
                    if op.opcode == 13 { // MOV Rd,#imm
                        constants[op.rd] = op.value
                    } else if op.opcode == 4, let base = constants[op.rn] { // ADD Rd,Rn,#imm
                        constants[op.rd] = base &+ op.value
                    } else if op.opcode != 10 && op.opcode != 11 {
                        constants.removeValue(forKey: op.rd)
                    }
                } else if let store = strSPImmediate(word), store.offset == callSiteOffset {
                    if let value = constants[store.register] { pendingCallSite = Int(value) }
                    else { pendingCallSite = nil }
                } else if ((word >> 25) & 7) == 5, (word & (1 << 24)) != 0,
                          let target = branchTarget(word, pc: pc) {
                    if let id = pendingCallSite, let name = stubs[target] {
                        matches.append(CallSiteMatch(callSiteIndex: id, callAddress: pc, symbol: name))
                    }
                    pendingCallSite = nil
                }
                pc &+= 4
            }
        } else {
            warnings.append("SJLJ context base/call_site stack slot was not recovered")
        }

        var cleanupImports = Set<DependencySite>()
        if let start = cleanupStart, let end = cleanupEnd, start < end {
            pc = start
            while pc < end {
                let word = try readWord(pc, memory: memory)
                if ((word >> 25) & 7) == 5,
                   (word & (1 << 24)) != 0,
                   let target = branchTarget(word, pc: pc),
                   let name = stubs[target] {
                    cleanupImports.insert(DependencySite(address: pc, symbol: name, path: .exceptionCleanup))
                }
                pc &+= 4
            }
        }

        return SJLJFunctionResult(function: bounds, lsdaAddress: lsda,
                                  registrationCall: registration, resumeCall: resume,
                                  cleanupStart: cleanupStart, cleanupEnd: cleanupEnd,
                                  table: table, matches: matches,
                                  cleanupImports: Array(cleanupImports), warnings: warnings)
    }

    private static func findSJLJContextBase(_ bounds: FunctionBounds,
                                            before registration: UInt32,
                                            memory: RE4GuestMemoryReading) throws -> UInt32? {
        var result: UInt32?
        var pc = bounds.start
        while pc < registration {
            let word = try readWord(pc, memory: memory)
            if let offset = isAddR0SPImmediate(word) { result = offset }
            pc &+= 4
        }
        return result
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    public static func inspect(
        image: RE4MachO32Image,
        memory: RE4GuestMemoryReading,
        maxInstructionsPerInitializer: Int = 4096,
        maxCallDepth: Int = 3
    ) throws -> RE4MachO32InitializerControlFlowAuditResult {
        let initSections = image.segments.flatMap { segment in
            segment.sections.filter {
                $0.segmentName == "__DATA" && $0.name == "__mod_init_func" && $0.type == 9
            }
        }
        guard initSections.count == 1, let section = initSections.first else {
            throw AuditError.initializerSectionMissing
        }
        guard section.address & 3 == 0, section.size > 0, section.size & 3 == 0,
              UInt64(section.size) / 4 <= 4096,
              let (_, text) = textSection(image),
              let eh = exceptSection(image) else {
            throw AuditError.malformed("initializer/text/exception-table sections are missing or malformed")
        }
        let stubs = stubSymbols(image)
        let functionSymbolRanges = functionSymbols(image)
        let count = Int(section.size / 4)
        var dependencyLines = ["Initializer_Index,Initializer_Slot_VA,Initializer_Target_VA,Initializer_Label,Functions_Visited,Normal_Imports,Normal_Call_Sites,Conditional_Imports,Conditional_Call_Sites,Exception_Cleanup_Imports,Exception_Cleanup_Call_Sites,LSDA_Functions,LSDA_Callsites,Matched_SJLJ_Callsites,CFG_Instructions,Max_Call_Depth,Unresolved_Count,Worklist_Budget_Reached,Guest_Execution"]
        var edgeLines = ["Initializer_Index,Function_Symbol,Source_VA,Target_VA,Edge_Type,Condition,Path,Detail"]
        var crosswalkLines = ["Initializer_Index,Function_Symbol,LSDA_VA,Table_Row,Callsite_Dispatch_Index,Action,Matched_Call_VA,Imported_Symbol,Match_Status"]
        var report = [
            "Stage J.1 — Control-Flow & SJLJ Landing-Pad Audit (read-only)",
            "Initializer section: __DATA,__mod_init_func (S_MOD_INIT_FUNC_POINTERS)",
            String(format: "Initializer section VA: 0x%08X; entries: %d", section.address, count),
            String(format: "__text VA: 0x%08X; size: 0x%X", text.address, text.size),
            String(format: "__gcc_except_tab VA: 0x%08X; size: 0x%X", eh.address, eh.size),
            "Control-flow: conditional direct B explores taken and fallthrough successors using a bounded worklist.",
            "Path categories: normal, conditional/alternative, and separately identified exception-cleanup blocks.",
            "No ARM/Thumb instruction, initializer, constructor, dyld helper, personality routine, unwinder, or landing pad was executed.",
            ""
        ]
        var totals: [String: Set<DependencySite>] = [
            "normal": [], "conditional": [], "exception_cleanup": []
        ]
        var sjljFunctionCount = 0
        var sjljRowsCount = 0
        var sjljMatchesCount = 0
        var budgetCount = 0
        var edgeCount = 0

        for index in 0..<count {
            let slot = section.address &+ UInt32(index * 4)
            let raw = try readWord(slot, memory: memory)
            let transition = RE4ARMv6InstructionSetState.resolveBX(from: .arm, registerTarget: raw)
            let target = transition.targetAddress
            var state = InitializerState()
            state.functionSymbolRanges = functionSymbolRanges
            if transition.targetState == .arm, inText(target, image),
               let bounds = functionBounds(at: target, image: image, symbols: functionSymbolRanges) {
                try scanFunction(at: target, path: .normal, depth: 0,
                                 initializerIndex: index + 1, image: image,
                                 memory: memory, stubs: stubs,
                                 maxDepth: max(0, min(maxCallDepth, 8)),
                                 maxInstructions: max(1, min(maxInstructionsPerInitializer, 16384)),
                                 state: &state)
                // Resolve all SJLJ-registered functions reached by this initializer's bounded CFG.
                var sjljResults: [SJLJFunctionResult] = []
                for function in state.functions.values.sorted(by: { $0.start < $1.start }) {
                    if let result = try findSJLJ(function, image: image, memory: memory, stubs: stubs) {
                        sjljResults.append(result)
                        state.dependencies.formUnion(result.cleanupImports)
                    }
                }
                let normal = state.dependencies.filter { $0.path == .normal }
                let conditional = state.dependencies.filter { $0.path == .conditional }
                let exceptional = state.dependencies.filter { $0.path == .exceptionCleanup }
                totals["normal", default: []].formUnion(normal)
                totals["conditional", default: []].formUnion(conditional)
                totals["exception_cleanup", default: []].formUnion(exceptional)
                if state.budgetReached { budgetCount += 1 }
                sjljFunctionCount += sjljResults.count
                sjljRowsCount += sjljResults.reduce(0) { $0 + $1.table.count }
                sjljMatchesCount += sjljResults.reduce(0) { $0 + $1.matches.count }
                edgeCount += state.edges.count

                let importedList: (Set<DependencySite>) -> String = { sites in
                    Dictionary(grouping: sites, by: \.symbol).keys.sorted().map { name in
                        let count = sites.filter { $0.symbol == name }.count
                        return "\(name) x\(count)"
                    }.joined(separator: ";")
                }
                let allNormal = Set(normal), allConditional = Set(conditional), allExceptional = Set(exceptional)
                let labels = bounds.symbol
                let dependencyCells: [String] = [
                    String(index + 1),
                    String(format: "0x%08X", slot),
                    String(format: "0x%08X", target),
                    csv(labels),
                    String(state.functions.count),
                    csv(importedList(allNormal)),
                    String(allNormal.count),
                    csv(importedList(allConditional)),
                    String(allConditional.count),
                    csv(importedList(allExceptional)),
                    String(allExceptional.count),
                    String(sjljResults.count),
                    String(sjljResults.reduce(0) { $0 + $1.table.count }),
                    String(sjljResults.reduce(0) { $0 + $1.matches.count }),
                    String(state.instructionCount),
                    String(state.maxDepthReached),
                    String(state.unresolved.count),
                    state.budgetReached ? "YES" : "NO",
                    "NO"
                ]
                dependencyLines.append(dependencyCells.joined(separator: ","))

                for edge in state.edges {
                    edgeLines.append([
                        String(edge.initializerIndex), csv(edge.functionSymbol),
                        String(format: "0x%08X", edge.source),
                        edge.target.map { String(format: "0x%08X", $0) } ?? "",
                        edge.edgeType, edge.condition, edge.path.rawValue, csv(edge.detail)
                    ].joined(separator: ","))
                }
                for result in sjljResults {
                    let matchByIndex = Dictionary(result.matches.map { ($0.callSiteIndex, $0) },
                                                  uniquingKeysWith: { first, _ in first })
                    for row in result.table {
                        let match = matchByIndex[row.landingPadIndex]
                        crosswalkLines.append([
                            String(index + 1), csv(result.function.symbol),
                            result.lsdaAddress.map { String(format: "0x%08X", $0) } ?? "",
                            String(row.tableIndex), String(row.landingPadIndex), String(row.action),
                            match.map { String(format: "0x%08X", $0.callAddress) } ?? "",
                            match.map { csv($0.symbol) } ?? "",
                            match == nil ? "NO_STATIC_CALLSITE_MATCH" : "MATCHED"
                        ].joined(separator: ","))
                    }
                    for warning in result.warnings {
                        report.append("Initializer #\(index + 1) / \(result.function.symbol): \(warning)")
                    }
                    if !result.table.isEmpty || result.registrationCall != nil {
                        report.append(String(format: "SJLJ: %@; function 0x%08X; LSDA %@; register %@; table rows %d; call-site matches %d; cleanup %@..%@",
                                             result.function.symbol, result.function.start,
                                             result.lsdaAddress.map { String(format: "0x%08X", $0) } ?? "unresolved",
                                             result.registrationCall.map { String(format: "0x%08X", $0) } ?? "unresolved",
                                             result.table.count, result.matches.count,
                                             result.cleanupStart.map { String(format: "0x%08X", $0) } ?? "none",
                                             result.cleanupEnd.map { String(format: "0x%08X", $0) } ?? "none"))
                    }
                }
                if !state.unresolved.isEmpty {
                    report.append("Initializer #\(index + 1) unresolved: \(state.unresolved.sorted().joined(separator: "; "))")
                }
            } else {
                dependencyLines.append([
                    String(index + 1), String(format: "0x%08X", slot), String(format: "0x%08X", target),
                    transition.targetState == .thumb ? "<Thumb body not decoded>" : "<target outside __text>",
                    "0", "", "0", "", "0", "", "0", "0", "0", "0", "0", "0", "1", "NO", "NO"
                ].joined(separator: ","))
            }
        }

        func summary(_ path: String) -> String {
            let sites = totals[path] ?? []
            let grouped = Dictionary(grouping: sites, by: \.symbol)
            return grouped.keys.sorted().map { "\($0) x\(grouped[$0]?.count ?? 0)" }.joined(separator: "; ")
        }
        report += [
            "",
            "[Dependency totals by path — static call sites, not dynamic invocation counts]",
            "Normal: \(summary("normal"))",
            "Conditional/alternative: \(summary("conditional"))",
            "Exception cleanup: \(summary("exception_cleanup"))",
            "",
            "[Audit totals]",
            "Initializer entries processed: \(count)",
            "Control-flow edges recorded: \(edgeCount)",
            "SJLJ functions correlated: \(sjljFunctionCount)",
            "SJLJ call-site table rows parsed: \(sjljRowsCount)",
            "SJLJ code call-site matches: \(sjljMatchesCount)",
            "Initializers hitting instruction budget: \(budgetCount)",
            "Guest instructions executed: NO",
            "Initializer / constructor / dyld helper / personality / unwinder invoked: NO",
            "Guest Memory writes performed: NO",
            "",
            "[Interpretation limits]",
            "The worklist follows both successors of direct conditional ARM B instructions; it does not solve arbitrary register targets, data-dependent control flow, indirect calls, interworking into Thumb, or all ARM instruction semantics.",
            "Function ranges are symbol-bounded using the nearest defined __TEXT,__text N_FUN or N_SECT symbol. Inferred boundaries may not describe every hand-written assembly or inline-data case.",
            "Exception-cleanup classification is a static branch-over-block pattern around __Unwind_SjLj_Resume plus a matching SJLJ/LSDA record; no personality dispatch or landing-pad execution was tested.",
            "SJLJ call-site rows are decoded as ULEB128 (landing-pad-index, action) pairs. A matched row proves static index/code correspondence, not that a runtime exception actually takes the path.",
            "One static destructor call instruction may execute multiple times in its cleanup loop.",
            "A missing dependency in a given path is not proof that no indirect or data-dependent dependency exists."
        ]

        return RE4MachO32InitializerControlFlowAuditResult(
            report: report.joined(separator: "\n") + "\n",
            dependencyCSV: dependencyLines.joined(separator: "\n") + "\n",
            edgeCSV: edgeLines.joined(separator: "\n") + "\n",
            sjljCrosswalkCSV: crosswalkLines.joined(separator: "\n") + "\n"
        )
    }

    /// Synthetic parser/edge tests. This never maps or executes guest code.
    public static func runSyntheticSelfTest() throws -> String {
        // A tiny SJLJ header: omit LPStart, omit TType, ULEB call-site encoding,
        // 40-byte table containing (0,0)..(19,0).
        var bytes: [UInt8] = [0xFF, 0xFF, 0x03, 0x28]
        for index in 0..<20 { bytes.append(UInt8(index)); bytes.append(0) }
        guard let parsed = parseSJLJCallSiteTable(bytes),
              parsed.encoding == 0x03,
              parsed.rows.count == 20,
              parsed.rows.first?.landingPadIndex == 1,
              parsed.rows.last?.landingPadIndex == 20,
              parsed.rows.allSatisfy({ $0.action == 0 }) else {
            throw AuditError.selfTestFailed("20-entry SJLJ ULEB128 call-site table")
        }

        // Verify signed ARM B target decoding and explicit conditional taken/fallthrough split.
        // BNE +2 at PC 0x1000 reaches 0x1010; fallthrough is 0x1004.
        let branch: UInt32 = 0x1A000002
        guard branchTarget(branch, pc: 0x1000) == 0x1010,
              conditionName((branch >> 28) & 0xF) == "NE" else {
            throw AuditError.selfTestFailed("conditional branch target/condition decoding")
        }
        let successors: Set<UInt32> = [branchTarget(branch, pc: 0x1000)!, 0x1004]
        guard successors == Set([UInt32(0x1010), UInt32(0x1004)]) else {
            throw AuditError.selfTestFailed("conditional branch taken plus fallthrough successors")
        }

        return "Stage J.1 control-flow / SJLJ synthetic self-test PASS\n" +
            "Conditional ARM B target and fallthrough successors: PASS\n" +
            "SJLJ 20-row ULEB128 call-site table parse: PASS\n" +
            "Dispatch indices (cs_lp + 1): 1..20; action values: 0\n" +
            "Generated metadata and arithmetic only; no Guest Memory write or guest execution."
    }
}
