import Foundation

@main
struct StageJ812VFPStackTransferTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "J8.12", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func makeMemory() -> RE4GuestARMv6Memory {
        RE4GuestARMv6Memory(size: 0x20000, heapBase: 0x10000,
                            stackTop: 0x1F000, returnSentinel: 0xFFF000)
    }

    static func makeCore(_ memory: RE4GuestARMv6Memory? = nil) -> RE4GuestARMv6Core {
        RE4GuestARMv6Core(memory: memory ?? makeMemory())
    }

    static func seedRegisters(
        _ core: RE4GuestARMv6Core,
        base: UInt64 = 0x1122334455667700
    ) throws -> [UInt64] {
        var values: [UInt64] = []
        for index in 0..<8 {
            let value = base &+ UInt64(index) &* 0x0101010101010101
            try core.setVFPDoubleRegisterValue(8 + index, value: value)
            values.append(value)
        }
        return values
    }

    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body()
            passed += 1
            print("PASS: \(name)")
        }

        try test("01 D8-D15 map to paired S16-S31 words without truncation") {
            let core = makeCore()
            let expected = try seedRegisters(core)
            let snapshot = try core.captureVFPD8ThroughD15Snapshot()
            try check(snapshot.d8ThroughD15 == expected, "double-register mapping mismatch")
            for index in 0..<8 {
                try core.setVFPDoubleRegisterValue(8 + index, value: 0)
            }
            try core.restoreVFPD8ThroughD15Snapshot(snapshot)
            let restored = try core.captureVFPD8ThroughD15Snapshot()
            try check(restored == snapshot, "VFP bank snapshot did not restore")
        }

        try test("02 VPUSH decrements SP and writes all 64 bytes in D-register order") {
            let memory = makeMemory()
            let core = makeCore(memory)
            let expected = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0xF000)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            _ = try core.step()

            let pushedSP = try core.registerValue(13)
            try check(pushedSP == 0xEFC0, "VPUSH must decrement SP by 64")
            for index in 0..<8 {
                let low = try memory.read32(0xEFC0 + UInt32(index * 8))
                let high = try memory.read32(0xEFC4 + UInt32(index * 8))
                let value = (UInt64(high) << 32) | UInt64(low)
                try check(value == expected[index], "memory order mismatch for D\(8 + index)")
            }
            let pc = try core.registerValue(15)
            try check(pc == 0x1004, "ARM instruction PC advancement changed")
        }

        try test("03 VPOP restores all D8-D15 and increments SP after a full read") {
            let memory = makeMemory()
            let core = makeCore(memory)
            let expected = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0xF000)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            try memory.write32(0x1004, 0xECBD8B10)
            _ = try core.step()
            for index in 0..<8 {
                try core.setVFPDoubleRegisterValue(8 + index, value: 0xDEADBEEFDEADBEEF)
            }
            _ = try core.step()

            let bank = try core.captureVFPD8ThroughD15Snapshot().d8ThroughD15
            let poppedSP = try core.registerValue(13)
            try check(bank == expected, "VPOP failed to restore the saved VFP bank")
            try check(poppedSP == 0xF000, "VPOP must restore the original stack pointer")
        }

        try test("04 VPUSH writes one contiguous 64-byte Guest Memory image") {
            let memory = makeMemory()
            let core = makeCore(memory)
            _ = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0xF000)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            _ = try core.step()
            let payload = try memory.copyBytes(at: 0xEFC0, count: 64)
            let sp = try core.registerValue(13)
            try check(payload.count == 64 && sp == 0xEFC0,
                      "contiguous stack image or SP publication mismatch")
            try check(core.supportsVFPD8ThroughD15StackTransfers,
                      "VFP capability must be enabled only after implementation")
        }

        try test("05 Failed VPOP leaves SP and all D registers unchanged") {
            let memory = makeMemory()
            let core = makeCore(memory)
            let before = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0x30000000)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xECBD8B10)
            do {
                _ = try core.step()
                throw NSError(domain: "J8.12", code: 2)
            } catch RE4GuestRuntimeError.invalidMemoryRange { }
            let sp = try core.registerValue(13)
            let bank = try core.captureVFPD8ThroughD15Snapshot().d8ThroughD15
            try check(sp == 0x30000000, "failed VPOP changed SP")
            try check(bank == before, "failed VPOP partially changed D8-D15")
        }

        try test("06 Failed VPUSH leaves SP and D registers unchanged") {
            let memory = makeMemory()
            let core = makeCore(memory)
            let before = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0x30000020)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            do {
                _ = try core.step()
                throw NSError(domain: "J8.12", code: 3)
            } catch RE4GuestRuntimeError.invalidMemoryRange { }
            let sp = try core.registerValue(13)
            let bank = try core.captureVFPD8ThroughD15Snapshot().d8ThroughD15
            try check(sp == 0x30000020, "failed VPUSH changed SP")
            try check(bank == before, "failed VPUSH changed D8-D15")
        }

        try test("07 VPUSH supports sparse Guest stack regions and shadow backing") {
            let memory = makeMemory()
            let backing = RE4GuestMemoryBacking(data: Data(repeating: 0, count: 0x1000))
            try memory.mountRegion(RE4GuestMemoryRegion(
                name: "TEST_VFP_STACK", guestBase: 0x30000000, length: 0x1000,
                backing: backing, backingOffset: 0,
                maxProtection: [.read, .write], initialProtection: [.read, .write]
            ))
            let core = makeCore(memory)
            let expected = try seedRegisters(core)
            try core.setRegisterValue(13, value: 0x30000100)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            _ = try core.step()

            let sp = try core.registerValue(13)
            try check(sp == 0x300000C0, "sparse stack SP mismatch")
            for index in 0..<8 {
                let low = try memory.read32(0x300000C0 + UInt32(index * 8))
                let high = try memory.read32(0x300000C4 + UInt32(index * 8))
                let value = (UInt64(high) << 32) | UInt64(low)
                try check(value == expected[index], "sparse D\(8 + index) payload mismatch")
            }
            try check(backing.dirtyPageCount == 1, "sparse write must use one shadow page")
        }

        try test("08 VPUSH underflow and VPOP overflow fail closed") {
            let memory = makeMemory()
            let core = makeCore(memory)
            try seedRegisters(core)
            try core.setRegisterValue(13, value: 0x20)
            try core.setRegisterValue(15, value: 0x1000)
            try memory.write32(0x1000, 0xED2D8B10)
            do {
                _ = try core.step()
                throw NSError(domain: "J8.12", code: 4)
            } catch RE4GuestRuntimeError.vfpStackPointerUnderflow(0x20) { }
            let underflowSP = try core.registerValue(13)
            try check(underflowSP == 0x20, "underflow changed SP")

            try core.setRegisterValue(13, value: 0xFFFFFFF0)
            try core.setRegisterValue(15, value: 0x1004)
            try memory.write32(0x1004, 0xECBD8B10)
            do {
                _ = try core.step()
                throw NSError(domain: "J8.12", code: 5)
            } catch RE4GuestRuntimeError.vfpStackPointerOverflow(0xFFFFFFF0) { }
            let overflowSP = try core.registerValue(13)
            try check(overflowSP == 0xFFFFFFF0, "overflow changed SP")
        }

        try test("09 VFP accessors reject every register outside D8-D15") {
            let core = makeCore()
            for invalid in [7, 16, -1] {
                do {
                    _ = try core.vfpDoubleRegisterValue(invalid)
                    throw NSError(domain: "J8.12", code: 6)
                } catch RE4GuestRuntimeError.invalidVFPDoubleRegister(invalid) { }
            }
        }

        try test("10 malformed VFP snapshot shape is rejected") {
            do {
                _ = try RE4StageJ812VFPRegisterSnapshot(
                    d8ThroughD15: Array(repeating: 0, count: 7))
                throw NSError(domain: "J8.12", code: 7)
            } catch RE4StageJ812VFPError.invalidDoubleRegisterCount(7) { }
        }

        print("RESULT: \(passed)/10 passed; 0 failed")
        print("SCOPE: real D8-D15 bank mapping and VPUSH/VPOP Guest Memory transfers; no BX, Thumb execution, provider call or original game code.")
    }
}
