import Foundation
@main
enum StageJ7TestMain {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("FAIL: expected Stage J.7 frame evidence and J.1 crosswalk paths\n", stderr)
            exit(2)
        }
        do {
            let result = try RE4StageJ7LandingPadContextTests.run(
                evidenceURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                crosswalkURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            print(result)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
