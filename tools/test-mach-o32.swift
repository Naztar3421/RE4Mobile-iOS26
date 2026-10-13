import Foundation

@main
enum MachO32ParserTest {
    static func main() {
        do {
            print(try RE4MachO32Parser.runSyntheticSelfTest())
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
