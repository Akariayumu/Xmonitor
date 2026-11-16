import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt

    var description: String {
        "\(file):\(line) — \(message)"
    }
}

func expectTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure(message: "expectTrue failed: \(message)", file: file, line: line)
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if actual != expected {
        throw TestFailure(
            message: "expectEqual failed (\(message)): actual=\(actual), expected=\(expected)",
            file: file,
            line: line
        )
    }
}

func expectApprox(
    _ actual: Double,
    _ expected: Double,
    tol: Double,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    if actual.isNaN || actual.isInfinite || abs(actual - expected) > tol {
        throw TestFailure(
            message: "expectApprox failed (\(message)): actual=\(actual), expected=\(expected), tol=\(tol)",
            file: file,
            line: line
        )
    }
}

@main
struct XSenseiTestRunner {
    static func main() async {
        var failures: [String] = []

        do {
            try runBridgeCoreTests()
            print("[PASS] All BridgeCoreTests passed")
        } catch {
            let desc = "[FAIL] BridgeCoreTests: \(error)"
            fputs("\(desc)\n", stderr)
            failures.append(desc)
        }

        if !failures.isEmpty {
            fputs("==> \(failures.count) test suite(s) FAILED\n", stderr)
            Foundation.exit(1)
        }
        print("==> All test suites passed")
    }
}
