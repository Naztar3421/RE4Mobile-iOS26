import Foundation

public enum RE4StageJ4ProviderRegressionTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    public static func run(fixtureURL: URL) throws -> String {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(message) }
        }
        func reg(_ registry: RE4StageJ4ProviderRegistry, _ ptr: UInt32,
                 _ arg: UInt32 = 0, _ dso: UInt32 = 0x1000) throws -> UInt64 {
            let r = registry.register(functionPointerRaw: ptr, argument: arg, dsoHandle: dso)
            guard r.returnCode == 0, let id = r.registrationID else { throw Failure("registration failed") }
            return id
        }
        var passed = 0
        var failed = 0
        var output: [String] = []
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; output.append("PASS — " + name) }
            catch { failed += 1; output.append("FAIL — " + name + ": " + String(describing:error)) }
        }

        test("01 ABI record layout and static initial node") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            let id = try reg(r, 0x35E0AFE9, 0x12345678)
            let x = r.recordSnapshot(registrationID:id)
            try check(RE4StageJ4ProviderRegistry.recordSize == 16 && RE4StageJ4ProviderRegistry.nodeHeaderSize == 8, "record/header size mismatch")
            try check(x?.kind == 2 && x?.functionPointerRaw == 0x35E0AFE9 && x?.argument == 0x12345678 && x?.dsoHandle == 0x1000, "record fields mismatch")
            try check(x?.nodeIsStatic == true && r.dynamicNodeAllocationSizes.isEmpty, "first node must be static")
        }
        test("02 32/33/64/65 node boundaries and global LIFO") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            for n in 1...65 {
                _ = try reg(r, UInt32(0x1000+n*4), UInt32(n))
                if n == 32 { try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [32], "32 boundary") }
                if n == 33 { try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [1,32], "33 boundary") }
                if n == 64 { try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [32,32], "64 boundary") }
                if n == 65 { try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [1,32,32], "65 boundary") }
            }
            try check(r.dynamicNodeAllocationSizes == [0x208,0x208], "dynamic allocations must be 0x208")
            let f = r.finalize(dsoHandle:0)
            try check(f.invocations.map(\.registrationID) == Array((1...65).reversed()).map(UInt64.init), "global LIFO mismatch")
            try check(f.remainingPendingCount == 0 && r.allRecordSnapshots.allSatisfy{$0.kind == 0}, "records not fully consumed")
        }
        test("03 nonzero DSO exact filter and zero wildcard") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            let a = try reg(r,0x1000,1,0x1000)
            let b = try reg(r,0x2000,2,0x2000)
            let c = try reg(r,0x3000,3,0x1000)
            let d = try reg(r,0x4000,4,0)
            try check(r.finalize(dsoHandle:0x1000).invocations.map(\.registrationID) == [c,a], "exact DSO filter")
            try check(r.finalize(dsoHandle:0).invocations.map(\.registrationID) == [d,b], "zero DSO must select all remaining records")
        }
        test("04 kind cleared before callback and cannot be replayed") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            let id = try reg(r,0x5000,0xCAFE)
            var observed = false
            let f = r.finalize(dsoHandle:0x1000) { p in
                observed = r.recordSnapshot(registrationID:p.registrationID)?.kind == 0
            }
            try check(observed && f.claimedRegistrationIDs == [id] && f.invocations.first?.kind == 2, "kind must clear before callback; copied record retained")
            try check(r.finalize(dsoHandle:0x1000).invocations.isEmpty, "consumed record replayed")
        }
        test("05 callback outside mutex; re-entry restarts at current root") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:true)
            let a = try reg(r,0x6000,1)
            let b = try reg(r,0x7000,2)
            var ids:[UInt64] = []
            var unlocked:[Bool] = []
            var c:UInt64?
            let f = r.finalize(dsoHandle:0) { p in
                ids.append(p.registrationID); unlocked.append(!r.mutexIsHeld)
                if p.registrationID == b { c = r.register(functionPointerRaw:0x8000,argument:3,dsoHandle:0x1000).registrationID }
            }
            try check(c != nil && ids == [b,c!,a], "root restart order mismatch")
            try check(unlocked.allSatisfy{$0} && f.restartCount == 1 && f.remainingPendingCount == 0, "callback/mutex/restart state mismatch")
            try check(!r.mutexIsHeld && r.events.contains(.restartFromCurrentRoot), "final mutex/restart state mismatch")
        }
        test("06 mutex calls are conditional on is_threaded") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            _ = try reg(r,0x9000)
            _ = r.finalize(dsoHandle:0) { _ in precondition(!r.mutexIsHeld) }
            try check(r.mutexEvents.isEmpty, "unthreaded path unexpectedly locked")
        }
        test("07 allocation root revalidation frees stale node and retries") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:true)
            for n in 1...32 { _ = try reg(r,UInt32(0xA000+n*4),UInt32(n),1) }
            var other:UInt64?
            let outer = r.register(functionPointerRaw:0xB000,argument:99,dsoHandle:1) {
                precondition(!r.mutexIsHeld)
                other = r.register(functionPointerRaw:0xC000,argument:98,dsoHandle:1).registrationID
            }
            try check(outer.registrationID != nil && other != nil && r.registrationCount == 34, "interleaved records lost")
            try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [2,32] && r.dynamicNodeFreedIDs.count == 1, "stale candidate was not freed/retried")
            let f = r.finalize(dsoHandle:0)
            try check(f.invocations.first?.registrationID == outer.registrationID && f.invocations.dropFirst().first?.registrationID == other, "post-retry LIFO order mismatch")
        }
        test("08 malloc failure returns -1 without partial append") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:true)
            for n in 1...32 { _ = try reg(r,UInt32(0xD000+n*4),0,1) }
            let f = r.register(functionPointerRaw:0xE000,argument:0,dsoHandle:1,allocatorSucceeds:false)
            try check(f.returnCode == -1 && f.registrationID == nil && r.registrationCount == 32, "allocation failure state mismatch")
            try check(!r.mutexIsHeld, "mutex should be released on allocation failure")
        }
        test("09 callback kinds 1/2/3 map to metadata descriptors") {
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            _ = r.registerRecord(kind:1,functionPointerRaw:0x1100,argument:0xAA,dsoHandle:1)
            _ = r.registerRecord(kind:2,functionPointerRaw:0x1200,argument:0xBB,dsoHandle:1)
            _ = r.registerRecord(kind:3,functionPointerRaw:0x1300,argument:0xCC,dsoHandle:1)
            let f = r.finalize(dsoHandle:1)
            try check(f.invocations.map(\.invocation) == [.objectFunctionAtOffset(0x0C),.functionWithArgument,.functionWithoutArgument], "kind dispatch mismatch")
        }
        test("10 Init C2 old=0 setup and second increment") {
            let m = RE4StageJ4IOSBaseInitModel(initialReferenceCount:0)
            let e = m.constructInstance()
            try check(e == [.atomicIncrement(oldValue:0,newValue:1),.synchronizedWithStdioSetTrue,.narrowStandardStreamsConstructed,.wideStandardStreamsConstructed,.secondAtomicIncrementAfterOneTimeSetup(oldValue:1,newValue:2)], "first C2 event sequence mismatch")
            try check(m.referenceCount == 2 && m.oneTimeStreamInitializationPasses == 1, "first C2 state mismatch")
        }
        test("11 subsequent C2 and D2 old=2 flushes six streams") {
            let m = RE4StageJ4IOSBaseInitModel(initialReferenceCount:0)
            _ = m.constructInstance()
            try check(m.constructInstance() == [.atomicIncrement(oldValue:2,newValue:3)], "subsequent C2 increment mismatch")
            try check(m.destroyInstance() == [.atomicDecrement(oldValue:3,newValue:2)], "old=3 must not flush")
            let expected = [RE4StageJ4IOSBaseInitEvent.atomicDecrement(oldValue:2,newValue:1)] + RE4StageJ4IOSBaseInitModel.flushTargets.map(RE4StageJ4IOSBaseInitEvent.standardStreamFlushed)
            try check(m.destroyInstance() == expected && m.flushPasses == 1, "old=2 flush sequence mismatch")
        }
        test("12 shared ios_base counter starts nonzero without setup") {
            let m = RE4StageJ4IOSBaseInitModel(initialReferenceCount:1)
            try check(m.constructInstance() == [.atomicIncrement(oldValue:1,newValue:2)] && m.oneTimeStreamInitializationPasses == 0, "nonzero C2 should skip setup")
            let d = m.destroyInstance()
            try check(d.count == 7 && d.first == .atomicDecrement(oldValue:2,newValue:1), "shared counter D2 flush mismatch")
        }
        test("13 replay all 240 Res4 registration rows as data") {
            let s = try String(contentsOf:fixtureURL,encoding:.utf8)
            let lines = s.split(whereSeparator:\.isNewline)
            try check(lines.count == 241, "fixture should have header plus 240 rows")
            let r = RE4StageJ4ProviderRegistry(isThreaded:false)
            var kinds:[String] = []
            var byInit:[String:[UInt64]] = [:]
            for line in lines.dropFirst() {
                let f = line.split(separator:",",omittingEmptySubsequences:false).map(String.init)
                guard f.count == 7, let seq = Int(f[0]), let ptr = UInt32(f[4].dropFirst(2),radix:16), let arg = UInt32(f[5].dropFirst(2),radix:16), let dso = UInt32(f[6].dropFirst(2),radix:16) else { throw Failure("fixture parse error") }
                try check(seq == r.registrationCount + 1, "fixture sequence gap")
                let id = try reg(r,ptr,arg,dso)
                byInit[f[1],default:[]].append(id); kinds.append(f[3])
            }
            try check(r.registrationCount == 240 && kinds.filter{$0 == "ios_base_Init_destructor"}.count == 238 && kinds.filter{$0 == "CMN_Timer_destructor"}.count == 1 && kinds.filter{$0 == "wide_string_destructor_loop"}.count == 1, "240-row callback class totals mismatch")
            try check(r.nodeSnapshotsNewestFirst.map(\.recordCount) == [16,32,32,32,32,32,32,32] && r.dynamicNodeAllocationSizes.count == 7, "240-row node packing mismatch")
            try check(r.allRecordSnapshots.allSatisfy{$0.kind == 2 && $0.argument == 0 && $0.dsoHandle == 0x1000}, "fixture record fields mismatch")
            let f = r.finalize(dsoHandle:0x1000)
            let order = f.invocations.map(\.registrationID)
            try check(order == Array((1...240).reversed()).map(UInt64.init), "240-row LIFO mismatch")
            try check(byInit["15"] == [15,16] && byInit["101"] == [100,101], "special registration pairs mismatch")
            try check(order.firstIndex(of:16)! < order.firstIndex(of:15)! && order.firstIndex(of:101)! < order.firstIndex(of:100)!, "CursorTimer/ExtraProductList destructor order mismatch")
        }
        test("14 Init D2 old=1 decrements without flush") {
            let m = RE4StageJ4IOSBaseInitModel(initialReferenceCount:1)
            try check(m.destroyInstance() == [.atomicDecrement(oldValue:1,newValue:0)] && m.flushPasses == 0, "old=1 must not flush")
        }

        let summary = "Stage J.4 provider regressions: \(passed)/14 PASS; \(failed) FAIL"
        guard failed == 0 else { throw Failure(summary + "\n" + output.joined(separator:"\n")) }
        return (output + [summary]).joined(separator:"\n")
    }
}
