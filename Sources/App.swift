import AppKit
import Darwin
import Foundation

@main
@MainActor
struct XSenseiApp {
    static func main() {
        if CommandLine.arguments.contains("--dump-json") {
            let engine = TelemetryEngine(autoStart: false)
            let token = engine.beginInteractiveSession()
            engine.refreshNow()
            usleep(500_000)
            engine.refreshNow()
            engine.endInteractiveSession(token)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(engine.snapshot)
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
                Foundation.exit(0)
            } catch {
                fputs("Failed to encode SystemSnapshot: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
