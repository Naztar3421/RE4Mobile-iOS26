import Foundation

// Stage J.8.1 adds strict plan/frame integrity checks around the existing
// Stage J.8 data-only harness. It never writes a CPU context or Guest Memory.

public enum RE4StageJ8IntegrityError: Error, CustomStringConvertible {
    case invalidPlanField(String)
    case frameAddressRangeOverflow(UInt32, Int)
    case fieldMismatch(String, UInt32, UInt32)
    case invalidSelector(UInt32)
    case invalidGR1(UInt32)
    case invalidLSDA(UInt32)
    case invalidSavedPC(UInt32)

    public var description: String {
        switch self {
        case .invalidPlanField(let field):
            return "J.7 plan invariant failed: \(field)"
        case .frameAddressRangeOverflow(let base, let length):
            return String(format: "Synthetic frame [0x%08X, +0x%X) wraps 32-bit address space", base, length)
        case .fieldMismatch(let field, let expected, let actual):
            return String(format: "Field %@ mismatch: expected 0x%08X, got 0x%08X", field, expected, actual)
        case .invalidSelector(let value):
            return String(format: "Cleanup selector 0x%08X is outside 1...19", value)
        case .invalidGR1(let value):
            return String(format: "Zero-action cleanup profile requires GR1=0, got 0x%08X", value)
        case .invalidLSDA(let value):
            return String(format: "Unexpected LSDA value 0x%08X", value)
        case .invalidSavedPC(let value):
            return String(format: "Unexpected cleanup continuation 0x%08X", value)
        }
    }
}

/// Expected values copied from a J.7 data-only plan for exact round-trip checks.
public struct RE4StageJ8IntegrityExpectedFields: Equatable {
    public let frameBaseAddress: UInt32
    public let selectorWord: UInt32
    public let unwindGR0: UInt32
    public let unwindGR1: UInt32
    public let lsdaVA: UInt32
    public let savedR7: UInt32
    public let savedSP: UInt32
    public let savedPC: UInt32

    public init(plan: RE4StageJ7CleanupContextPlan) {
        frameBaseAddress = plan.frameAddress
        selectorWord = plan.setIPStoredSelector
        unwindGR0 = plan.setGR0Value
        unwindGR1 = plan.setGR1Value
        lsdaVA = plan.lsdaVA
        savedR7 = plan.savedR7
        savedSP = plan.savedSP
        savedPC = plan.savedContinuationPC
    }
}

public enum RE4StageJ8SyntheticContextIntegrityGuard {
    public static let frameByteCount = RE4StageJ8SyntheticFrame.byteCount

    /// Checks the J.7 plan's pinned #101 cleanup invariants before a byte array is built.
    public static func validatePlan(_ plan: RE4StageJ7CleanupContextPlan) throws {
        func require(_ ok: Bool, _ field: String) throws {
            guard ok else { throw RE4StageJ8IntegrityError.invalidPlanField(field) }
        }
        try require(plan.initializerVA == RE4StageJ7LandingPadContextModel.initializerVA, "initializerVA")
        try require(plan.frameBaseOffsetFromPostPrologueSP == RE4StageJ7LandingPadContextModel.frameBaseOffset, "frameBaseOffsetFromPostPrologueSP")
        try require(plan.lsdaVA == RE4StageJ7LandingPadContextModel.lsdaVA, "lsdaVA")
        try require((2...20).contains(plan.row), "row must be in cleanup rows 2...20")
        try require(plan.dispatchIndex == UInt32(plan.row), "dispatchIndex must equal row")
        try require(plan.selector == UInt32(plan.row - 1), "selector must equal row minus one")
        try require(plan.cleanupObjectCount == plan.selector, "cleanupObjectCount must equal selector")
        try require(plan.actionOffset == 0, "actionOffset must be zero for this profile")
        try require(plan.savedContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC, "savedContinuationPC")
        try require(plan.cleanupContinuationPC == RE4StageJ7LandingPadContextModel.cleanupContinuationPC, "cleanupContinuationPC")
        try require(plan.setGR0Offset == RE4StageJ7LandingPadContextModel.frameGR0Offset, "setGR0Offset")
        try require(plan.setGR1Offset == RE4StageJ7LandingPadContextModel.frameGR1Offset, "setGR1Offset")
        try require(plan.setGR1Value == 0, "setGR1Value must be zero")
        try require(plan.setIPArgument == plan.dispatchIndex, "setIPArgument must equal dispatchIndex")
        try require(plan.setIPStoredSelector == plan.dispatchIndex - 1, "SetIP must store dispatchIndex minus one")
        try require(plan.setIPStoredSelector == plan.selector, "SetIP stored selector must equal the LSDA selector")
        try require(plan.contextPCOverwriteSkipped, "contextPCOverwriteSkipped")
        try require(plan.personalityReturnCode == RE4StageJ7LandingPadContextModel.personalityInstallContextCode, "personalityReturnCode")
        try require(plan.frameRetainedAtTSDTop, "frameRetainedAtTSDTop")
        try require(plan.cleanupEntryReadsGR0, "cleanupEntryReadsGR0")
        try require(plan.resumeExceptionArgument == plan.setGR0Value, "resumeExceptionArgument must equal GR0")
        try require(plan.resumeSelectorSentinel == UInt32.max, "resumeSelectorSentinel")
        try require(plan.resumeGetIPAfterCleanup == 0, "resumeGetIPAfterCleanup")
        try require(plan.resumeContinuesPastCurrentFrame, "resumeContinuesPastCurrentFrame")
        try require(!plan.controlTransferPerformed, "controlTransferPerformed must remain false")
    }

    /// Checks 32-bit address-span arithmetic, then delegates frame construction to J.8.
    public static func makeSyntheticFrame(from plan: RE4StageJ7CleanupContextPlan) throws -> RE4StageJ8SyntheticFrame {
        try validatePlan(plan)
        let endExclusive = UInt64(plan.frameAddress) + UInt64(frameByteCount)
        guard endExclusive <= UInt64(UInt32.max) + 1 else {
            throw RE4StageJ8IntegrityError.frameAddressRangeOverflow(plan.frameAddress, frameByteCount)
        }
        return try RE4StageJ8SyntheticContextRestoreHarness.makeSyntheticFrame(from: plan)
    }

    /// Checks exact plan-to-frame preservation and profile-specific invariants, then
    /// delegates BX target classification to the original J.8 data-only harness.
    public static func inspectRestore(frame: RE4StageJ8SyntheticFrame,
                                      codeRange: RE4StageJ8SyntheticCodeRange,
                                      expected: RE4StageJ8IntegrityExpectedFields) throws -> RE4StageJ8SyntheticRestoreSnapshot {
        let selector = try frame.loadWord(at: 0x04)
        let gr0 = try frame.loadWord(at: 0x08)
        let gr1 = try frame.loadWord(at: 0x0C)
        let lsda = try frame.loadWord(at: 0x1C)
        let r7 = try frame.loadWord(at: 0x20)
        let pc = try frame.loadWord(at: 0x24)
        let sp = try frame.loadWord(at: 0x28)

        try match("frameBaseAddress", expected.frameBaseAddress, frame.baseAddress)
        try match("selectorWord", expected.selectorWord, selector)
        try match("unwindGR0", expected.unwindGR0, gr0)
        try match("unwindGR1", expected.unwindGR1, gr1)
        try match("lsdaVA", expected.lsdaVA, lsda)
        try match("savedR7", expected.savedR7, r7)
        try match("savedSP", expected.savedSP, sp)
        try match("savedPC", expected.savedPC, pc)

        guard (1...19).contains(selector) else {
            throw RE4StageJ8IntegrityError.invalidSelector(selector)
        }
        guard gr1 == 0 else { throw RE4StageJ8IntegrityError.invalidGR1(gr1) }
        guard lsda == RE4StageJ7LandingPadContextModel.lsdaVA else {
            throw RE4StageJ8IntegrityError.invalidLSDA(lsda)
        }
        guard pc == RE4StageJ7LandingPadContextModel.cleanupContinuationPC else {
            throw RE4StageJ8IntegrityError.invalidSavedPC(pc)
        }
        return try RE4StageJ8SyntheticContextRestoreHarness.inspectRestore(frame: frame, codeRange: codeRange)
    }

    private static func match(_ field: String, _ expected: UInt32, _ actual: UInt32) throws {
        guard expected == actual else {
            throw RE4StageJ8IntegrityError.fieldMismatch(field, expected, actual)
        }
    }
}
