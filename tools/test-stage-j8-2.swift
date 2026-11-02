import Foundation
@main
enum StageJ82TestMain {
    static func main() {
        guard CommandLine.arguments.count == 4 else {
            fputs("FAIL: expected J.6 LSDA hex, J.7 frame evidence and J.1 crosswalk paths\n", stderr)
            exit(2)
        }
        do {
            let result = try RE4StageJ82SJLJContextBridgeTests.run(
                lsdaHexURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                evidenceURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                crosswalkURL: URL(fileURLWithPath: CommandLine.arguments[3]))
            print(result)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
