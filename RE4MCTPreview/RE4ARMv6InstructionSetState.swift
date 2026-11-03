import Foundation

/// ARM/Thumb instruction-set labels used by static state-transition analysis.
public enum RE4ARMv6InstructionSet: String {
    case arm = "ARM"
    case thumb = "Thumb"
}

/// Result of decoding the architectural state bit in a BX/BLX-register target.
public struct RE4ARMv6StateTransition: Equatable {
    public let sourceState: RE4ARMv6InstructionSet
    public let targetState: RE4ARMv6InstructionSet
    /// Canonical instruction address with state-selection bits removed.
    public let targetAddress: UInt32
    /// The CPSR T-bit value that a real CPU would select at the transfer.
    public var targetCPSRTBit: Bool { targetState == .thumb }
}

/// Pure address/state decoding only. This helper does not mutate a CPU, update CPSR,
/// fetch an instruction, or execute ARM/Thumb code.
public enum RE4ARMv6InstructionSetState {
    public static func resolveBX(from sourceState: RE4ARMv6InstructionSet,
                                 registerTarget: UInt32) -> RE4ARMv6StateTransition {
        resolveExchange(from: sourceState, registerTarget: registerTarget)
    }

    public static func resolveBLXRegister(from sourceState: RE4ARMv6InstructionSet,
                                          registerTarget: UInt32) -> RE4ARMv6StateTransition {
        resolveExchange(from: sourceState, registerTarget: registerTarget)
    }

    /// ARM interworking rule for a register target:
    /// bit 0 selects Thumb when set and ARM when clear; ARM targets are word-aligned,
    /// while Thumb targets are halfword-aligned.
    private static func resolveExchange(from sourceState: RE4ARMv6InstructionSet,
                                        registerTarget: UInt32) -> RE4ARMv6StateTransition {
        if registerTarget & 1 != 0 {
            return RE4ARMv6StateTransition(
                sourceState: sourceState,
                targetState: .thumb,
                targetAddress: registerTarget & ~UInt32(1)
            )
        }
        return RE4ARMv6StateTransition(
            sourceState: sourceState,
            targetState: .arm,
            targetAddress: registerTarget & ~UInt32(3)
        )
    }

    public static func runSyntheticSelfTest() throws -> String {
        struct Vector {
            let source: RE4ARMv6InstructionSet
            let rawTarget: UInt32
            let expectedAddress: UInt32
            let expectedState: RE4ARMv6InstructionSet
        }
        let vectors = [
            Vector(source: .arm, rawTarget: 0x35DD6555,
                   expectedAddress: 0x35DD6554, expectedState: .thumb),
            Vector(source: .thumb, rawTarget: 0x00011FC0,
                   expectedAddress: 0x00011FC0, expectedState: .arm),
            Vector(source: .arm, rawTarget: 0x00001237,
                   expectedAddress: 0x00001236, expectedState: .thumb),
            Vector(source: .thumb, rawTarget: 0x00001236,
                   expectedAddress: 0x00001234, expectedState: .arm),
            Vector(source: .arm, rawTarget: 0x35D87D71,
                   expectedAddress: 0x35D87D70, expectedState: .thumb)
        ]

        for vector in vectors {
            let bx = resolveBX(from: vector.source, registerTarget: vector.rawTarget)
            let blx = resolveBLXRegister(from: vector.source, registerTarget: vector.rawTarget)
            guard bx.targetAddress == vector.expectedAddress,
                  bx.targetState == vector.expectedState,
                  bx.targetCPSRTBit == (vector.expectedState == .thumb),
                  blx == bx else {
                throw RE4ARMv6InstructionSetStateError.selfTestFailed(
                    String(format: "source=%@ target=0x%08X", vector.source.rawValue, vector.rawTarget)
                )
            }
        }

        return "ARM/Thumb register-branch state-transition self-test PASS\n" +
            "BX and BLX-register bit-0 state selection: 5/5 vectors\n" +
            "ARM target word alignment and Thumb target halfword alignment: PASS\n" +
            "Synthetic address/state decoding only; CPSR and guest CPU state were not changed.\n" +
            "This helper remains a pure address/state decoder; bounded Thumb-1 execution is implemented separately by the Guest Core."
    }
}

public enum RE4ARMv6InstructionSetStateError: Error, LocalizedError {
    case selfTestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .selfTestFailed(let detail):
            return "ARM/Thumb state-transition synthetic test failed: \(detail)"
        }
    }
}
