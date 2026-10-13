import Foundation

public enum RE4MachO32HLEBinderError: Error, LocalizedError {
    case thunkRegionOutOfBounds
    case thunkRegionOverlapsSegment(String)
    case invalidPointerSite(UInt32)
    case argumentOverflow
    case stringNotTerminated(UInt32)
    case unsupportedSymbol(String)

    public var errorDescription: String? {
        switch self {
        case .thunkRegionOutOfBounds: return "HLE trap address region does not fit in guest memory."
        case .thunkRegionOverlapsSegment(let name): return "HLE trap region overlaps Mach-O segment \(name)."
        case .invalidPointerSite(let address): return String(format: "Import pointer site 0x%08X is invalid.", address)
        case .argumentOverflow: return "C ABI size/count arguments exceed guest memory limits."
        case .stringNotTerminated(let address): return String(format: "Guest C string at 0x%08X has no terminator within scan limits.", address)
        case .unsupportedSymbol(let name): return "HLE function \(name) is not implemented in this runtime subset."
        }
    }
}

public struct RE4MachO32HLEBindingResult {
    public let thunkAddressBySymbol: [String: UInt32]
    public let symbolByThunkAddress: [UInt32: String]
    public let patchedPointerSites: Int
    public let coveredStubSites: Int
    public let unresolvedSymbols: [String]
    public let bindingBase: UInt32

    public var report: String {
        var lines = [
            "Mach-O HLE binding PASS",
            String(format: "HLE trap base: 0x%08X", bindingBase),
            "Known function symbols bound: \(thunkAddressBySymbol.count)",
            "Import pointer slots patched: \(patchedPointerSites)",
            "Symbol-stub sites covered (stub bytes unchanged): \(coveredStubSites)",
            "Unimplemented unique symbols remaining: \(unresolvedSymbols.count)",
            "",
            "[Implemented HLE symbols]"
        ]
        for name in thunkAddressBySymbol.keys.sorted() {
            lines.append(String(format: "%@ -> 0x%08X", name, thunkAddressBySymbol[name]!))
        }
        lines += ["", "[Unresolved symbol examples]"]
        lines += unresolvedSymbols.prefix(24)
        if unresolvedSymbols.count > 24 { lines.append("… plus \(unresolvedSymbols.count - 24) more") }
        else if unresolvedSymbols.isEmpty { lines.append("(none)") }
        lines += ["", "Only the explicit HLE subset was patched. No game code or initializer ran."]
        return lines.joined(separator: "\n")
    }
}

public enum RE4MachO32HLEBinder {
    public static let defaultTrapBase: UInt32 = 0x04E00000
    public static let implementedFunctions: Set<String> = [
        "_malloc", "_calloc", "_realloc", "_free",
        "_memcpy", "_memmove", "_memset", "_memcmp", "_memchr",
        "_strlen", "_strnlen", "_strcmp", "_strncmp", "_strcpy", "_strncpy", "_strchr"
    ]

    private static func leData(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    public static func bind(_ image: RE4MachO32Image, into memory: RE4GuestARMv6Memory,
                            trapBase: UInt32 = defaultTrapBase) throws -> RE4MachO32HLEBindingResult {
        let plan = try RE4MachO32ImportBindingPlanner.makePlan(image, guestMemorySize: memory.size)
        let candidates = plan.symbolPlans.filter { symbol in
            implementedFunctions.contains(symbol.name) &&
            symbol.sites.contains { $0.kind == .lazyPointer || $0.kind == .nonLazyPointer }
        }.sorted { $0.name < $1.name }

        let trapEnd = UInt64(trapBase) + UInt64(candidates.count) * 4
        guard trapEnd >= UInt64(trapBase), trapEnd <= UInt64(memory.size) else {
            throw RE4MachO32HLEBinderError.thunkRegionOutOfBounds
        }
        for segment in image.segments where !segment.isPageZero && segment.vmSize > 0 {
            let start = UInt64(segment.vmAddress), end = start + UInt64(segment.vmSize)
            if UInt64(trapBase) < end && trapEnd > start {
                throw RE4MachO32HLEBinderError.thunkRegionOverlapsSegment(segment.name)
            }
        }

        var thunkByName: [String: UInt32] = [:]
        var nameByThunk: [UInt32: String] = [:]
        for (i, symbol) in candidates.enumerated() {
            let address = trapBase &+ UInt32(i * 4)
            thunkByName[symbol.name] = address
            nameByThunk[address] = symbol.name
        }

        var patches: [(UInt32, UInt32)] = []
        var coveredStubs = 0
        for symbol in candidates {
            guard let thunk = thunkByName[symbol.name] else { continue }
            for site in symbol.sites {
                switch site.kind {
                case .lazyPointer, .nonLazyPointer:
                    guard site.entrySize == 4 else {
                        throw RE4MachO32HLEBinderError.invalidPointerSite(site.siteAddress)
                    }
                    let end = UInt64(site.siteAddress) + 4
                    let inSegment = image.segments.contains {
                        !$0.isPageZero && UInt64(site.siteAddress) >= UInt64($0.vmAddress) &&
                        end <= UInt64($0.vmAddress) + UInt64($0.vmSize)
                    }
                    guard inSegment, end <= UInt64(memory.size) else {
                        throw RE4MachO32HLEBinderError.invalidPointerSite(site.siteAddress)
                    }
                    patches.append((site.siteAddress, thunk))
                case .symbolStub:
                    coveredStubs += 1 // Leave the code stub unchanged; it will indirect through the patched pointer.
                case .otherIndirect:
                    break
                }
            }
        }
        for (site, address) in patches { try memory.writeBytes(at: site, data: leData(address)) }
        let unresolved = plan.symbolPlans.map(\.name).filter { !implementedFunctions.contains($0) }.sorted()
        return RE4MachO32HLEBindingResult(
            thunkAddressBySymbol: thunkByName, symbolByThunkAddress: nameByThunk,
            patchedPointerSites: patches.count, coveredStubSites: coveredStubs,
            unresolvedSymbols: unresolved, bindingBase: trapBase
        )
    }

    public static func runSyntheticSelfTest() throws -> String {
        let fixture = try RE4MachO32Parser.makeSyntheticSelfTestFixture()
        let image = try RE4MachO32Parser.parse(fixture)
        let memory = RE4GuestARMv6Memory(size: 0x04000000, heapBase: 0x01000000,
                                         stackTop: 0x03F00000, returnSentinel: 0x00FFF000)
        _ = try RE4MachO32Loader.map(image, into: memory)
        let trapBase: UInt32 = 0x03E00000
        let binding = try bind(image, into: memory, trapBase: trapBase)
        guard binding.thunkAddressBySymbol["_malloc"] == trapBase,
              binding.patchedPointerSites == 1,
              try memory.read32(0x3000) == trapBase else {
            throw RE4MachO32HLETestError.failed("lazy pointer did not resolve to _malloc HLE trap")
        }

        var traps = binding.symbolByThunkAddress
        traps[trapBase &+ 4] = "_memset"
        traps[trapBase &+ 8] = "_memcpy"
        let dispatcher = RE4GuestARMv6HLEDispatcher(memory: memory, symbolByThunkAddress: traps)
        let cpu = RE4GuestARMv6Core(memory: memory)
        cpu.instructionHook = { pc, activeCPU in
            try dispatcher.handleInstruction(at: pc, cpu: activeCPU)
        }

        let mallocResult = try cpu.run(entry: trapBase, arguments: [32])
        let pointer = mallocResult.registers[0]
        guard pointer >= 0x01000000, pointer < 0x03EF0000, try memory.read8(pointer) == 0 else {
            throw RE4MachO32HLETestError.failed("_malloc returned an invalid allocation")
        }
        _ = try cpu.run(entry: trapBase &+ 4, arguments: [pointer, 0x5A, 4])
        guard try memory.copyBytes(at: pointer, count: 4) == Data([0x5A, 0x5A, 0x5A, 0x5A]) else {
            throw RE4MachO32HLETestError.failed("_memset wrote unexpected bytes")
        }
        _ = try cpu.run(entry: trapBase &+ 8, arguments: [pointer &+ 8, pointer, 4])
        guard try memory.copyBytes(at: pointer &+ 8, count: 4) == Data([0x5A, 0x5A, 0x5A, 0x5A]) else {
            throw RE4MachO32HLETestError.failed("_memcpy copied unexpected bytes")
        }
        return "Mach-O HLE binder/dispatcher self-test PASS\nLazy pointer 0x00003000 patched to _malloc trap.\nARM host-call returned through LR.\n_malloc allocated guest memory; _memset and _memcpy traps passed.\nNo original game code or assets executed."
    }
}

public final class RE4GuestARMv6HLEDispatcher {
    private let memory: RE4GuestARMv6Memory
    private let symbolByThunkAddress: [UInt32: String]
    private var allocationSizes: [UInt32: Int] = [:]
    private let maxCStringScan = 16 * 1024 * 1024

    public init(memory: RE4GuestARMv6Memory, symbolByThunkAddress: [UInt32: String]) {
        self.memory = memory
        self.symbolByThunkAddress = symbolByThunkAddress
    }

    public func handleInstruction(at pc: UInt32, cpu: RE4GuestARMv6Core) throws -> Bool {
        guard let symbol = symbolByThunkAddress[pc] else { return false }
        let result = try invoke(symbol: symbol, cpu: cpu)
        cpu.completeHostCall(returnValue: result)
        return true
    }

    private func arg(_ n: Int, _ cpu: RE4GuestARMv6Core) throws -> UInt32 {
        try cpu.registerValue(n)
    }

    private func checkedCount(_ value: UInt32) throws -> Int {
        guard UInt64(value) <= UInt64(memory.size) else { throw RE4MachO32HLEBinderError.argumentOverflow }
        return Int(value)
    }

    private func byte(at pointer: UInt32, offset: Int) throws -> UInt8 {
        guard offset >= 0, UInt64(offset) <= UInt64(UInt32.max) else {
            throw RE4MachO32HLEBinderError.argumentOverflow
        }
        let (address, overflow) = pointer.addingReportingOverflow(UInt32(offset))
        guard !overflow else { throw RE4MachO32HLEBinderError.argumentOverflow }
        return try memory.read8(address)
    }

    private func cStringLength(_ pointer: UInt32, limit: Int) throws -> Int {
        if limit == 0 { return 0 }
        guard Int(pointer) < memory.size else { throw RE4MachO32HLEBinderError.argumentOverflow }
        let allowed = min(max(0, limit), memory.size - Int(pointer))
        var offset = 0
        while offset < allowed {
            let amount = min(4096, allowed - offset)
            let (address, overflow) = pointer.addingReportingOverflow(UInt32(offset))
            guard !overflow else { throw RE4MachO32HLEBinderError.argumentOverflow }
            let bytes = try memory.copyBytes(at: address, count: amount)
            if let end = bytes.firstIndex(of: 0) { return offset + end }
            offset += amount
        }
        throw RE4MachO32HLEBinderError.stringNotTerminated(pointer)
    }

    private func compareStrings(_ lhs: UInt32, _ rhs: UInt32, limit: Int) throws -> Int32 {
        if limit == 0 { return 0 }
        for offset in 0..<limit {
            let a = try byte(at: lhs, offset: offset)
            let b = try byte(at: rhs, offset: offset)
            if a != b { return Int32(a) - Int32(b) }
            if a == 0 { return 0 }
        }
        return 0
    }

    private func invoke(symbol: String, cpu: RE4GuestARMv6Core) throws -> UInt32 {
        let r0 = try arg(0, cpu), r1 = try arg(1, cpu), r2 = try arg(2, cpu)
        switch symbol {
        case "_malloc":
            let count = try checkedCount(r0)
            let ptr = try memory.allocate(count)
            allocationSizes[ptr] = max(1, count)
            return ptr
        case "_calloc":
            let product = UInt64(r0) * UInt64(r1)
            guard product <= UInt64(memory.size) else { throw RE4MachO32HLEBinderError.argumentOverflow }
            let count = Int(product)
            let ptr = try memory.allocate(count)
            allocationSizes[ptr] = max(1, count)
            return ptr
        case "_realloc":
            let count = try checkedCount(r1)
            if r0 == 0 {
                let ptr = try memory.allocate(count)
                allocationSizes[ptr] = max(1, count)
                return ptr
            }
            if count == 0 { allocationSizes.removeValue(forKey: r0); return 0 }
            let ptr = try memory.allocate(count)
            let old = allocationSizes[r0] ?? 0
            if old > 0 {
                let bytes = try memory.copyBytes(at: r0, count: min(old, count))
                try memory.writeBytes(at: ptr, data: bytes)
            }
            allocationSizes.removeValue(forKey: r0)
            allocationSizes[ptr] = max(1, count)
            return ptr
        case "_free":
            if r0 != 0 { allocationSizes.removeValue(forKey: r0) }
            return 0
        case "_memcpy", "_memmove":
            let n = try checkedCount(r2)
            let bytes = try memory.copyBytes(at: r1, count: n)
            try memory.writeBytes(at: r0, data: bytes)
            return r0
        case "_memset":
            let n = try checkedCount(r2)
            try memory.writeBytes(at: r0, data: Data(repeating: UInt8(truncatingIfNeeded: r1), count: n))
            return r0
        case "_memcmp":
            let n = try checkedCount(r2)
            let a = [UInt8](try memory.copyBytes(at: r0, count: n))
            let b = [UInt8](try memory.copyBytes(at: r1, count: n))
            for i in 0..<n where a[i] != b[i] { return UInt32(bitPattern: Int32(a[i]) - Int32(b[i])) }
            return 0
        case "_memchr":
            let n = try checkedCount(r2)
            let bytes = [UInt8](try memory.copyBytes(at: r0, count: n))
            guard let i = bytes.firstIndex(of: UInt8(truncatingIfNeeded: r1)) else { return 0 }
            let (ptr, overflow) = r0.addingReportingOverflow(UInt32(i))
            guard !overflow else { throw RE4MachO32HLEBinderError.argumentOverflow }
            return ptr
        case "_strlen":
            return UInt32(try cStringLength(r0, limit: maxCStringScan))
        case "_strnlen":
            return UInt32(try cStringLength(r0, limit: min(try checkedCount(r1), maxCStringScan)))
        case "_strcmp":
            return UInt32(bitPattern: try compareStrings(r0, r1, limit: maxCStringScan))
        case "_strncmp":
            return UInt32(bitPattern: try compareStrings(r0, r1, limit: min(try checkedCount(r2), maxCStringScan)))
        case "_strcpy", "_strncpy":
            let maxCount = symbol == "_strncpy" ? try checkedCount(r2) : maxCStringScan
            var result: [UInt8] = []
            result.reserveCapacity(min(maxCount, 4096))
            var sawNul = false
            for i in 0..<maxCount {
                let value = try byte(at: r1, offset: i)
                result.append(value)
                if value == 0 {
                    sawNul = true
                    if symbol == "_strcpy" { break }
                    while result.count < maxCount { result.append(0) }
                    break
                }
            }
            if symbol == "_strcpy" && !sawNul { throw RE4MachO32HLEBinderError.stringNotTerminated(r1) }
            try memory.writeBytes(at: r0, data: Data(result))
            return r0
        case "_strchr":
            let target = UInt8(truncatingIfNeeded: r1)
            for i in 0..<maxCStringScan {
                let value = try byte(at: r0, offset: i)
                if value == target {
                    let (ptr, overflow) = r0.addingReportingOverflow(UInt32(i))
                    guard !overflow else { throw RE4MachO32HLEBinderError.argumentOverflow }
                    return ptr
                }
                if value == 0 { return 0 }
            }
            throw RE4MachO32HLEBinderError.stringNotTerminated(r0)
        default:
            throw RE4MachO32HLEBinderError.unsupportedSymbol(symbol)
        }
    }
}
private enum RE4MachO32HLETestError: Error { case failed(String) }
