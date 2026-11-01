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
