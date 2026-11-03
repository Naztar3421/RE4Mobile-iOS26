import Foundation

@main
struct StageJ88TSDLifecycleTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "J8.8", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); passed += 1; print("PASS: \(name)")
        }
        try test("01 key is created once with null destructor") {
            let model = RE4StageJ88SJLJTSDLifecycleModel()
            try model.createKey()
            try check(model.keyDestructor == 0, "provider key destructor must be null")
            do { try model.createKey(); throw NSError(domain: "J8.8", code: 2) }
            catch RE4StageJ88Error.keyAlreadyCreated { }
        }
        try test("02 Register links previous frame and publishes new TSD top") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            let a = try model.register(threadID: 1, address: 0x7100)
            let b = try model.register(threadID: 1, address: 0x7200)
            try check(a.previousFrame == 0 && b.previousFrame == 0x7100 &&
                      model.top(threadID: 1) == 0x7200, "Register chain mismatch")
        }
        try test("03 pthread TSD tops are isolated by thread") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 2, address: 0x8200)
            try check(model.top(threadID: 1) == 0x7100 &&
                      model.top(threadID: 2) == 0x8200, "thread-local tops were mixed")
        }
        try test("04 end-of-stack leaves provider-boundary TSD top unchanged") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 1, address: 0x7200)
            let trace = try model.resumeAndContinueCaller(threadID: 1,
                callerUnregisterFrameAddress: nil) { _ in .continueUnwind }
            try check(trace.providerResult == .endOfStack(reason: 5) &&
                      trace.tsdTopAtProviderBoundary == 0x7200 &&
                      trace.tsdTopAfterCallerContinuation == 0x7200,
                      "provider EOS must not clear TSD")
        }
        try test("05 #101 caller Unregister runs only after Resume returns") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 1, address: 0x7200)
            let trace = try model.resumeAndContinueCaller(threadID: 1,
                callerUnregisterFrameAddress: 0x7200) { _ in .continueUnwind }
            try check(trace.resumeReturnedToCallSite && trace.callerUnregisterExecuted &&
                      trace.tsdTopAtProviderBoundary == 0x7200 &&
                      trace.tsdTopAfterCallerContinuation == 0x7100 &&
                      model.top(threadID: 1) == 0x7100,
                      "Resume-return then Unregister sequence mismatch")
        }
        try test("06 InstallContext publishes selected frame and bypasses caller Unregister") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 1, address: 0x7200)
            let trace = try model.resumeAndContinueCaller(threadID: 1,
                callerUnregisterFrameAddress: 0x7200) { frame in
                    frame.address == 0x7100 ? .installContext : .continueUnwind
                }
            try check(trace.providerResult == .installContext(frameAddress: 0x7100) &&
                      trace.tsdTopAtProviderBoundary == 0x7100 &&
                      !trace.resumeReturnedToCallSite &&
                      !trace.callerUnregisterExecuted &&
                      trace.controlTransferred && model.top(threadID: 1) == 0x7100,
                      "InstallContext must not fall through to caller Unregister")
        }
        try test("07 Unregister uses supplied frame predecessor without top search") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 1, address: 0x7200)
            _ = try model.register(threadID: 1, address: 0x7300)
            let top = try model.unregister(threadID: 1, address: 0x7200)
            try check(top == 0x7100 && model.top(threadID: 1) == 0x7100,
                      "model must match frame->prev publication, not enforce LIFO")
        }
        try test("08 forced walk visits newest-to-oldest and reports exact boundary") {
            let model = RE4StageJ88SJLJTSDLifecycleModel(); try model.createKey()
            _ = try model.register(threadID: 1, address: 0x7100)
            _ = try model.register(threadID: 1, address: 0x7200)
            _ = try model.register(threadID: 1, address: 0x7300)
            let trace = try model.resumeAndContinueCaller(threadID: 1,
                callerUnregisterFrameAddress: nil) { _ in .continueUnwind }
            try check(trace.visitedFrameAddresses == [0x7300, 0x7200, 0x7100] &&
                      trace.initialTSDTop == trace.tsdTopAtProviderBoundary,
                      "forced traversal order/boundary mismatch")
        }
        print("RESULT: \(passed)/8 passed; 0 failed")
        print("SCOPE: host-only per-thread TSD lifecycle; no pthread API, provider, callback, Guest memory, or control transfer executed.")
    }
}
