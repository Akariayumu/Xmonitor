import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
func runWidgetLayoutTests() throws {
    let screen = CGRect(x: 0, y: 0, width: 2560, height: 1575) // 2560x1600 minus 25pt menu bar

    // 1. Out-of-bounds normalized coordinates (-0.5, 1.4) must clamp strictly inside visibleFrame
    let clamped = WidgetLayoutMath.resolvedFrame(
        normalizedOrigin: CGPoint(x: -0.5, y: 1.4),
        size: CGSize(width: 320, height: 180),
        visibleFrame: screen
    )
    try expectTrue(screen.contains(clamped), "widget frame clamped inside visibleFrame: \(clamped)")
    try expectEqual(clamped.origin, CGPoint(x: 0, y: 1395), "clamped top-left origin in AppKit coords")

    // 2. Opposite out-of-bounds normalized coordinates (2.2, -0.8) and non-zero visibleFrame origin (e.g. left Dock)
    let dockedScreen = CGRect(x: 72, y: 0, width: 2488, height: 1575)
    let clampedBottomRight = WidgetLayoutMath.resolvedFrame(
        normalizedOrigin: CGPoint(x: 2.2, y: -0.8),
        size: CGSize(width: 320, height: 180),
        visibleFrame: dockedScreen
    )
    try expectTrue(
        dockedScreen.contains(clampedBottomRight),
        "widget frame clamped inside docked visibleFrame: \(clampedBottomRight)"
    )
    try expectEqual(clampedBottomRight.origin, CGPoint(x: 2240, y: 0), "clamped bottom-right origin")

    // 3. NaN / Infinite normalized coordinates & oversized widget safety
    let nanResolved = WidgetLayoutMath.resolvedFrame(
        normalizedOrigin: CGPoint(x: Double.nan, y: Double.infinity),
        size: CGSize(width: 320, height: 180),
        visibleFrame: screen
    )
    try expectTrue(screen.contains(nanResolved), "NaN/Inf normalized coords still clamp inside screen")

    let smallScreen = CGRect(x: 0, y: 0, width: 300, height: 160)
    let oversizedResolved = WidgetLayoutMath.resolvedFrame(
        normalizedOrigin: CGPoint(x: 0.5, y: 0.5),
        size: CGSize(width: 392, height: 208),
        visibleFrame: smallScreen
    )
    try expectTrue(
        smallScreen.contains(oversizedResolved),
        "oversized widget clamped to fit small visibleFrame: \(oversizedResolved)"
    )

    // 4. Round-trip normalizedOrigin <-> resolvedFrame
    let sampleFrame = CGRect(x: 2216, y: 1359, width: 320, height: 192)
    let norm = WidgetLayoutMath.normalizedOrigin(for: sampleFrame, in: screen)
    let roundTripped = WidgetLayoutMath.resolvedFrame(
        normalizedOrigin: norm,
        size: sampleFrame.size,
        visibleFrame: screen
    )
    try expectApprox(Double(roundTripped.origin.x), Double(sampleFrame.origin.x), tol: 1e-4, "roundtrip x")
    try expectApprox(Double(roundTripped.origin.y), Double(sampleFrame.origin.y), tol: 1e-4, "roundtrip y")

    // 5. 8pt grid snap
    let snapped = WidgetLayoutMath.snapToGrid(CGPoint(x: 103.2, y: 205.9), step: 8.0)
    try expectEqual(snapped, CGPoint(x: 104.0, y: 208.0), "8pt snap")

    // 6. Default top-right stacking (24pt margin, non-overlapping, strictly inside visibleFrame)
    let cpuDefault = WidgetLayoutMath.defaultFrame(
        for: .cpuGpu,
        size: DesktopWidgetKind.cpuGpu.size(for: .standard),
        in: screen
    )
    let powerDefault = WidgetLayoutMath.defaultFrame(
        for: .powerS0ix,
        size: DesktopWidgetKind.powerS0ix.size(for: .standard),
        in: screen
    )
    try expectTrue(screen.contains(cpuDefault), "default cpuGpu inside screen")
    try expectTrue(screen.contains(powerDefault), "default powerS0ix inside screen")
    try expectTrue(!cpuDefault.intersects(powerDefault), "default stacked widgets do not overlap")
    try expectTrue(cpuDefault.minY > powerDefault.maxY, "cpuGpu sits above powerS0ix in top-right stack")

    // 7. DesktopWidgetManager persistence via settings.defaults & panel window contract
    let suiteName = "com.xstation.sensei.widgets.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = SettingsStore(defaults: defaults)
    let engine = TelemetryEngine(autoStart: false)
    let manager = DesktopWidgetManager(engine: engine, settings: settings, createPanels: false)

    try expectEqual(
        manager.enabledKinds,
        Set([DesktopWidgetKind.cpuGpu, DesktopWidgetKind.powerS0ix]),
        "first-launch default enabled desktop widgets"
    )
    try expectEqual(manager.isWidgetEnabled(.cpuGpu), true, "cpuGpu enabled by default")
    try expectEqual(manager.isWidgetEnabled(.network), false, "network disabled by default")
    try expectEqual(manager.sizePreset(for: .cpuGpu), .standard, "default sizePreset is .standard")

    manager.setWidgetEnabled(.network, enabled: true)
    manager.setWidgetEnabled(.powerS0ix, enabled: false)
    manager.setSizePreset(.wide, for: .cpuGpu)

    let reloadedManager = DesktopWidgetManager(engine: engine, settings: settings, createPanels: false)
    try expectEqual(
        reloadedManager.enabledKinds,
        Set([DesktopWidgetKind.cpuGpu, DesktopWidgetKind.network]),
        "persisted enabledKinds across reload"
    )
    try expectEqual(reloadedManager.sizePreset(for: .cpuGpu), .wide, "persisted sizePreset across reload")

    // Verify hiding all widgets persists empty set (does not reset to defaults on reload)
    reloadedManager.setWidgetEnabled(.cpuGpu, enabled: false)
    reloadedManager.setWidgetEnabled(.network, enabled: false)
    let emptyReloaded = DesktopWidgetManager(engine: engine, settings: settings, createPanels: false)
    try expectTrue(emptyReloaded.enabledKinds.isEmpty, "empty enabledKinds persists without resetting")

    // 8. Menu bar zero-jitter width & interactive session refcount check
    var lowSnap = SystemSnapshot.empty
    lowSnap.cpu.totalUsage = 0.4
    lowSnap.cpu.maxFreqMHz = 800
    lowSnap.cpu.packagePowerW = 1.2
    lowSnap.gpu.usagePct = 0.0
    lowSnap.memory.totalBytes = 17_179_869_184
    lowSnap.memory.usedBytes = 1_500_000_000

    var highSnap = SystemSnapshot.empty
    highSnap.cpu.totalUsage = 100.0
    highSnap.cpu.maxFreqMHz = 4700
    highSnap.cpu.packagePowerW = 42.8
    highSnap.gpu.usagePct = 99.6
    highSnap.memory.totalBytes = 17_179_869_184
    highSnap.memory.usedBytes = 16_900_000_000
    highSnap.network.rxBytesPerSec = 98_500_000
    highSnap.network.txBytesPerSec = 14_200_000
    highSnap.cpu.hasTemp = true
    highSnap.cpu.packageTempC = 94.0

    settings.showMenuNet = true
    settings.showMenuTemp = true
    lowSnap.cpu.hasTemp = false // Even missing SMC temp dash must match 3-digit °C width!

    var midSnap = lowSnap
    midSnap.cpu.totalUsage = 42.3
    midSnap.cpu.maxFreqMHz = 2800
    midSnap.cpu.packagePowerW = 8.4
    midSnap.cpu.hasTemp = true
    midSnap.cpu.packageTempC = 46.0
    midSnap.gpu.usagePct = 14.0
    midSnap.memory.usedBytes = 8_589_934_592
    midSnap.network.rxBytesPerSec = 512_000

    let lowAttr = StatusBarController.makeStatusAttributedTitle(snapshot: lowSnap, settings: settings)
    let midAttr = StatusBarController.makeStatusAttributedTitle(snapshot: midSnap, settings: settings)
    let highAttr = StatusBarController.makeStatusAttributedTitle(snapshot: highSnap, settings: settings)
    try expectEqual(lowAttr.string.count, highAttr.string.count, "fixed character count across low/high metrics")
    try expectEqual(midAttr.string.count, highAttr.string.count, "fixed character count across mid/high metrics")
    try expectApprox(
        Double(lowAttr.size().width),
        Double(highAttr.size().width),
        tol: 0.5,
        "jitter-free rendered pixel width across low(no-temp, KB/s) and high(100%, MB/s)"
    )
    try expectApprox(
        Double(midAttr.size().width),
        Double(highAttr.size().width),
        tol: 0.5,
        "jitter-free rendered pixel width across mid(46°C, KB/s) and high(94°C, MB/s)"
    )

    for style in MenuBarLayoutStyle.allCases {
        settings.menuBarStyle = style
        let lowImg = StatusBarController.makeStatusTemplateImage(snapshot: lowSnap, settings: settings)
        let midImg = StatusBarController.makeStatusTemplateImage(snapshot: midSnap, settings: settings)
        let highImg = StatusBarController.makeStatusTemplateImage(snapshot: highSnap, settings: settings)
        try expectEqual(lowImg.isTemplate, true, "status bar image (\(style.rawValue)) uses macOS native template vibrancy tint")
        try expectEqual(lowImg.size, highImg.size, "zero-jitter (\(style.rawValue)) template image size across low/high metrics")
        try expectEqual(midImg.size, highImg.size, "zero-jitter (\(style.rawValue)) template image size across mid/high metrics")
    }
    settings.menuBarStyle = .stacked

    // Module reorder & ambient interval customization checks
    settings.moveMenuModule(.temp, by: -1)
    try expectEqual(settings.menuModuleOrder.first, .temp, "moveMenuModule moves temp ahead of cpu")
    settings.resetMenuModuleOrder()
    try expectEqual(settings.menuModuleOrder, MenuBarModule.defaultOrder, "resetMenuModuleOrder restores default order")
    engine.setAmbientInterval(5.0)
    try expectEqual(engine.currentInterval, 5.0, "setAmbientInterval updates ambient cadence to 5.0s")
    engine.setAmbientInterval(2.0)

    // 9. All menu items disabled fallback
    settings.showMenuCPU = false
    settings.showMenuGPU = false
    settings.showMenuRAM = false
    settings.showMenuPower = false
    settings.showMenuNet = false
    settings.showMenuTemp = false
    let fallbackAttr = StatusBarController.makeStatusAttributedTitle(snapshot: lowSnap, settings: settings)
    try expectEqual(fallbackAttr.string, "Xmonitor", "fallback label when all menu toggles off")

    // 9b. Ambient deadband zero-rate transitions & storage capacity/wear checks (headless-safe)
    settings.showMenuCPU = true
    settings.showMenuGPU = true
    settings.showMenuRAM = true
    settings.showMenuPower = true
    settings.showMenuNet = true

    var prevAmbient = lowSnap
    prevAmbient.cpu.maxFreqMHz = 900
    prevAmbient.cpu.packagePowerW = 1.4
    prevAmbient.network.rxBytesPerSec = 3_072
    prevAmbient.network.txBytesPerSec = 2_048
    prevAmbient.storage.readBytesPerSec = 12_288
    prevAmbient.storage.writeBytesPerSec = 8_192
    prevAmbient.storage.availableBytes = 250 * 1_073_741_824
    prevAmbient.storage.lifeUsedPct = 1

    var tinyJitter = prevAmbient
    tinyJitter.cpu.maxFreqMHz = 960
    tinyJitter.cpu.packagePowerW = 1.5
    tinyJitter.network.rxBytesPerSec = 3_500
    tinyJitter.network.txBytesPerSec = 2_200
    tinyJitter.storage.readBytesPerSec = 10_000
    tinyJitter.storage.writeBytesPerSec = 9_000
    try expectEqual(
        StatusBarController.isWithinAmbientDeadband(prev: prevAmbient, curr: tinyJitter, settings: settings),
        true,
        "menu bar suppresses sub-threshold ambient LSB noise"
    )
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .network, prev: prevAmbient, curr: tinyJitter),
        true,
        "network widget suppresses sub-threshold ambient noise"
    )
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .memoryStorage, prev: prevAmbient, curr: tinyJitter),
        true,
        "memoryStorage widget suppresses sub-threshold ambient noise"
    )

    var netZeroDrop = prevAmbient
    netZeroDrop.network.rxBytesPerSec = 0
    try expectEqual(
        StatusBarController.isWithinAmbientDeadband(prev: prevAmbient, curr: netZeroDrop, settings: settings),
        false,
        "menu bar never sticks on non-zero rx rate when dropping to 0 B/s"
    )
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .network, prev: prevAmbient, curr: netZeroDrop),
        false,
        "network widget never sticks on non-zero rx rate when dropping to 0 B/s"
    )

    var menuSubKBZeroDrop = prevAmbient
    menuSubKBZeroDrop.network.rxBytesPerSec = 120 // rounds to 0K while prev was 3K
    try expectEqual(
        StatusBarController.isWithinAmbientDeadband(prev: prevAmbient, curr: menuSubKBZeroDrop, settings: settings),
        false,
        "menu bar flushes 3K -> 0K sub-512B/s rounding drop"
    )

    var diskZeroDrop = prevAmbient
    diskZeroDrop.storage.writeBytesPerSec = 0
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .memoryStorage, prev: prevAmbient, curr: diskZeroDrop),
        false,
        "memoryStorage widget never sticks on non-zero write rate when dropping to 0 B/s"
    )

    var diskAvailShift = prevAmbient
    diskAvailShift.storage.availableBytes -= 256 * 1_048_576
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .memoryStorage, prev: prevAmbient, curr: diskAvailShift),
        false,
        "memoryStorage widget refreshes when availableBytes shifts >= 64 MB"
    )

    var wearShift = prevAmbient
    wearShift.storage.lifeUsedPct = 2
    try expectEqual(
        WidgetCardCanvasNSView.isWithinAmbientDeadband(kind: .memoryStorage, prev: prevAmbient, curr: wearShift),
        false,
        "memoryStorage widget refreshes when SMART lifeUsedPct increments"
    )

    // 10–11. Live NSPanel & NSStatusItem window tests (gated on awake WindowServer)
    if canConnectToAwakeWindowServer() {
        ensureTestGUIApplication()

        let testPanel = DesktopWidgetPanel(
            kind: .cpuGpu,
            initialFrame: CGRect(x: 100, y: 100, width: 320, height: 192),
            locked: true,
            themeMode: .darkGraphite,
            rootView: EmptyView()
        )
        let expectedLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
        try expectEqual(testPanel.level.rawValue, expectedLevel, "wallpaper-above-icons window level")
        try expectTrue(
            testPanel.collectionBehavior.contains([.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]),
            "panel collectionBehavior includes all 4 desktop stationary flags"
        )
        try expectTrue(
            testPanel.styleMask.contains([.borderless, .nonactivatingPanel]),
            "panel styleMask is borderless nonactivatingPanel"
        )
        try expectEqual(testPanel.ignoresMouseEvents, true, "locked panel clicks through")
        testPanel.applyLockState(false)
        try expectEqual(testPanel.ignoresMouseEvents, false, "unlocked panel accepts mouse events for snap-drag")
        testPanel.close()

        let liveSuiteName = "com.xstation.sensei.livepanel.tests.\(UUID().uuidString)"
        let liveDefaults = UserDefaults(suiteName: liveSuiteName)!
        defer { liveDefaults.removePersistentDomain(forName: liveSuiteName) }
        let liveSettings = SettingsStore(defaults: liveDefaults)
        let liveManager = DesktopWidgetManager(engine: engine, settings: liveSettings)
        liveManager.setSizePreset(.wide, for: .cpuGpu)
        try expectEqual(
            liveManager.activePanel(for: .cpuGpu)?.frame.size,
            DesktopWidgetKind.cpuGpu.size(for: .wide),
            "live panel resizes up to .wide"
        )
        liveManager.setSizePreset(.compact, for: .cpuGpu)
        try expectEqual(
            liveManager.activePanel(for: .cpuGpu)?.frame.size,
            DesktopWidgetKind.cpuGpu.size(for: .compact),
            "live panel shrinks cleanly down to .compact without NSHostingView minSize clamp"
        )
        for kind in DesktopWidgetKind.allCases {
            liveManager.setWidgetEnabled(kind, enabled: false)
        }

        try expectEqual(engine.currentInterval, 2.0, "engine starts at ambient 2.0s")
        let statusController = StatusBarController(
            engine: engine,
            settings: settings,
            widgetManager: manager,
            onOpenConsole: {}
        )
        statusController.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        try expectEqual(engine.currentInterval, 1.0, "popoverWillShow switches engine to 1.0s")
        statusController.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        try expectEqual(engine.currentInterval, 2.0, "popoverDidClose restores engine to 2.0s")
    } else {
        print("[SKIP] GUI WindowServer asleep or console not owned by uid")
    }
}
