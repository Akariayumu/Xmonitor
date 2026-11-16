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
    let onOpenSettings: () -> Void
    let onClosePopover: () -> Void

    var body: some View {
        if mountState.isShown {
            MenuPopoverView(
                engine: engine,
                settings: settings,
                widgetManager: widgetManager,
                onOpenConsole: onOpenConsole,
                onOpenSettings: onOpenSettings,
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
    private static let barHeight: CGFloat = 22.0
    private static let outerPadX: CGFloat = 2.0
    private static let interColumnGapWithDivider: CGFloat = 9.0
    private static let interColumnGapPlain: CGFloat = 7.0

    // Unified foreground color for attributed-string API (zero dark-gray mismatch)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold)
    private static let monoUnitFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)
    private static let valueAttrs: [NSAttributedString.Key: Any] = [
        .font: valueFont,
        .foregroundColor: NSColor.labelColor
    ]
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.labelColor
    ]
    private static let unitAttrs: [NSAttributedString.Key: Any] = [
        .font: monoUnitFont,
        .foregroundColor: NSColor.labelColor
    ]
    private static let separatorAttr = NSAttributedString(string: "  ", attributes: labelAttrs)

    // Template image typography (100% alpha black -> macOS WindowServer tints uniformly in pure white/black)
    private static let topHeaderFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private static let bottomValueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let inlineFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    private static let netRowFont = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
    private static let fallbackFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    private static let centeredStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byClipping
        return p
    }()

    private static let leftStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .left
        p.lineBreakMode = .byClipping
        return p
    }()

    private static let topHeaderAttrs: [NSAttributedString.Key: Any] = [
        .font: topHeaderFont,
        .foregroundColor: NSColor.black,
        .kern: 0.35,
        .paragraphStyle: centeredStyle
    ]

    private static let bottomValueAttrs: [NSAttributedString.Key: Any] = [
        .font: bottomValueFont,
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredStyle
    ]

    private static let inlineCenteredAttrs: [NSAttributedString.Key: Any] = [
        .font: inlineFont,
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredStyle
    ]

    private static let inlineLeftAttrs: [NSAttributedString.Key: Any] = [
        .font: inlineFont,
        .foregroundColor: NSColor.black,
        .paragraphStyle: leftStyle
    ]

    private static let netRowAttrs: [NSAttributedString.Key: Any] = [
        .font: netRowFont,
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredStyle
    ]

    private static let fallbackAttrs: [NSAttributedString.Key: Any] = [
        .font: fallbackFont,
        .foregroundColor: NSColor.black,
        .paragraphStyle: centeredStyle
    ]

    // Fixed column widths (stacked)
    private static let stackedCpuFreqWidth = ceil(("100% 4.9G" as NSString).size(withAttributes: bottomValueAttrs).width) + 4.0
    private static let stackedPctWidth = max(31.0, ceil(("100%" as NSString).size(withAttributes: bottomValueAttrs).width) + 4.0)
    private static let stackedTempWidth = max(34.0, ceil(("100°C" as NSString).size(withAttributes: bottomValueAttrs).width) + 4.0)
    private static let stackedPowerWidth = max(36.0, ceil(("99.9W" as NSString).size(withAttributes: bottomValueAttrs).width) + 4.0)
    private static let netDualWidth = max(56.0, ceil(("↓\(figureSpace)999 M/s" as NSString).size(withAttributes: netRowAttrs).width) + 4.0)

    // Fixed column widths (inline)
    private static let inlineCpuFreqWidth = ceil(("CPU 100% 4.9G" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlineCpuOnlyWidth = ceil(("CPU 100%" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlineGpuWidth = ceil(("GPU 100%" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlineRamWidth = ceil(("RAM 100%" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlineTempWidth = ceil(("100°C" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlinePowerWidth = ceil(("99.9W" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0
    private static let inlineNetWidth = ceil(("↓999M ↑999M" as NSString).size(withAttributes: inlineCenteredAttrs).width) + 4.0

    // Fixed column widths (minimal icon + value)
    private static let iconSlotWidth: CGFloat = 14.0
    private static let minimalCpuFreqWidth = iconSlotWidth + ceil(("100% 4.9G" as NSString).size(withAttributes: inlineLeftAttrs).width) + 3.0
    private static let minimalPctWidth = iconSlotWidth + ceil(("100%" as NSString).size(withAttributes: inlineLeftAttrs).width) + 3.0
    private static let minimalTempWidth = iconSlotWidth + ceil(("100°C" as NSString).size(withAttributes: inlineLeftAttrs).width) + 3.0
    private static let minimalPowerWidth = iconSlotWidth + ceil(("99.9W" as NSString).size(withAttributes: inlineLeftAttrs).width) + 3.0

    private static let fallbackColumnWidth = max(58.0, ceil(("Xmonitor" as NSString).size(withAttributes: fallbackAttrs).width) + 6.0)

    private enum MenuColumn {
        case stacked(header: String, value: String, width: CGFloat)
        case inlineText(text: String, width: CGFloat)
        case minimalIcon(symbol: String, value: String, width: CGFloat)
        case netDual(upLine: String, downLine: String, width: CGFloat)
        case single(title: String, width: CGFloat)

        var width: CGFloat {
            switch self {
            case .stacked(_, _, let w),
                 .inlineText(_, let w),
                 .minimalIcon(_, _, let w),
                 .netDual(_, _, let w),
                 .single(_, let w):
                return w
            }
        }
    }

    private let engine: TelemetryEngine
    private let settings: SettingsStore
    private let widgetManager: DesktopWidgetManager
    private let onOpenConsole: () -> Void
    private let onOpenSettings: () -> Void

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverMountState = PopoverMountState()
    private var interactiveToken: UUID?
    private var lastDisplayedSnapshot: SystemSnapshot?
    private var lastRenderedKey: String?
    private var hasPinnedStatusLength = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        engine: TelemetryEngine,
        settings: SettingsStore,
        widgetManager: DesktopWidgetManager,
        onOpenConsole: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.engine = engine
        self.settings = settings
        self.widgetManager = widgetManager
        self.onOpenConsole = onOpenConsole
        self.onOpenSettings = onOpenSettings
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

        for module in settings.menuModuleOrder where settings.isModuleEnabled(module) {
            switch module {
            case .cpu:
                let seg = NSMutableAttributedString(string: "CPU ", attributes: labelAttrs)
                let pct = figurePadded(MetricFormat.menuPercent(snapshot.cpu.totalUsage))
                if settings.showMenuCpuFreq {
                    let ghz = figurePadded(MetricFormat.menuGHz(snapshot.cpu.maxFreqMHz))
                    seg.append(NSAttributedString(string: "\(pct) \(ghz)", attributes: valueAttrs))
                } else {
                    seg.append(NSAttributedString(string: pct, attributes: valueAttrs))
                }
                segments.append(seg)
            case .temp:
                segments.append(NSAttributedString(string: fixedMenuTemp(snapshot.cpu), attributes: valueAttrs))
            case .gpu:
                let seg = NSMutableAttributedString(string: "GPU ", attributes: labelAttrs)
                let pct = figurePadded(MetricFormat.menuPercent(snapshot.gpu.usagePct))
                seg.append(NSAttributedString(string: pct, attributes: valueAttrs))
                segments.append(seg)
            case .ram:
                let seg = NSMutableAttributedString(string: "RAM ", attributes: labelAttrs)
                let pct = figurePadded(MetricFormat.menuPercent(snapshot.memory.usedPercent))
                seg.append(NSAttributedString(string: pct, attributes: valueAttrs))
                segments.append(seg)
            case .power:
                let watts = resolvedMenuWatts(snapshot: snapshot)
                let wStr = figurePadded(MetricFormat.menuWatts(watts))
                segments.append(NSAttributedString(string: wStr, attributes: valueAttrs))
            case .net:
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
        }

        if segments.isEmpty {
            return NSAttributedString(string: "Xmonitor", attributes: valueAttrs)
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

    static func makeStatusTemplateImage(
        snapshot: SystemSnapshot,
        settings: SettingsStore
    ) -> NSImage {
        let (columns, _) = makeColumns(snapshot: snapshot, settings: settings)
        return renderTemplateImage(columns: columns, showDividers: settings.showMenuDividers)
    }

    private static func makeColumns(
        snapshot: SystemSnapshot,
        settings: SettingsStore
    ) -> (columns: [MenuColumn], cacheKey: String) {
        let style = settings.menuBarStyle
        var columns: [MenuColumn] = []
        var keyParts: [String] = ["S:\(style.rawValue)", "D:\(settings.showMenuDividers ? 1 : 0)"]

        for module in settings.menuModuleOrder where settings.isModuleEnabled(module) {
            switch module {
            case .cpu:
                let pctInt = max(0, min(100, Int(snapshot.cpu.totalUsage.rounded())))
                let pctCompact = "\(pctInt)%"
                let pctPadded = "\(figurePad3(pctInt))%"
                let ghzVal = max(0.0, min(9.9, snapshot.cpu.maxFreqMHz / 1000.0))
                let tenths = Int((ghzVal * 10.0).rounded())
                let ghzShort = "\(tenths / 10).\(tenths % 10)G"

                switch style {
                case .stacked:
                    let val = settings.showMenuCpuFreq ? "\(pctCompact) \(ghzShort)" : pctCompact
                    let w = settings.showMenuCpuFreq ? stackedCpuFreqWidth : stackedPctWidth
                    columns.append(.stacked(header: "CPU", value: val, width: w))
                    keyParts.append("C:\(val)")
                case .inline:
                    let val = settings.showMenuCpuFreq ? "CPU \(pctPadded) \(ghzShort)" : "CPU \(pctPadded)"
                    let w = settings.showMenuCpuFreq ? inlineCpuFreqWidth : inlineCpuOnlyWidth
                    columns.append(.inlineText(text: val, width: w))
                    keyParts.append("C:\(val)")
                case .minimal:
                    let val = settings.showMenuCpuFreq ? "\(pctPadded) \(ghzShort)" : pctPadded
                    let w = settings.showMenuCpuFreq ? minimalCpuFreqWidth : minimalPctWidth
                    columns.append(.minimalIcon(symbol: "cpu", value: val, width: w))
                    keyParts.append("C:\(val)")
                }

            case .temp:
                let hasValid = snapshot.cpu.hasTemp && snapshot.cpu.packageTempC.isFinite
                let deg = hasValid ? max(0, min(999, Int(snapshot.cpu.packageTempC.rounded()))) : 0
                let compactVal = hasValid ? "\(deg)°C" : "\u{2012}°C"
                let paddedVal = fixedMenuTemp(snapshot.cpu)

                switch style {
                case .stacked:
                    columns.append(.stacked(header: "TEMP", value: compactVal, width: stackedTempWidth))
                    keyParts.append("T:\(compactVal)")
                case .inline:
                    columns.append(.inlineText(text: paddedVal, width: inlineTempWidth))
                    keyParts.append("T:\(paddedVal)")
                case .minimal:
                    columns.append(.minimalIcon(symbol: "thermometer.medium", value: paddedVal, width: minimalTempWidth))
                    keyParts.append("T:\(paddedVal)")
                }

            case .gpu:
                let pctInt = max(0, min(100, Int(snapshot.gpu.usagePct.rounded())))
                let compactVal = "\(pctInt)%"
                let paddedVal = "\(figurePad3(pctInt))%"

                switch style {
                case .stacked:
                    columns.append(.stacked(header: "GPU", value: compactVal, width: stackedPctWidth))
                    keyParts.append("G:\(compactVal)")
                case .inline:
                    let txt = "GPU \(paddedVal)"
                    columns.append(.inlineText(text: txt, width: inlineGpuWidth))
                    keyParts.append("G:\(txt)")
                case .minimal:
                    columns.append(.minimalIcon(symbol: "display", value: paddedVal, width: minimalPctWidth))
                    keyParts.append("G:\(paddedVal)")
                }

            case .ram:
                let pctInt = max(0, min(100, Int(snapshot.memory.usedPercent.rounded())))
                let compactVal = "\(pctInt)%"
                let paddedVal = "\(figurePad3(pctInt))%"

                switch style {
                case .stacked:
                    columns.append(.stacked(header: "RAM", value: compactVal, width: stackedPctWidth))
                    keyParts.append("R:\(compactVal)")
                case .inline:
                    let txt = "RAM \(paddedVal)"
                    columns.append(.inlineText(text: txt, width: inlineRamWidth))
                    keyParts.append("R:\(txt)")
                case .minimal:
                    columns.append(.minimalIcon(symbol: "memorychip", value: paddedVal, width: minimalPctWidth))
                    keyParts.append("R:\(paddedVal)")
                }

            case .power:
                let watts = resolvedMenuWatts(snapshot: snapshot)
                let tenths = max(0, min(999, Int((watts * 10.0).rounded())))
                let compactVal = "\(tenths / 10).\(tenths % 10)W"
                let paddedVal = figurePadded(MetricFormat.menuWatts(watts))

                switch style {
                case .stacked:
                    columns.append(.stacked(header: "PWR", value: compactVal, width: stackedPowerWidth))
                    keyParts.append("P:\(compactVal)")
                case .inline:
                    columns.append(.inlineText(text: paddedVal, width: inlinePowerWidth))
                    keyParts.append("P:\(paddedVal)")
                case .minimal:
                    columns.append(.minimalIcon(symbol: "bolt.fill", value: paddedVal, width: minimalPowerWidth))
                    keyParts.append("P:\(paddedVal)")
                }

            case .net:
                let tx = fixedMenuRateParts(snapshot.network.txBytesPerSec)
                let rx = fixedMenuRateParts(snapshot.network.rxBytesPerSec)
                switch style {
                case .stacked, .minimal:
                    let upLine = "↑\(tx.digits) \(tx.unit)/s"
                    let downLine = "↓\(rx.digits) \(rx.unit)/s"
                    columns.append(.netDual(upLine: upLine, downLine: downLine, width: netDualWidth))
                    keyParts.append("N:\(upLine)|\(downLine)")
                case .inline:
                    let txt = "↓\(rx.digits)\(rx.unit) ↑\(tx.digits)\(tx.unit)"
                    columns.append(.inlineText(text: txt, width: inlineNetWidth))
                    keyParts.append("N:\(txt)")
                }
            }
        }

        if columns.isEmpty {
            columns.append(.single(title: "Xmonitor", width: fallbackColumnWidth))
            keyParts.append("Xmonitor")
        }

        return (columns, keyParts.joined(separator: ";"))
    }

    private static func renderTemplateImage(columns: [MenuColumn], showDividers: Bool) -> NSImage {
        let gap = showDividers ? interColumnGapWithDivider : interColumnGapPlain
        let contentWidth = columns.reduce(CGFloat(0.0)) { $0 + $1.width }
        let gapsWidth = CGFloat(max(0, columns.count - 1)) * gap
        let totalWidth = ceil(outerPadX * 2.0 + contentWidth + gapsWidth)

        let image = NSImage(size: NSSize(width: totalWidth, height: barHeight), flipped: true) { _ in
            var x = outerPadX
            for (idx, col) in columns.enumerated() {
                if showDividers && idx > 0 {
                    let sepX = floor(x - gap * 0.5) + 0.5
                    let path = NSBezierPath()
                    path.lineWidth = 1.0
                    path.move(to: NSPoint(x: sepX, y: 4.5))
                    path.line(to: NSPoint(x: sepX, y: barHeight - 4.5))
                    NSColor.black.withAlphaComponent(0.22).setStroke()
                    path.stroke()
                }

                switch col {
                case .stacked(let header, let value, let w):
                    (header as NSString).draw(
                        in: NSRect(x: x, y: 0.8, width: w, height: 9.5),
                        withAttributes: topHeaderAttrs
                    )
                    (value as NSString).draw(
                        in: NSRect(x: x, y: 9.2, width: w, height: 12.6),
                        withAttributes: bottomValueAttrs
                    )

                case .inlineText(let text, let w):
                    (text as NSString).draw(
                        in: NSRect(x: x, y: 3.6, width: w, height: 15.0),
                        withAttributes: inlineCenteredAttrs
                    )

                case .minimalIcon(let symbol, let value, let w):
                    if let baseSym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                       let sym = baseSym.withSymbolConfiguration(
                           NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
                       ) {
                        let symSize = sym.size
                        let symY = floor((barHeight - symSize.height) * 0.5)
                        sym.draw(
                            in: NSRect(x: x, y: symY, width: min(iconSlotWidth, symSize.width), height: symSize.height),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: 1.0,
                            respectFlipped: true,
                            hints: nil
                        )
                    }
                    (value as NSString).draw(
                        in: NSRect(x: x + iconSlotWidth, y: 3.6, width: max(1, w - iconSlotWidth), height: 15.0),
                        withAttributes: inlineLeftAttrs
                    )

                case .netDual(let upLine, let downLine, let w):
                    (upLine as NSString).draw(
                        in: NSRect(x: x, y: 0.6, width: w, height: 10.8),
                        withAttributes: netRowAttrs
                    )
                    (downLine as NSString).draw(
                        in: NSRect(x: x, y: 10.6, width: w, height: 10.8),
                        withAttributes: netRowAttrs
                    )

                case .single(let title, let w):
                    (title as NSString).draw(
                        in: NSRect(x: x, y: 3.5, width: w, height: 15.0),
                        withAttributes: fallbackAttrs
                    )
                }

                x += col.width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
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
            onOpenSettings: { [weak self] in
                self?.onOpenSettings()
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
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
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
                self.lastRenderedKey = nil
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

        let (columns, cacheKey) = Self.makeColumns(snapshot: snapshot, settings: settings)
        if cacheKey != lastRenderedKey {
            lastRenderedKey = cacheKey
            let img = Self.renderTemplateImage(columns: columns, showDividers: settings.showMenuDividers)
            button.image = img
            let targetLength = ceil(img.size.width + 8.0)
            if !hasPinnedStatusLength || abs(statusItem.length - targetLength) > 0.5 {
                statusItem.length = targetLength
                hasPinnedStatusLength = true
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
            if settings.showMenuCpuFreq && abs(curr.cpu.maxFreqMHz - prev.cpu.maxFreqMHz) >= 250.0 { return false }
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
