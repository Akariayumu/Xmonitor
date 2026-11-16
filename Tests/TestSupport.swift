import AppKit
import Darwin
import Foundation
import IOKit

func canConnectToAwakeWindowServer() -> Bool {
    if ProcessInfo.processInfo.environment["XSENSEI_SKIP_GUI_TESTS"] == "1" {
        return false
    }
    var st = stat()
    guard stat("/dev/console", &st) == 0, st.st_uid == getuid() else {
        return false
    }
    let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
    guard entry != IO_OBJECT_NULL else {
        return false
    }
    defer { IOObjectRelease(entry) }
    guard let pm = IORegistryEntryCreateCFProperty(
        entry,
        "IOPowerManagement" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? [String: Any],
    let stateNum = pm["CurrentPowerState"] as? NSNumber else {
        return false
    }
    return stateNum.intValue >= 4
}

@MainActor
private var didInitTestGUIApp = false

@MainActor
func ensureTestGUIApplication() {
    guard !didInitTestGUIApp else { return }
    didInitTestGUIApp = true
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
}

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
@MainActor
struct XSenseiTestRunner {
    static func main() {
        var failures: [String] = []

        do {
            try runBridgeCoreTests()
            print("[PASS] All BridgeCoreTests passed")
        } catch {
            let desc = "[FAIL] BridgeCoreTests: \(error)"
            fputs("\(desc)\n", stderr)
            failures.append(desc)
        }

        do {
            try runEngineAndCollectorsTests()
            print("[PASS] All EngineAndCollectorsTests passed")
        } catch {
            let desc = "[FAIL] EngineAndCollectorsTests: \(error)"
            fputs("\(desc)\n", stderr)
            failures.append(desc)
        }

        do {
            try runFormattersTests()
            print("[PASS] All FormattersTests passed")
        } catch {
            let desc = "[FAIL] FormattersTests: \(error)"
            fputs("\(desc)\n", stderr)
            failures.append(desc)
        }

        do {
            try runWidgetLayoutTests()
            print("[PASS] All WidgetLayoutTests passed")
        } catch {
            let desc = "[FAIL] WidgetLayoutTests: \(error)"
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
