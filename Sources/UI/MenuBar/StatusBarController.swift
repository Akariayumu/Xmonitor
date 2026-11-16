import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
private final class PopoverMountState: ObservableObject {
    @Published var isShown: Bool = false
}

private struct LazyMenuPopoverHostView: View {
    @ObservedObject var mountState: PopoverMountState
    let engine: TelemetryEngine
    let settings: SettingsStore
    let widgetManager: DesktopWidgetManager
    let onOpenConsole: () -> Void
    let onClosePopover: () -> Void

    var body: some View {
        if mountState.isShown {
            MenuPopoverView(
                engine: engine,
                settings: settings,
                widgetManager: widgetManager,
                onOpenConsole: onOpenConsole,
                onClosePopover: onClosePopover
            )
        } else {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private static let figureSpace = "\u{2007}"
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .semibold)
    private static let monoUnitFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
    private static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: valueFont,
        .foregroundColor: NSColor.labelColor
    ]
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    private static let unitAttrs: [NSAttributedString.Key: Any] = [
        .font: monoUnitFont,
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    private static let separatorAttr = NSAttributedString(string: "  ", attributes: labelAttrs)

    private let engine: TelemetryEngine
    private let settings: SettingsStore
    private let widgetManager: DesktopWidgetManager
    private let onOpenConsole: () -> Void

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverMountState = PopoverMountState()
    private var interactiveToken: UUID?
    private var lastDisplayedSnapshot: SystemSnapshot?
    private var lastRenderedTitleString: String?
    private var hasPinnedStatusLength = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        engine: TelemetryEngine,
        settings: SettingsStore,
        widgetManager: DesktopWidgetManager,
        onOpenConsole: @escaping () -> Void
    ) {
        self.engine = engine
        self.settings = settings
        self.widgetManager = widgetManager
        self.onOpenConsole = onOpenConsole
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configurePopover()
        configureStatusButton()
        bindStreams()
        updateStatusButton(snapshot: engine.snapshot)
    }

    // MARK: - NSPopoverDelegate

    func popoverWillShow(_ notification: Notification) {
        if !popoverMountState.isShown {
            popoverMountState.isShown = true
        }
        if interactiveToken == nil {
            interactiveToken = engine.beginInteractiveSession()
        }
        syncPopoverAppearance()
    }

    func popoverDidClose(_ notification: Notification) {
        if popoverMountState.isShown {
            popoverMountState.isShown = false
        }
        if let token = interactiveToken {
            interactiveToken = nil
            engine.endInteractiveSession(token)
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - Fixed-Width Jitter-Free Menu Bar Formatting

    static func makeStatusAttributedTitle(
        snapshot: SystemSnapshot,
        settings: SettingsStore
    ) -> NSAttributedString {
        var segments: [NSAttributedString] = []

        if settings.showMenuCPU {
            let seg = NSMutableAttributedString(string: "CPU ", attributes: labelAttrs)
            let pct = figurePadded(MetricFormat.menuPercent(snapshot.cpu.totalUsage))
            let ghz = figurePadded(MetricFormat.menuGHz(snapshot.cpu.maxFreqMHz))
            seg.append(NSAttributedString(string: "\(pct) \(ghz)", attributes: valueAttrs))
            segments.append(seg)
        }

        if settings.showMenuTemp {
            let seg = NSMutableAttributedString()
            seg.append(NSAttributedString(string: fixedMenuTemp(snapshot.cpu), attributes: valueAttrs))
            segments.append(seg)
        }

        if settings.showMenuGPU {
            let seg = NSMutableAttributedString(string: "GPU ", attributes: labelAttrs)
            let pct = figurePadded(MetricFormat.menuPercent(snapshot.gpu.usagePct))
            seg.append(NSAttributedString(string: pct, attributes: valueAttrs))
            segments.append(seg)
        }

        if settings.showMenuRAM {
            let seg = NSMutableAttributedString(string: "RAM ", attributes: labelAttrs)
            let pct = figurePadded(MetricFormat.menuPercent(snapshot.memory.usedPercent))
            seg.append(NSAttributedString(string: pct, attributes: valueAttrs))
            segments.append(seg)
        }

        if settings.showMenuPower {
            let watts = resolvedMenuWatts(snapshot: snapshot)
            let wStr = figurePadded(MetricFormat.menuWatts(watts))
            segments.append(NSAttributedString(string: wStr, attributes: valueAttrs))
        }

        if settings.showMenuNet {
            let rx = fixedMenuRateParts(snapshot.network.rxBytesPerSec)
            let tx = fixedMenuRateParts(snapshot.network.txBytesPerSec)
            let seg = NSMutableAttributedString(string: "↓", attributes: labelAttrs)
            seg.append(NSAttributedString(string: rx.digits, attributes: valueAttrs))
            seg.append(NSAttributedString(string: rx.unit, attributes: unitAttrs))
            seg.append(NSAttributedString(string: " ↑", attributes: labelAttrs))
            seg.append(NSAttributedString(string: tx.digits, attributes: valueAttrs))
            seg.append(NSAttributedString(string: tx.unit, attributes: unitAttrs))
            segments.append(seg)
        }

        if segments.isEmpty {
            return NSAttributedString(string: "XSensei", attributes: valueAttrs)
        }

        let result = NSMutableAttributedString()
        for (idx, seg) in segments.enumerated() {
            if idx > 0 {
                result.append(separatorAttr)
            }
            result.append(seg)
        }
        return result
    }

    private static func figurePadded(_ raw: String) -> String {
        raw.replacingOccurrences(of: " ", with: figureSpace)
    }

    private static func resolvedMenuWatts(snapshot: SystemSnapshot) -> Double {
        if snapshot.power.present && !snapshot.power.isPluggedIn && abs(snapshot.power.batteryWatts) >= 0.05 {
            return abs(snapshot.power.batteryWatts)
        }
        return max(0, snapshot.cpu.packagePowerW)
    }

    private static func figurePad3(_ value: Int) -> String {
        let v = max(0, min(999, value))
        if v < 10 {
            return "\(figureSpace)\(figureSpace)\(v)"
        }
        if v < 100 {
            return "\(figureSpace)\(v)"
        }
        return "\(v)"
    }

    private static func fixedMenuTemp(_ cpu: CpuSnapshot) -> String {
        guard cpu.hasTemp, cpu.packageTempC.isFinite else {
            return "\(figureSpace)\(figureSpace)\u{2012}°C"
        }
        let deg = max(0, min(999, Int(cpu.packageTempC.rounded())))
        return "\(figurePad3(deg))°C"
    }

    private static func fixedMenuRateParts(_ bytesPerSec: UInt64) -> (digits: String, unit: String) {
        let mb = Double(bytesPerSec) / 1_048_576.0
        if mb >= 1.0 {
            let clamped = min(999, Int(mb.rounded()))
            return (figurePad3(clamped), "M")
        }
        let kb = min(999, Int((Double(bytesPerSec) / 1024.0).rounded()))
        return (figurePad3(kb), "K")
    }

    // MARK: - Setup & Bindings

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        syncPopoverAppearance()

        let rootView = LazyMenuPopoverHostView(
            mountState: popoverMountState,
            engine: engine,
            settings: settings,
            widgetManager: widgetManager,
            onOpenConsole: { [weak self] in
                self?.onOpenConsole()
            },
            onClosePopover: { [weak self] in
                self?.closePopover()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .noImage
    }

    private func bindStreams() {
        engine.$snapshot
            .sink { [weak self] newSnapshot in
                self?.updateStatusButton(snapshot: newSnapshot)
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hasPinnedStatusLength = false
                self.statusItem.length = NSStatusItem.variableLength
                self.lastDisplayedSnapshot = nil
                self.lastRenderedTitleString = nil
                self.updateStatusButton(snapshot: self.engine.snapshot)
                self.syncPopoverAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton(snapshot: SystemSnapshot) {
        guard let button = statusItem.button else { return }
        if engine.currentInterval >= 1.9,
           let prev = lastDisplayedSnapshot,
           Self.isWithinAmbientDeadband(prev: prev, curr: snapshot, settings: settings) {
            return
        }
        lastDisplayedSnapshot = snapshot

        let attr = Self.makeStatusAttributedTitle(
            snapshot: snapshot,
            settings: settings
        )
        if attr.string != lastRenderedTitleString {
            lastRenderedTitleString = attr.string
            button.attributedTitle = attr
            if !hasPinnedStatusLength {
                let fitWidth = ceil(button.fittingSize.width)
                if fitWidth > 20 {
                    statusItem.length = fitWidth
                    hasPinnedStatusLength = true
                }
            }
        }
    }

    static func isWithinAmbientDeadband(
        prev: SystemSnapshot,
        curr: SystemSnapshot,
        settings: SettingsStore
    ) -> Bool {
        if prev.cpu.maxFreqMHz == 0 && curr.cpu.maxFreqMHz > 0 { return false }
        if settings.showMenuCPU {
            if prev.cpu.totalUsage >= 0.5 && curr.cpu.totalUsage < 0.5 { return false }
            if abs(curr.cpu.totalUsage - prev.cpu.totalUsage) >= 2.5 { return false }
            if abs(curr.cpu.maxFreqMHz - prev.cpu.maxFreqMHz) >= 250.0 { return false }
        }
        if settings.showMenuTemp {
            if curr.cpu.hasTemp != prev.cpu.hasTemp { return false }
            if curr.cpu.hasTemp && abs(curr.cpu.packageTempC - prev.cpu.packageTempC) >= 1.5 { return false }
        }
        if settings.showMenuGPU {
            if prev.gpu.usagePct >= 0.5 && curr.gpu.usagePct < 0.5 { return false }
            if abs(curr.gpu.usagePct - prev.gpu.usagePct) >= 2.0 { return false }
        }
        if settings.showMenuRAM {
            if abs(curr.memory.usedPercent - prev.memory.usedPercent) >= 1.5 { return false }
        }
        if settings.showMenuPower {
            let w0 = resolvedMenuWatts(snapshot: prev)
            let w1 = resolvedMenuWatts(snapshot: curr)
            if w0 >= 0.05 && w1 < 0.05 { return false }
            if abs(w1 - w0) >= 0.5 { return false }
        }
        if settings.showMenuNet {
            if (prev.network.rxBytesPerSec > 0 && curr.network.rxBytesPerSec == 0) ||
                ((prev.network.rxBytesPerSec >= 512) != (curr.network.rxBytesPerSec >= 512)) {
                return false
            }
            if (prev.network.txBytesPerSec > 0 && curr.network.txBytesPerSec == 0) ||
                ((prev.network.txBytesPerSec >= 512) != (curr.network.txBytesPerSec >= 512)) {
                return false
            }
            if abs(Int64(curr.network.rxBytesPerSec) - Int64(prev.network.rxBytesPerSec)) >= 4096 { return false }
            if abs(Int64(curr.network.txBytesPerSec) - Int64(prev.network.txBytesPerSec)) >= 4096 { return false }
        }
        return true
    }

    private func syncPopoverAppearance() {
        switch settings.themeMode {
        case .system:
            popover.appearance = nil
        case .darkGraphite:
            popover.appearance = NSAppearance(named: .darkAqua)
        case .lightFrost:
            popover.appearance = NSAppearance(named: .aqua)
        }
    }

    @objc private func handleStatusButtonClick(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if !popoverMountState.isShown {
                popoverMountState.isShown = true
                popover.contentViewController?.view.layoutSubtreeIfNeeded()
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
