import Foundation

@main
struct StageJ87ProviderABITests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain:"J8.7", code:1,
                                       userInfo:[NSLocalizedDescriptionKey:message]) }
    }

    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: \(name)")
        }

        try test("01 callback AAPCS32 register and stack argument order") {
            let ex = RE4StageJ6SJLJException(exceptionClassLow:0x11223344,
                exceptionClassHigh:0x55667788, private1:0x358CFABC, private2:0xCAFEBABE)
            let call = try RE4StageJ87StopCallbackInvocation.make(
                exception:ex, exceptionPointer:0xA0F00000, contextPointer:0x7100)
            try check(call.callbackAddressRaw == 0x358CFABC, "raw callback token changed")
            try check(call.registerArgumentsR0ToR3 == [1,10,0x11223344,0x55667788],
                      "R0-R3 ABI assignment mismatch")
            try check(call.stackArguments == [0xA0F00000,0x7100,0xCAFEBABE],
                      "stack argument order mismatch")
        }

        try test("02 zero callback return continues forced unwind") {
            let ex = RE4StageJ6SJLJException(private1:1, private2:2)
            let call = try RE4StageJ87StopCallbackInvocation.make(
                exception:ex, exceptionPointer:3, contextPointer:4)
            try check(call.disposition(forCallbackReturn:0) == .continueForcedUnwind,
                      "zero callback return must continue")
        }

        try test("03 nonzero callback return maps to fatal phase-2 error") {
            let ex = RE4StageJ6SJLJException(private1:1, private2:2)
            let call = try RE4StageJ87StopCallbackInvocation.make(
                exception:ex, exceptionPointer:3, contextPointer:4)
            try check(call.disposition(forCallbackReturn:-7) ==
                .fatalPhase2Error(returnCode:-7, unwindReason:2),
                "nonzero callback return must become phase-2 fatal")
        }

        try test("04 Register links previous top and publishes new top") {
            let tsd = RE4StageJ87SJLJTSDModel()
            tsd.createKey()
            let a = try tsd.register(address:0x7100)
            let b = try tsd.register(address:0x7200)
            try check(a.previousFrame == 0 && b.previousFrame == 0x7100 &&
                      tsd.top == 0x7200, "register link/top mismatch")
        }

        try test("05 Unregister publishes the supplied frame predecessor") {
            let tsd = RE4StageJ87SJLJTSDModel()
            tsd.createKey()
            _ = try tsd.register(address:0x7100)
            _ = try tsd.register(address:0x7200)
            try check(try tsd.unregister(address:0x7200) == 0x7100 &&
                      tsd.top == 0x7100, "unregister did not restore predecessor")
        }

        try test("06 forced walk end-of-stack leaves TSD top unchanged") {
            let tsd = RE4StageJ87SJLJTSDModel()
            tsd.createKey()
            _ = try tsd.register(address:0x7100)
            _ = try tsd.register(address:0x7200)
            let result = try tsd.forcedWalk { _ in .continueUnwind }
            try check(result == .endOfStack(visited:[0x7200,0x7100],
                      tsdTopAtReturn:0x7200), "EOS must not implicitly clear TSD")
        }

        try test("07 InstallContext changes TSD top to selected frame") {
            let tsd = RE4StageJ87SJLJTSDModel()
            tsd.createKey()
            _ = try tsd.register(address:0x7100)
            _ = try tsd.register(address:0x7200)
            let result = try tsd.forcedWalk { frame in
                frame.address == 0x7100 ? .installContext : .continueUnwind
            }
            try check(result == .installContext(frame:0x7100,
                      visited:[0x7200,0x7100], tsdTopAfterInstall:0x7100) &&
                      tsd.top == 0x7100, "InstallContext TSD update mismatch")
        }

        try test("08 post-EOS caller Unregister is a distinct transition") {
            let tsd = RE4StageJ87SJLJTSDModel()
            tsd.createKey()
            _ = try tsd.register(address:0x7100)
            _ = try tsd.register(address:0x7200)
            _ = try tsd.forcedWalk { _ in .continueUnwind }
            try check(tsd.top == 0x7200, "provider EOS boundary changed TSD")
            try check(try tsd.unregister(address:0x7200) == 0x7100,
                      "caller-side Unregister was not modeled separately")
        }

        print("RESULT: \(passed)/8 passed; 0 failed")
        print("SCOPE: host-only ABI/TSD metadata; no raw callback, pthread API, provider, or Guest instruction executed.")
    }
}
