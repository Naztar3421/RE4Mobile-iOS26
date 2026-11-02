import Foundation

@main
enum StageJ6TestMain {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("FAIL: expected Stage J.6 LSDA hex and crosswalk fixture paths\n", stderr)
            exit(2)
        }
        do {
            let report = try RE4StageJ6SJLJPersonalityTests.run(
                lsdaHexURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                crosswalkURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            print(report)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
