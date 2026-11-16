import AppKit
import Darwin
import Foundation

@MainActor
final class XSenseiAppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var engine: TelemetryEngine?
    private var widgetManager: DesktopWidgetManager?
    private var consoleController: ConsoleWindowController?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore()
        let engine = TelemetryEngine(autoStart: true)
        let widgetManager = DesktopWidgetManager(engine: engine, settings: settings)
        engine.requiresFastAmbientIoNet = { [weak settings, weak widgetManager] in
            (settings?.showMenuNet ?? false) ||
            (widgetManager?.isWidgetEnabled(.memoryStorage) ?? false) ||
            (widgetManager?.isWidgetEnabled(.network) ?? false)
        }
        let consoleController = ConsoleWindowController(
            engine: engine,
            settings: settings,
            widgetManager: widgetManager
        )
        let statusBarController = StatusBarController(
            engine: engine,
            settings: settings,
            widgetManager: widgetManager,
            onOpenConsole: { [weak consoleController] in
                consoleController?.showConsole()
            }
        )

        self.settings = settings
        self.engine = engine
        self.widgetManager = widgetManager
        self.consoleController = consoleController
        self.statusBarController = statusBarController

        if CommandLine.arguments.contains("--open-console") {
            consoleController.showConsole()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        consoleController?.showConsole()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct XSenseiApp {
    private static var retainedDelegate: XSenseiAppDelegate?

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
        let delegate = XSenseiAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
