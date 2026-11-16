import AppKit
import Combine
import Foundation
import SwiftUI

enum ConsoleTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case cpu
    case gpu
    case memory
    case storage
    case powerS0ix
    case network
    case processesSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览面板"
        case .cpu: return "处理器 CPU"
        case .gpu: return "核显 Iris Xe"
        case .memory: return "内存 Memory"
        case .storage: return "存储与 SMART"
        case .powerS0ix: return "电源与 S0ix"
        case .network: return "无线网络"
        case .processesSettings: return "进程与设置"
        }
    }

    var englishTitle: String {
        switch self {
        case .overview: return "Dashboard Overview"
        case .cpu: return "Processor Telemetry"
        case .gpu: return "Graphics & Display"
        case .memory: return "Memory & VM Pressure"
        case .storage: return "NVMe Storage & SMART"
        case .powerS0ix: return "Battery & S0ix Standby"
        case .network: return "Wi-Fi 6 & Throughput"
        case .processesSettings: return "Processes & Preferences"
        }
    }

    var hardwareSubtitle: String {
        switch self {
        case .overview:
            return "X-STATION V2 · i7-1165G7 · Iris Xe 96EU · 16GB LPDDR4X · 1TB NVMe"
        case .cpu:
            return "Intel Core i7-1165G7 · 4C / 8T Tiger Lake-UP3 · APERF/MPERF & RAPL"
        case .gpu:
            return "Intel Iris Xe Graphics (96 EU · 8086:9A49) · Zero-Forcewake RC0/RC6"
        case .memory:
            return "16 GB LPDDR4X-4267 Dual-Channel · XNU Mach VM Statistics"
        case .storage:
            return "APFS Root Volume & NVMeSMARTLib Log Page 0x02 Health"
        case .powerS0ix:
            return "AppleSmartBattery & S0ixStandby v2.0 Deep Idle Diagnostics"
        case .network:
            return "Intel Wi-Fi 6 AX201 (en1) · CoreWLAN & BSD Interface Counters"
        case .processesSettings:
            return "Top-30 Live Process Monitor · Launch at Login, Theme & Widgets"
        }
    }

    var iconName: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .cpu: return "cpu.fill"
        case .gpu: return "display"
        case .memory: return "memorychip.fill"
        case .storage: return "internaldrive.fill"
        case .powerS0ix: return "bolt.batteryblock.fill"
        case .network: return "wifi"
        case .processesSettings: return "slider.horizontal.3"
        }
    }

    var accent: SenseiAccent {
        switch self {
        case .overview: return .cyan
        case .cpu: return .cyan
        case .gpu: return .indigo
        case .memory: return .emerald
        case .storage: return .amber
        case .powerS0ix: return .emerald
        case .network: return .cyan
        case .processesSettings: return .violet
        }
    }
}

enum ProcessesSettingsSubTab: String, CaseIterable, Identifiable, Sendable {
    case processes
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "实时进程排行 (Top 30)"
        case .settings: return "外观与组件设置"
        }
    }

    var iconName: String {
        switch self {
        case .processes: return "list.number"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
final class ConsoleNavigationModel: ObservableObject {
    @Published var selectedTab: ConsoleTab = .overview
    @Published var processesSubTab: ProcessesSettingsSubTab = .processes

    func select(_ tab: ConsoleTab) {
        selectedTab = tab
    }

    func openProcesses() {
        processesSubTab = .processes
        selectedTab = .processesSettings
    }

    func openSettings() {
        processesSubTab = .settings
        selectedTab = .processesSettings
    }
}

@MainActor
final class ConsoleWindowController: NSObject, NSWindowDelegate {
    private let engine: TelemetryEngine
    private let settings: SettingsStore
    private let widgetManager: DesktopWidgetManager
    private let navigation = ConsoleNavigationModel()

    private var window: NSWindow?
    private var interactiveToken: UUID?
    private var cancellables: Set<AnyCancellable> = []

    init(
        engine: TelemetryEngine,
        settings: SettingsStore,
        widgetManager: DesktopWidgetManager
    ) {
        self.engine = engine
        self.settings = settings
        self.widgetManager = widgetManager
        super.init()

        settings.$themeMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.applyWindowAppearance(mode)
            }
            .store(in: &cancellables)
    }

    func showConsole() {
        NSApp.setActivationPolicy(.regular)
        acquireInteractiveSessionIfNeeded()

        let win = ensureWindow()
        if win.isMiniaturized {
            win.deminiaturize(nil)
        }
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
        widgetManager.refreshVisibilityAndFrames()
    }

    func openTab(_ tab: ConsoleTab) {
        navigation.select(tab)
        showConsole()
    }

    func openSettings() {
        navigation.openSettings()
        showConsole()
    }

    private func ensureWindow() -> NSWindow {
        if let existing = window {
            return existing
        }

        let initialRect = NSRect(x: 0, y: 0, width: 1140, height: 740)
        let style: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
            .fullSizeContentView
        ]

        let newWindow = NSWindow(
            contentRect: initialRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        newWindow.minSize = NSSize(width: 980, height: 640)
        newWindow.title = "Xmonitor — X-STATION V2"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.toolbarStyle = .unified
        newWindow.isMovableByWindowBackground = false
        newWindow.isReleasedWhenClosed = false
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        newWindow.delegate = self
        applyWindowAppearance(settings.themeMode, to: newWindow)

        let rootView = ConsoleRootView(
            engine: engine,
            settings: settings,
            widgetManager: widgetManager,
            navigation: navigation
        )
        newWindow.contentView = NSHostingView(rootView: rootView)
        newWindow.center()

        self.window = newWindow
        return newWindow
    }

    private func applyWindowAppearance(_ mode: AppThemeMode, to targetWindow: NSWindow? = nil) {
        guard let win = targetWindow ?? window else { return }
        switch mode {
        case .system:
            win.appearance = nil
        case .darkGraphite:
            win.appearance = NSAppearance(named: .darkAqua)
        case .lightFrost:
            win.appearance = NSAppearance(named: .aqua)
        }
    }

    private func acquireInteractiveSessionIfNeeded() {
        guard interactiveToken == nil else { return }
        interactiveToken = engine.beginInteractiveSession()
    }

    private func releaseInteractiveSessionIfNeeded() {
        guard let token = interactiveToken else { return }
        interactiveToken = nil
        engine.endInteractiveSession(token)
    }

    func windowWillClose(_ notification: Notification) {
        releaseInteractiveSessionIfNeeded()
        let closingWindow = (notification.object as? NSWindow) ?? window
        closingWindow?.delegate = nil
        if window === closingWindow {
            window = nil
        }
        DispatchQueue.main.async { [weak self, closingWindow] in
            closingWindow?.contentView = NSView()
            guard let self else { return }
            if self.window == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self.widgetManager.refreshVisibilityAndFrames()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        releaseInteractiveSessionIfNeeded()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        acquireInteractiveSessionIfNeeded()
    }
}
