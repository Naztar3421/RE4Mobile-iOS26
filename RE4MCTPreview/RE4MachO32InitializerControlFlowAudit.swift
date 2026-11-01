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

