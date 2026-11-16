import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI

private func widgetClampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1.0, max(0.0, value))
}

private func widgetSafeRound(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(value.rounded())
}

private func fmtTenths(_ value: Double) -> String {
    let tenths = max(0, widgetSafeRound(value * 10.0))
    return "\(tenths / 10).\(tenths % 10)"
}

private func fmtSignedTenths(_ value: Double) -> String {
    guard value.isFinite else { return "0.0" }
    let tenths = widgetSafeRound(abs(value) * 10.0)
    let sign = value >= 0 ? "+" : "-"
    return "\(sign)\(tenths / 10).\(tenths % 10)"
}

private enum WidgetTextColorRole: Equatable {
    case primary
    case secondary
    case accent(SenseiAccent)

    var nsColor: NSColor {
        switch self {
        case .primary:
            return .labelColor
        case .secondary:
            return .secondaryLabelColor
        case .accent(let acc):
            return acc.primaryNSColor
        }
    }
}

// MARK: - Lightweight Cached Label & Pill Views (Zero Redraw When Unchanged)

private let noLayerActions: [String: CAAction] = [
    "bounds": NSNull(),
    "position": NSNull(),
    "frame": NSNull(),
    "backgroundColor": NSNull(),
    "borderColor": NSNull(),
    "colors": NSNull(),
    "path": NSNull(),
    "strokeEnd": NSNull(),
    "strokeColor": NSNull(),
    "sublayers": NSNull(),
    "contents": NSNull()
]

@MainActor
private final class CachedLabelView: NSTextField {
    private var lastText: String?
    private var lastColorRole: WidgetTextColorRole?
    private var currentFontSize: CGFloat = 0
    private var currentWeight: NSFont.Weight = .regular
    private var isMono: Bool = true
    private var currentAlign: NSTextAlignment = .natural
    private var cachedMeasuredSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        colorRole: WidgetTextColorRole,
        monospaced: Bool = true,
        alignment: NSTextAlignment = .left
    ) {
        var needsMeasure = false
        if abs(currentFontSize - size) > 0.01 || currentWeight != weight || isMono != monospaced {
            currentFontSize = size
            currentWeight = weight
            isMono = monospaced
            font = monospaced
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            needsMeasure = true
        }
        if currentAlign != alignment {
            currentAlign = alignment
            self.alignment = alignment
        }
        if lastColorRole != colorRole {
            lastColorRole = colorRole
            self.textColor = colorRole.nsColor
        }
        if lastText != text {
            lastText = text
            stringValue = text
            needsMeasure = true
        }
        if needsMeasure {
            let s = cell?.cellSize ?? intrinsicContentSize
            cachedMeasuredSize = CGSize(width: ceil(s.width), height: ceil(s.height))
        }
    }

    func measuredSize() -> CGSize {
        cachedMeasuredSize
    }
}

extension NSView {
    fileprivate func setFrameIfChanged(_ target: CGRect) {
        if frame != target {
            frame = target
        }
    }
}

@MainActor
private final class CachedPillView: NSView {
    private let label = CachedLabelView()
    private var lastAccent: SenseiAccent?
    private(set) var pillSize: CGSize = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.actions = noLayerActions
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, accent: SenseiAccent) {
        label.configure(
            text: text,
            size: 9.5,
            weight: .semibold,
            colorRole: .accent(accent),
            monospaced: true
        )
        let ls = label.measuredSize()
        let w = ls.width + 12.0
        let h = ls.height + 4.0
        if pillSize != CGSize(width: w, height: h) {
            pillSize = CGSize(width: w, height: h)
            label.setFrameIfChanged(CGRect(x: 6.0, y: 2.0, width: ls.width, height: ls.height))
            layer?.cornerRadius = h * 0.5
        }
        if lastAccent != accent {
            lastAccent = accent
            layer?.backgroundColor = accent.primaryNSColor.withAlphaComponent(0.15).cgColor
        }
    }
}

// MARK: - GPU-Composited CAShapeLayer Ring Gauge

@MainActor
private final class LayerRingView: NSView {
    private let trackLayer = CAShapeLayer()
    private let gradientLayer = CAGradientLayer()
    private let arcMaskLayer = CAShapeLayer()
    private let valueLabel = CachedLabelView()
    private let subLabel = CachedLabelView()

    private var lastDiameter: CGFloat = 0
    private var lastLineWidth: CGFloat = 0
    private var lastAccent: SenseiAccent?
    private var lastQuantizedProgress: Int = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        trackLayer.fillColor = nil
        trackLayer.lineCap = .round
        trackLayer.actions = noLayerActions

        arcMaskLayer.fillColor = nil
        arcMaskLayer.strokeColor = NSColor.white.cgColor
        arcMaskLayer.lineCap = .round
        arcMaskLayer.strokeStart = 0.0
        arcMaskLayer.strokeEnd = 0.0
        arcMaskLayer.actions = noLayerActions

        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        gradientLayer.mask = arcMaskLayer
        gradientLayer.actions = noLayerActions

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(gradientLayer)
        addSubview(valueLabel)
        addSubview(subLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        frame targetFrame: CGRect,
        progress: Double,
        valueText: String,
        subtitle: String,
        accent: SenseiAccent,
        lineWidth: CGFloat,
        isDark: Bool
    ) {
        if self.frame != targetFrame {
            self.frame = targetFrame
        }
        let diameter = min(targetFrame.width, targetFrame.height)
        if abs(diameter - lastDiameter) > 0.1 || abs(lineWidth - lastLineWidth) > 0.05 {
            lastDiameter = diameter
            lastLineWidth = lineWidth
            let localBounds = CGRect(origin: .zero, size: targetFrame.size)
            trackLayer.frame = localBounds
            gradientLayer.frame = localBounds
            arcMaskLayer.frame = localBounds

            let radius = max(1.0, (diameter - lineWidth) * 0.5)
            let center = CGPoint(x: localBounds.midX, y: localBounds.midY)
            let circle = CGMutablePath()
            circle.addArc(
                center: center,
                radius: radius,
                startAngle: -.pi * 0.5,
                endAngle: .pi * 1.5,
                clockwise: false
            )
            trackLayer.path = circle
            trackLayer.lineWidth = lineWidth
            arcMaskLayer.path = circle
            arcMaskLayer.lineWidth = lineWidth
        }

        trackLayer.strokeColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.10).cgColor

        if lastAccent != accent {
            lastAccent = accent
            gradientLayer.colors = [accent.primaryNSColor.cgColor, accent.secondaryNSColor.cgColor]
        }

        let clamped = widgetClampUnit(progress)
        let q = Int((clamped * 360.0).rounded())
        if q != lastQuantizedProgress {
            lastQuantizedProgress = q
            arcMaskLayer.strokeEnd = clamped > 0.0005 ? CGFloat(clamped) : 0.0
        }

        valueLabel.configure(
            text: valueText,
            size: max(10.5, diameter * 0.205),
            weight: .semibold,
            colorRole: .primary,
            monospaced: true,
            alignment: .center
        )
        subLabel.configure(
            text: subtitle,
            size: max(8.5, diameter * 0.125),
            weight: .medium,
            colorRole: .secondary,
            monospaced: true,
            alignment: .center
        )
        let vs = valueLabel.measuredSize()
        let ss = subLabel.measuredSize()
        let totalH = vs.height + ss.height - 1.0
        let startY = floor((diameter - totalH) * 0.5)
        valueLabel.setFrameIfChanged(CGRect(x: 2, y: startY, width: diameter - 4, height: vs.height))
        subLabel.setFrameIfChanged(CGRect(x: 2, y: startY + vs.height - 1.0, width: diameter - 4, height: ss.height))
    }
}

// MARK: - GPU-Composited CAShapeLayer + CAGradientLayer Sparkline

@MainActor
private final class LayerSparklineView: NSView {
    private let midRuleLayer = CAShapeLayer()
    private let areaGradientLayer = CAGradientLayer()
    private let areaMaskLayer = CAShapeLayer()
    private let strokeGradientLayer = CAGradientLayer()
    private let strokeMaskLayer = CAShapeLayer()

    private var lastBoundsSize: CGSize = .zero
    private var lastKey: [Int] = []
    private var lastAccent: SenseiAccent?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        midRuleLayer.fillColor = nil
        midRuleLayer.lineWidth = 0.75
        midRuleLayer.lineDashPattern = [3, 3]
        midRuleLayer.actions = noLayerActions

        areaMaskLayer.fillColor = NSColor.white.cgColor
        areaMaskLayer.actions = noLayerActions
        areaGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        areaGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        areaGradientLayer.mask = areaMaskLayer
        areaGradientLayer.actions = noLayerActions

        strokeMaskLayer.fillColor = nil
        strokeMaskLayer.strokeColor = NSColor.white.cgColor
        strokeMaskLayer.lineWidth = 1.6
        strokeMaskLayer.lineCap = .round
        strokeMaskLayer.lineJoin = .round
        strokeMaskLayer.actions = noLayerActions
        strokeGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        strokeGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        strokeGradientLayer.mask = strokeMaskLayer
        strokeGradientLayer.actions = noLayerActions

        layer?.addSublayer(midRuleLayer)
        layer?.addSublayer(areaGradientLayer)
        layer?.addSublayer(strokeGradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        frame targetFrame: CGRect,
        values: [Double],
        maxValue: Double?,
        accent: SenseiAccent,
        isDark: Bool
    ) {
        if self.frame != targetFrame {
            self.frame = targetFrame
        }
        let size = targetFrame.size
        guard size.width > 4, size.height > 6 else { return }

        let sizeChanged = abs(size.width - lastBoundsSize.width) > 0.5 || abs(size.height - lastBoundsSize.height) > 0.5
        if sizeChanged {
            lastBoundsSize = size
            let local = CGRect(origin: .zero, size: size)
            midRuleLayer.frame = local
            areaGradientLayer.frame = local
            areaMaskLayer.frame = local
            strokeGradientLayer.frame = local
            strokeMaskLayer.frame = local

            let midY = 1.5 + max(1.0, size.height - 2.5) * 0.5
            let midPath = CGMutablePath()
            midPath.move(to: CGPoint(x: 0, y: midY))
            midPath.addLine(to: CGPoint(x: size.width, y: midY))
            midRuleLayer.path = midPath
        }

        midRuleLayer.strokeColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.06).cgColor

        if lastAccent != accent {
            lastAccent = accent
            areaGradientLayer.colors = [
                accent.primaryNSColor.withAlphaComponent(0.30).cgColor,
                accent.secondaryNSColor.withAlphaComponent(0.02).cgColor
            ]
            strokeGradientLayer.colors = [
                accent.primaryNSColor.cgColor,
                accent.secondaryNSColor.cgColor
            ]
        }

        let norm = AreaSparkline.normalizedSamples(values: values, maxValue: maxValue)
        let scale = Double(max(8.0, size.height / 1.5))
        let key = norm.map { Int(($0 * scale).rounded()) }
        guard sizeChanged || key != lastKey else { return }
        lastKey = key

        let topPad: CGFloat = 1.5
        let bottomPad: CGFloat = 1.0
        let plotH = max(1.0, size.height - topPad - bottomPad)
        let baseY = size.height - bottomPad
        let stepX = size.width / CGFloat(max(1, norm.count - 1))

        let line = CGMutablePath()
        var prev = CGPoint(x: 0, y: baseY - CGFloat(norm[0]) * plotH)
        line.move(to: prev)
        for i in 1..<norm.count {
            let curr = CGPoint(x: CGFloat(i) * stepX, y: baseY - CGFloat(norm[i]) * plotH)
            let midX = (prev.x + curr.x) * 0.5
            line.addCurve(to: curr, control1: CGPoint(x: midX, y: prev.y), control2: CGPoint(x: midX, y: curr.y))
            prev = curr
        }

        if let area = line.mutableCopy() {
            area.addLine(to: CGPoint(x: size.width, y: baseY))
            area.addLine(to: CGPoint(x: 0, y: baseY))
            area.closeSubpath()
            areaMaskLayer.path = area
        }
        strokeMaskLayer.path = line
    }
}

// MARK: - Zero-BackingStore Layer-Composited Widget Card View

@MainActor
final class WidgetCardCanvasNSView: NSView {
    private let kind: DesktopWidgetKind

    // Static glass chrome sublayers (composited by WindowServer GPU, zero draw(_:))
    private let surfaceTintLayer = CALayer()
    private let topSheenLayer = CAGradientLayer()
    private let borderLayer = CALayer()
    private let dividerLayer = CALayer()
    private let barTrackLayer = CALayer()
    private let barAppLayer = CALayer()
    private let barWiredLayer = CALayer()
    private let barCompLayer = CALayer()
    private var dotLayers: [CALayer] = []

    // Reusable child views (allocated lazily per card kind)
    private var labels: [CachedLabelView] = []
    private var pills: [CachedPillView] = []
    private var rings: [LayerRingView] = []
    private var sparklines: [LayerSparklineView] = []

    private var lastPreset: WidgetSizePreset?
    private var lastOpacityInt: Int = -1
    private var lastIsDark: Bool?
    private var lastSize: CGSize = .zero
    private var lastPowerFastKey: [Int] = []
    private var lastDisplayedSnapshot: SystemSnapshot?

    override var isFlipped: Bool { true }

    init(kind: DesktopWidgetKind, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = true
        root.cornerRadius = 16.0
        root.cornerCurve = .continuous

        surfaceTintLayer.cornerRadius = 16.0
        surfaceTintLayer.cornerCurve = .continuous
        surfaceTintLayer.actions = noLayerActions

        topSheenLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        topSheenLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        topSheenLayer.actions = noLayerActions

        borderLayer.cornerRadius = 16.0
        borderLayer.cornerCurve = .continuous
        borderLayer.borderWidth = 1.0
        borderLayer.actions = noLayerActions

        root.addSublayer(surfaceTintLayer)
        root.addSublayer(topSheenLayer)
        root.addSublayer(borderLayer)

        if kind == .memoryStorage {
            barTrackLayer.cornerRadius = 4.0
            barTrackLayer.masksToBounds = true
            barTrackLayer.actions = noLayerActions
            barAppLayer.backgroundColor = SenseiAccent.cyan.primaryNSColor.cgColor
            barAppLayer.actions = noLayerActions
            barWiredLayer.backgroundColor = SenseiAccent.indigo.primaryNSColor.cgColor
            barWiredLayer.actions = noLayerActions
            barCompLayer.backgroundColor = SenseiAccent.violet.primaryNSColor.cgColor
            barCompLayer.actions = noLayerActions
            dividerLayer.actions = noLayerActions
            barTrackLayer.addSublayer(barAppLayer)
            barTrackLayer.addSublayer(barWiredLayer)
            barTrackLayer.addSublayer(barCompLayer)
            root.addSublayer(barTrackLayer)
            root.addSublayer(dividerLayer)
            for acc in [SenseiAccent.cyan, .indigo, .violet] {
                let dot = CALayer()
                dot.cornerRadius = 3.0
                dot.backgroundColor = acc.primaryNSColor.cgColor
                root.addSublayer(dot)
                dotLayers.append(dot)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func label(at idx: Int) -> CachedLabelView {
        while labels.count <= idx {
            let v = CachedLabelView()
            addSubview(v)
            labels.append(v)
        }
        labels[idx].isHidden = false
        return labels[idx]
    }

    private func pill(at idx: Int) -> CachedPillView {
        while pills.count <= idx {
            let p = CachedPillView(frame: .zero)
            addSubview(p)
            pills.append(p)
        }
        pills[idx].isHidden = false
        return pills[idx]
    }

    private func ring(at idx: Int) -> LayerRingView {
        while rings.count <= idx {
            let r = LayerRingView(frame: .zero)
            addSubview(r)
            rings.append(r)
        }
        rings[idx].isHidden = false
        return rings[idx]
    }

    private func sparkline(at idx: Int) -> LayerSparklineView {
        while sparklines.count <= idx {
            let s = LayerSparklineView(frame: .zero)
            addSubview(s)
            sparklines.append(s)
        }
        sparklines[idx].isHidden = false
        return sparklines[idx]
    }

    private func hideUnused(labelsUsed: Int, pillsUsed: Int, ringsUsed: Int, sparksUsed: Int) {
        for i in labelsUsed..<labels.count where !labels[i].isHidden { labels[i].isHidden = true }
        for i in pillsUsed..<pills.count where !pills[i].isHidden { pills[i].isHidden = true }
        for i in ringsUsed..<rings.count where !rings[i].isHidden { rings[i].isHidden = true }
        for i in sparksUsed..<sparklines.count where !sparklines[i].isHidden { sparklines[i].isHidden = true }
    }

    func updateContent(
        preset: WidgetSizePreset,
        opacity: Double,
        snapshot: SystemSnapshot,
        engine: TelemetryEngine,
        force: Bool = false
    ) {
        let b = bounds
        guard b.width > 20, b.height > 20 else { return }

        let clampedOpacity = opacity.isFinite ? min(1.0, max(0.3, opacity)) : 0.88
        let opInt = widgetSafeRound(clampedOpacity * 100)
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let sizeChanged = abs(b.width - lastSize.width) > 0.5 || abs(b.height - lastSize.height) > 0.5
        let chromeChanged = force || sizeChanged || preset != lastPreset || opInt != lastOpacityInt || lastIsDark != isDark

        if !chromeChanged,
           engine.currentInterval >= 1.9,
           let prev = lastDisplayedSnapshot,
           Self.isWithinAmbientDeadband(kind: kind, prev: prev, curr: snapshot) {
            let pad: CGFloat = (preset == .compact) ? 11.0 : 14.0
            let rect = b.insetBy(dx: pad, dy: pad)
            updateSparklinesOnly(rect: rect, preset: preset, engine: engine, isDark: isDark)
            return
        }
        lastDisplayedSnapshot = snapshot

        if chromeChanged {
            lastSize = b.size
            lastOpacityInt = opInt
            lastIsDark = isDark

            surfaceTintLayer.frame = b
            topSheenLayer.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height * 0.5)
            borderLayer.frame = b

            surfaceTintLayer.backgroundColor = (
                isDark
                    ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.54 * clampedOpacity)
                    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.64 * clampedOpacity)
            ).cgColor
            let sheenAlpha = isDark ? (0.05 * clampedOpacity) : (0.24 * clampedOpacity)
            topSheenLayer.colors = [
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: sheenAlpha).cgColor,
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0).cgColor
            ]
            borderLayer.borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: isDark ? 0.12 : 0.52).cgColor
            lastPowerFastKey = []
        }

        lastPreset = preset
        let pad: CGFloat = (preset == .compact) ? 11.0 : 14.0
        let rect = b.insetBy(dx: pad, dy: pad)

        switch kind {
        case .cpuGpu:
            layoutCpuGpu(rect: rect, preset: preset, snapshot: snapshot, engine: engine, isDark: isDark)
        case .memoryStorage:
            layoutMemoryStorage(rect: rect, preset: preset, snapshot: snapshot, isDark: isDark)
        case .powerS0ix:
            layoutPowerS0ix(rect: rect, preset: preset, snapshot: snapshot, isDark: isDark)
        case .network:
            layoutNetwork(rect: rect, preset: preset, snapshot: snapshot, engine: engine, isDark: isDark)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        lastSize = .zero
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lastIsDark = nil
    }

    static func isWithinAmbientDeadband(
        kind: DesktopWidgetKind,
        prev: SystemSnapshot,
        curr: SystemSnapshot
    ) -> Bool {
        if prev.cpu.maxFreqMHz == 0 && curr.cpu.maxFreqMHz > 0 { return false }
        switch kind {
        case .cpuGpu:
            if prev.cpu.totalUsage >= 0.5 && curr.cpu.totalUsage < 0.5 { return false }
            if prev.gpu.usagePct >= 0.5 && curr.gpu.usagePct < 0.5 { return false }
            return abs(curr.cpu.totalUsage - prev.cpu.totalUsage) < 2.5 &&
                abs(curr.cpu.maxFreqMHz - prev.cpu.maxFreqMHz) < 250.0 &&
                abs(curr.cpu.packagePowerW - prev.cpu.packagePowerW) < 0.5 &&
                abs(curr.cpu.corePowerW - prev.cpu.corePowerW) < 0.4 &&
                abs(curr.cpu.pkgCStatePct - prev.cpu.pkgCStatePct) < 3.0 &&
                curr.cpu.hasTemp == prev.cpu.hasTemp &&
                (!curr.cpu.hasTemp || abs(curr.cpu.packageTempC - prev.cpu.packageTempC) < 1.5) &&
                abs(curr.gpu.usagePct - prev.gpu.usagePct) < 2.0 &&
                abs(curr.gpu.powerW - prev.gpu.powerW) < 0.3 &&
                curr.gpu.hasFreq == prev.gpu.hasFreq &&
                curr.gpu.currentFreqMHz == prev.gpu.currentFreqMHz &&
                (curr.gpu.gartUsedBytes >> 25) == (prev.gpu.gartUsedBytes >> 25)
        case .memoryStorage:
            if prev.storage.readBytesPerSec > 0 && curr.storage.readBytesPerSec == 0 { return false }
            if prev.storage.writeBytesPerSec > 0 && curr.storage.writeBytesPerSec == 0 { return false }
            return abs(Int64(curr.memory.usedBytes) - Int64(prev.memory.usedBytes)) < 33_554_432 &&
                curr.memory.pressureLevel == prev.memory.pressureLevel &&
                curr.storage.hasSmart == prev.storage.hasSmart &&
                curr.storage.tempC == prev.storage.tempC &&
                curr.storage.lifeUsedPct == prev.storage.lifeUsedPct &&
                (curr.storage.availableBytes >> 26) == (prev.storage.availableBytes >> 26) &&
                abs(Int64(curr.storage.readBytesPerSec) - Int64(prev.storage.readBytesPerSec)) < 16_384 &&
                abs(Int64(curr.storage.writeBytesPerSec) - Int64(prev.storage.writeBytesPerSec)) < 16_384
        case .powerS0ix:
            return curr.power.present == prev.power.present &&
                curr.power.isPluggedIn == prev.power.isPluggedIn &&
                curr.power.isCharging == prev.power.isCharging &&
                widgetSafeRound(curr.power.percentage) == widgetSafeRound(prev.power.percentage) &&
                curr.power.cycleCount == prev.power.cycleCount &&
                abs(curr.power.batteryWatts - prev.power.batteryWatts) < 0.4 &&
                abs(curr.cpu.packagePowerW - prev.cpu.packagePowerW) < 0.5 &&
                curr.power.hasS0ix == prev.power.hasS0ix &&
                curr.power.lastCC7Pct == prev.power.lastCC7Pct &&
                curr.power.lastPC8Pct == prev.power.lastPC8Pct &&
                curr.power.lastDC9 == prev.power.lastDC9 &&
                curr.power.sleepCount == prev.power.sleepCount &&
                curr.power.lastWakeSource == prev.power.lastWakeSource
        case .network:
            if prev.network.rxBytesPerSec > 0 && curr.network.rxBytesPerSec == 0 { return false }
            if prev.network.txBytesPerSec > 0 && curr.network.txBytesPerSec == 0 { return false }
            return abs(Int64(curr.network.rxBytesPerSec) - Int64(prev.network.rxBytesPerSec)) < 4_096 &&
                abs(Int64(curr.network.txBytesPerSec) - Int64(prev.network.txBytesPerSec)) < 4_096 &&
                curr.network.ipv4 == prev.network.ipv4 &&
                curr.wifi.isAssociated == prev.wifi.isAssociated &&
                curr.wifi.ssid == prev.wifi.ssid &&
                abs(curr.wifi.txRateMbps - prev.wifi.txRateMbps) < 50 &&
                abs(curr.wifi.rssi - prev.wifi.rssi) < 3
        }
    }

    private func updateSparklinesOnly(
        rect: CGRect,
        preset: WidgetSizePreset,
        engine: TelemetryEngine,
        isDark: Bool
    ) {
        guard preset != .compact else { return }
        switch kind {
        case .cpuGpu:
            if preset == .standard {
                sparkline(at: 0).configure(
                    frame: CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36),
                    values: engine.cpuHistory.values,
                    maxValue: 100,
                    accent: .cyan,
                    isDark: isDark
                )
            } else if preset == .wide {
                let halfW = (rect.width - 10) * 0.5
                sparkline(at: 0).configure(
                    frame: CGRect(x: rect.minX, y: rect.maxY - 38, width: halfW, height: 38),
                    values: engine.cpuHistory.values,
                    maxValue: 100,
                    accent: .cyan,
                    isDark: isDark
                )
                sparkline(at: 1).configure(
                    frame: CGRect(x: rect.minX + halfW + 10, y: rect.maxY - 38, width: halfW, height: 38),
                    values: engine.gpuHistory.values,
                    maxValue: 100,
                    accent: .indigo,
                    isDark: isDark
                )
            }
        case .network:
            if preset == .standard {
                sparkline(at: 0).configure(
                    frame: CGRect(x: rect.minX, y: rect.maxY - 40, width: rect.width, height: 40),
                    values: engine.netRxHistory.values,
                    maxValue: nil,
                    accent: .cyan,
                    isDark: isDark
                )
            } else if preset == .wide {
                let halfW = (rect.width - 10) * 0.5
                sparkline(at: 0).configure(
                    frame: CGRect(x: rect.minX, y: rect.maxY - 42, width: halfW, height: 42),
                    values: engine.netRxHistory.values,
                    maxValue: nil,
                    accent: .cyan,
                    isDark: isDark
                )
                sparkline(at: 1).configure(
                    frame: CGRect(x: rect.minX + halfW + 10, y: rect.maxY - 42, width: halfW, height: 42),
                    values: engine.netTxHistory.values,
                    maxValue: nil,
                    accent: .emerald,
                    isDark: isDark
                )
            }
        case .memoryStorage, .powerS0ix:
            break
        }
    }

    // MARK: - 1. CPU + Iris Xe Layout

    private func layoutCpuGpu(
        rect: CGRect,
        preset: WidgetSizePreset,
        snapshot: SystemSnapshot,
        engine: TelemetryEngine,
        isDark: Bool
    ) {
        let cpu = snapshot.cpu
        let gpu = snapshot.gpu

        let titleLbl = label(at: 0)
        titleLbl.configure(text: "性能双核", size: 11.5, weight: .semibold, colorRole: .primary, monospaced: false)
        let titleS = titleLbl.measuredSize()
        titleLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rect.minY, width: titleS.width, height: titleS.height))

        var pillsUsed = 1
        let pkgPill = pill(at: 0)
        pkgPill.configure(text: "Pkg \(fmtTenths(cpu.packagePowerW))W", accent: .indigo)
        pkgPill.setFrameIfChanged(CGRect(
            x: rect.maxX - pkgPill.pillSize.width,
            y: rect.minY - 1,
            width: pkgPill.pillSize.width,
            height: pkgPill.pillSize.height
        ))

        if cpu.hasTemp {
            let tempPill = pill(at: 1)
            pillsUsed = 2
            tempPill.configure(
                text: MetricFormat.optionalTemp(true, cpu.packageTempC),
                accent: cpu.packageTempC >= 80 ? .coral : .cyan
            )
            tempPill.setFrameIfChanged(CGRect(
                x: pkgPill.frame.minX - 5 - tempPill.pillSize.width,
                y: rect.minY - 1,
                width: tempPill.pillSize.width,
                height: tempPill.pillSize.height
            ))
        }

        let ringSize: CGFloat = (preset == .compact) ? 54 : (preset == .standard ? 62 : 66)
        let ringLW: CGFloat = (preset == .compact) ? 5.5 : 6.5
        let rowY = rect.minY + ((preset == .compact) ? 24 : 26)
        let colW = (rect.width - 10) * 0.5

        ring(at: 0).configure(
            frame: CGRect(x: rect.minX, y: rowY, width: ringSize, height: ringSize),
            progress: cpu.totalUsage / 100.0,
            valueText: "\(widgetSafeRound(cpu.totalUsage))%",
            subtitle: "CPU",
            accent: .cyan,
            lineWidth: ringLW,
            isDark: isDark
        )

        let cpuTextX = rect.minX + ringSize + 8
        let cpuTextW = max(28, colW - ringSize - 8)
        let cpuTextY = rowY + (preset == .compact ? 8 : 6)

        let ghzLbl = label(at: 1)
        ghzLbl.configure(
            text: MetricFormat.menuGHz(cpu.maxFreqMHz),
            size: 12.5,
            weight: .bold,
            colorRole: .primary
        )
        ghzLbl.setFrameIfChanged(CGRect(x: cpuTextX, y: cpuTextY, width: cpuTextW, height: 16))

        let cstateLbl = label(at: 2)
        cstateLbl.configure(text: "C-State \(widgetSafeRound(cpu.pkgCStatePct))%", size: 10, weight: .medium, colorRole: .secondary)
        cstateLbl.setFrameIfChanged(CGRect(x: cpuTextX, y: cpuTextY + 18, width: cpuTextW, height: 14))

        let gpuColX = rect.minX + colW + 10
        ring(at: 1).configure(
            frame: CGRect(x: gpuColX, y: rowY, width: ringSize, height: ringSize),
            progress: gpu.usagePct / 100.0,
            valueText: "\(widgetSafeRound(gpu.usagePct))%",
            subtitle: "Xe",
            accent: .indigo,
            lineWidth: ringLW,
            isDark: isDark
        )

        let gpuTextX = gpuColX + ringSize + 8
        let gpuTextW = max(28, colW - ringSize - 8)
        let gtW = label(at: 3)
        gtW.configure(text: "\(fmtTenths(gpu.powerW))W GT", size: 12.5, weight: .bold, colorRole: .primary)
        gtW.setFrameIfChanged(CGRect(x: gpuTextX, y: cpuTextY, width: gpuTextW, height: 16))

        let rc6Lbl = label(at: 4)
        let gpuMid = gpu.hasFreq
            ? MetricFormat.optionalMHz(true, gpu.currentFreqMHz, isRC6: gpu.usagePct < 0.5)
            : "RC6 \(widgetSafeRound(gpu.rc6Pct))%"
        rc6Lbl.configure(text: gpuMid, size: 10, weight: .medium, colorRole: .secondary)
        rc6Lbl.setFrameIfChanged(CGRect(x: gpuTextX, y: cpuTextY + 18, width: gpuTextW, height: 14))

        var labelsUsed = 5
        if preset != .compact {
            let coreWLbl = label(at: 5)
            coreWLbl.configure(text: "核 \(fmtTenths(cpu.corePowerW))W", size: 10, weight: .medium, colorRole: .secondary)
            coreWLbl.setFrameIfChanged(CGRect(x: cpuTextX, y: cpuTextY + 33, width: cpuTextW, height: 14))

            let gartLbl = label(at: 6)
            gartLbl.configure(text: "GART \(MetricFormat.bytes(gpu.gartUsedBytes))", size: 9.5, weight: .medium, colorRole: .secondary)
            gartLbl.setFrameIfChanged(CGRect(x: gpuTextX, y: cpuTextY + 33, width: gpuTextW, height: 14))
            labelsUsed = 7
        }

        var sparksUsed = 0
        if preset == .standard {
            sparkline(at: 0).configure(
                frame: CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36),
                values: engine.cpuHistory.values,
                maxValue: 100,
                accent: .cyan,
                isDark: isDark
            )
            sparksUsed = 1
        } else if preset == .wide {
            let halfW = (rect.width - 10) * 0.5
            let capY = rect.maxY - 38 - 14
            let cCap = label(at: 7)
            cCap.configure(text: "CPU 60 点负载", size: 9.5, weight: .medium, colorRole: .secondary, monospaced: false)
            cCap.setFrameIfChanged(CGRect(x: rect.minX, y: capY, width: halfW, height: 13))

            let gCap = label(at: 8)
            gCap.configure(text: "Iris Xe 60 点负载", size: 9.5, weight: .medium, colorRole: .secondary, monospaced: false)
            gCap.setFrameIfChanged(CGRect(x: rect.minX + halfW + 10, y: capY, width: halfW, height: 13))
            labelsUsed = 9

            sparkline(at: 0).configure(
                frame: CGRect(x: rect.minX, y: rect.maxY - 38, width: halfW, height: 38),
                values: engine.cpuHistory.values,
                maxValue: 100,
                accent: .cyan,
                isDark: isDark
            )
            sparkline(at: 1).configure(
                frame: CGRect(x: rect.minX + halfW + 10, y: rect.maxY - 38, width: halfW, height: 38),
                values: engine.gpuHistory.values,
                maxValue: 100,
                accent: .indigo,
                isDark: isDark
            )
            sparksUsed = 2
        }

        hideUnused(labelsUsed: labelsUsed, pillsUsed: pillsUsed, ringsUsed: 2, sparksUsed: sparksUsed)
    }

    // MARK: - 2. Memory + NVMe Storage Layout

    private func layoutMemoryStorage(
        rect: CGRect,
        preset: WidgetSizePreset,
        snapshot: SystemSnapshot,
        isDark: Bool
    ) {
        let mem = snapshot.memory
        let sto = snapshot.storage
        let (pLabel, pAccent): (String, SenseiAccent) = {
            switch mem.pressureLevel {
            case 4: return ("紧张", .coral)
            case 2: return ("警告", .amber)
            default: return ("正常", .emerald)
            }
        }()

        let hLbl = label(at: 0)
        hLbl.configure(text: "内存 · LPDDR4X", size: 11.5, weight: .semibold, colorRole: .primary, monospaced: false)
        let hS = hLbl.measuredSize()
        hLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rect.minY, width: hS.width, height: hS.height))

        let pPill = pill(at: 0)
        pPill.configure(text: pLabel, accent: pAccent)
        pPill.setFrameIfChanged(CGRect(
            x: rect.maxX - pPill.pillSize.width,
            y: rect.minY - 1,
            width: pPill.pillSize.width,
            height: pPill.pillSize.height
        ))

        let usageLbl = label(at: 1)
        let totalTxt = mem.totalBytes > 0 ? MetricFormat.bytes(mem.totalBytes) : "16.0 GB"
        usageLbl.configure(text: "\(MetricFormat.bytes(mem.usedBytes)) / \(totalTxt)", size: 10.5, weight: .semibold, colorRole: .primary, alignment: .right)
        let uS = usageLbl.measuredSize()
        usageLbl.setFrameIfChanged(CGRect(x: pPill.frame.minX - 6 - uS.width, y: rect.minY + 1, width: uS.width, height: uS.height))

        let barY = rect.minY + (preset == .compact ? 22 : 25)
        barTrackLayer.frame = CGRect(x: rect.minX, y: barY, width: rect.width, height: 8)
        barTrackLayer.backgroundColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.10).cgColor

        let total = Double(max(mem.totalBytes, 1))
        let appW = rect.width * CGFloat(widgetClampUnit(Double(mem.appBytes) / total))
        let wiredW = rect.width * CGFloat(widgetClampUnit(Double(mem.wiredBytes) / total))
        let compW = min(max(0, rect.width - appW - wiredW), rect.width * CGFloat(widgetClampUnit(Double(mem.compressedBytes) / total)))
        barAppLayer.frame = CGRect(x: 0, y: 0, width: appW, height: 8)
        barWiredLayer.frame = CGRect(x: appW, y: 0, width: wiredW, height: 8)
        barCompLayer.frame = CGRect(x: appW + wiredW, y: 0, width: compW, height: 8)

        var cursorY = barY + 8 + (preset == .compact ? 9 : 10)
        var labelsUsed = 2
        if preset != .compact {
            var lx = rect.minX
            let items = [
                "应用 \(MetricFormat.bytes(mem.appBytes))",
                "联动 \(MetricFormat.bytes(mem.wiredBytes))",
                "压缩 \(MetricFormat.bytes(mem.compressedBytes))"
            ]
            for (i, txt) in items.enumerated() {
                dotLayers[i].isHidden = false
                dotLayers[i].frame = CGRect(x: lx, y: cursorY + 3.5, width: 6, height: 6)
                let l = label(at: labelsUsed)
                labelsUsed += 1
                l.configure(text: txt, size: 9.5, weight: .medium, colorRole: .secondary)
                let ls = l.measuredSize()
                l.setFrameIfChanged(CGRect(x: lx + 9, y: cursorY, width: ls.width, height: ls.height))
                lx += 9 + ls.width + 10
            }
            cursorY += 21
        } else {
            for d in dotLayers { d.isHidden = true }
        }

        dividerLayer.frame = CGRect(x: rect.minX, y: cursorY, width: rect.width, height: 1)
        dividerLayer.backgroundColor = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.08).cgColor
        cursorY += (preset == .compact ? 8 : 10)

        var pillsUsed = 1
        var titleMaxW = rect.width
        if sto.hasSmart {
            let sPill = pill(at: 1)
            pillsUsed = 2
            sPill.configure(
                text: "\(sto.tempC)°C · 寿命 \(max(0, 100 - Int(sto.lifeUsedPct)))%",
                accent: sto.tempC >= 70 ? .amber : .cyan
            )
            sPill.setFrameIfChanged(CGRect(
                x: rect.maxX - sPill.pillSize.width,
                y: cursorY - 1,
                width: sPill.pillSize.width,
                height: sPill.pillSize.height
            ))
            titleMaxW -= (sPill.pillSize.width + 8)
        }

        let nvmeLbl = label(at: labelsUsed)
        labelsUsed += 1
        nvmeLbl.configure(
            text: (preset == .wide && !sto.model.isEmpty) ? sto.model : "NVMe 存储",
            size: 11,
            weight: .semibold,
            colorRole: .primary,
            monospaced: false
        )
        nvmeLbl.setFrameIfChanged(CGRect(x: rect.minX, y: cursorY, width: max(40, titleMaxW), height: 15))

        let rateY = rect.maxY - 15
        let availLbl = label(at: labelsUsed)
        labelsUsed += 1
        availLbl.configure(text: "可用 \(MetricFormat.bytes(sto.availableBytes))", size: 10.5, weight: .medium, colorRole: .secondary)
        let avS = availLbl.measuredSize()
        availLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rateY, width: avS.width, height: avS.height))

        let wLbl = label(at: labelsUsed)
        labelsUsed += 1
        wLbl.configure(text: "W \(MetricFormat.rate(sto.writeBytesPerSec))", size: 10.5, weight: .semibold, colorRole: .accent(.indigo), alignment: .right)
        let wS = wLbl.measuredSize()
        wLbl.setFrameIfChanged(CGRect(x: rect.maxX - wS.width, y: rateY, width: wS.width, height: wS.height))

        let rLbl = label(at: labelsUsed)
        labelsUsed += 1
        rLbl.configure(text: "R \(MetricFormat.rate(sto.readBytesPerSec))", size: 10.5, weight: .semibold, colorRole: .accent(.cyan), alignment: .right)
        let rS = rLbl.measuredSize()
        rLbl.setFrameIfChanged(CGRect(x: wLbl.frame.minX - 10 - rS.width, y: rateY, width: rS.width, height: rS.height))

        hideUnused(labelsUsed: labelsUsed, pillsUsed: pillsUsed, ringsUsed: 0, sparksUsed: 0)
    }

    // MARK: - 3. Power & S0ix Layout

    private func layoutPowerS0ix(
        rect: CGRect,
        preset: WidgetSizePreset,
        snapshot: SystemSnapshot,
        isDark: Bool
    ) {
        let pwr = snapshot.power
        let fastKey: [Int] = [
            preset.hashValue,
            pwr.present ? 1 : 0,
            pwr.isPluggedIn ? 1 : 0,
            pwr.isCharging ? 1 : 0,
            widgetSafeRound(pwr.percentage),
            widgetSafeRound(pwr.healthPct),
            Int(pwr.cycleCount),
            widgetSafeRound(pwr.batteryWatts * 10),
            widgetSafeRound(snapshot.cpu.packagePowerW * 10),
            pwr.hasS0ix ? 1 : 0,
            Int(pwr.lastCC7Pct),
            Int(pwr.lastPC8Pct),
            pwr.lastDC9 ? 1 : 0,
            Int(pwr.sleepCount)
        ]
        if fastKey == lastPowerFastKey {
            return
        }
        lastPowerFastKey = fastKey
        let accent: SenseiAccent = pwr.isCharging
            ? .emerald
            : (pwr.present && pwr.percentage <= 20 ? .coral : .amber)

        let titleLbl = label(at: 0)
        titleLbl.configure(text: "电源与 S0ix 待机", size: 11.5, weight: .semibold, colorRole: .primary, monospaced: false)
        let tS = titleLbl.measuredSize()
        titleLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rect.minY, width: tS.width, height: tS.height))

        var pillsUsed = 0
        if pwr.present && preset != .compact {
            let hp = pill(at: pillsUsed)
            pillsUsed += 1
            hp.configure(text: "健康 \(widgetSafeRound(pwr.healthPct))% · \(pwr.cycleCount)次", accent: .emerald)
            hp.setFrameIfChanged(CGRect(x: rect.maxX - hp.pillSize.width, y: rect.minY - 1, width: hp.pillSize.width, height: hp.pillSize.height))
        }

        let ringSize: CGFloat = (preset == .compact) ? 54 : (preset == .standard ? 66 : 70)
        let ringLW: CGFloat = (preset == .compact) ? 5.5 : 6.5
        let bodyY = rect.minY + (preset == .compact ? 24 : 28)

        ring(at: 0).configure(
            frame: CGRect(x: rect.minX, y: bodyY, width: ringSize, height: ringSize),
            progress: pwr.percentage / 100.0,
            valueText: pwr.present ? "\(widgetSafeRound(pwr.percentage))%" : "AC",
            subtitle: pwr.isCharging ? "充电中" : (pwr.isPluggedIn ? "已插电" : "电池"),
            accent: accent,
            lineWidth: ringLW,
            isDark: isDark
        )

        let rightX = rect.minX + ringSize + 12
        let rightW = max(40, rect.maxX - rightX)
        let headline: String = {
            if pwr.present && abs(pwr.batteryWatts) >= 0.05 {
                return "\(fmtSignedTenths(pwr.batteryWatts)) W"
            }
            if pwr.isPluggedIn {
                return "AC · Pkg \(fmtTenths(snapshot.cpu.packagePowerW)) W"
            }
            return "\(fmtTenths(snapshot.cpu.packagePowerW)) W"
        }()

        let wLbl = label(at: 1)
        wLbl.configure(text: headline, size: preset == .compact ? 13 : 14.5, weight: .bold, colorRole: .primary)
        wLbl.setFrameIfChanged(CGRect(x: rightX, y: bodyY + 4, width: rightW, height: 19))

        var labelsUsed = 2
        if pwr.hasS0ix {
            let py = bodyY + (preset == .compact ? 25 : 28)
            let p1 = pill(at: pillsUsed)
            pillsUsed += 1
            p1.configure(text: "CC7 \(pwr.lastCC7Pct)%", accent: .cyan)
            p1.setFrameIfChanged(CGRect(x: rightX, y: py, width: p1.pillSize.width, height: p1.pillSize.height))

            let p2 = pill(at: pillsUsed)
            pillsUsed += 1
            p2.configure(text: "PC8 \(pwr.lastPC8Pct)%", accent: .indigo)
            p2.setFrameIfChanged(CGRect(x: p1.frame.maxX + 5, y: py, width: p2.pillSize.width, height: p2.pillSize.height))

            if preset != .compact {
                let p3 = pill(at: pillsUsed)
                pillsUsed += 1
                p3.configure(text: pwr.lastDC9 ? "DC9 ✓" : "DC9 —", accent: pwr.lastDC9 ? .emerald : .amber)
                p3.setFrameIfChanged(CGRect(x: p2.frame.maxX + 5, y: py, width: p3.pillSize.width, height: p3.pillSize.height))

                let wakeLbl = label(at: labelsUsed)
                labelsUsed += 1
                wakeLbl.configure(
                    text: "上次唤醒(#\(pwr.sleepCount)): \(pwr.lastWakeSource.isEmpty ? "未知" : pwr.lastWakeSource)",
                    size: 10,
                    weight: .medium,
                    colorRole: .secondary
                )
                wakeLbl.setFrameIfChanged(CGRect(x: rightX, y: py + p1.pillSize.height + 6, width: rightW, height: 14))
            }
        } else {
            let sLbl = label(at: labelsUsed)
            labelsUsed += 1
            sLbl.configure(text: "S0ix 待机统计将在睡眠唤醒后刷新", size: 10, weight: .medium, colorRole: .secondary, monospaced: false)
            sLbl.setFrameIfChanged(CGRect(x: rightX, y: bodyY + 28, width: rightW, height: 14))
        }

        hideUnused(labelsUsed: labelsUsed, pillsUsed: pillsUsed, ringsUsed: 1, sparksUsed: 0)
    }

    // MARK: - 4. Network Layout

    private func layoutNetwork(
        rect: CGRect,
        preset: WidgetSizePreset,
        snapshot: SystemSnapshot,
        engine: TelemetryEngine,
        isDark: Bool
    ) {
        let net = snapshot.network
        let wifi = snapshot.wifi
        let iface = net.primaryInterface.isEmpty
            ? (wifi.interfaceName.isEmpty ? "en1" : wifi.interfaceName)
            : net.primaryInterface
        let title: String = {
            if wifi.isAssociated {
                if let ssid = wifi.ssid, !ssid.isEmpty { return "\(ssid) (\(iface))" }
                let isWifi6 = wifi.phyMode == "802.11ax" || wifi.channelWidthMHz >= 160 || wifi.txRateMbps >= 1000
                return "\(isWifi6 ? "Wi-Fi 6" : "Wi-Fi") (\(iface))"
            }
            return "网络 (\(iface))"
        }()

        var pillsUsed = 0
        var titleMaxW = rect.width
        if wifi.isAssociated {
            let wp = pill(at: 0)
            pillsUsed = 1
            wp.configure(
                text: "\(widgetSafeRound(wifi.txRateMbps)) Mbps · \(wifi.rssi) dBm",
                accent: wifi.rssi >= -65 ? .emerald : .amber
            )
            wp.setFrameIfChanged(CGRect(x: rect.maxX - wp.pillSize.width, y: rect.minY - 1, width: wp.pillSize.width, height: wp.pillSize.height))
            titleMaxW -= (wp.pillSize.width + 8)
        }

        let tLbl = label(at: 0)
        tLbl.configure(text: title, size: 11.5, weight: .semibold, colorRole: .primary, monospaced: false)
        tLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rect.minY, width: max(40, titleMaxW), height: 16))

        let rateY = rect.minY + (preset == .compact ? 25 : 27)
        let rxLbl = label(at: 1)
        rxLbl.configure(text: "↓ \(MetricFormat.rate(net.rxBytesPerSec))", size: 12.5, weight: .bold, colorRole: .accent(.cyan))
        let rxS = rxLbl.measuredSize()
        rxLbl.setFrameIfChanged(CGRect(x: rect.minX, y: rateY, width: rxS.width, height: rxS.height))

        let txLbl = label(at: 2)
        txLbl.configure(text: "↑ \(MetricFormat.rate(net.txBytesPerSec))", size: 12.5, weight: .bold, colorRole: .accent(.emerald))
        let txS = txLbl.measuredSize()
        txLbl.setFrameIfChanged(CGRect(x: rxLbl.frame.maxX + 14, y: rateY, width: txS.width, height: txS.height))

        var labelsUsed = 3
        if preset != .compact, !net.ipv4.isEmpty {
            let ipLbl = label(at: 3)
            labelsUsed = 4
            ipLbl.configure(text: net.ipv4, size: 10, weight: .medium, colorRole: .secondary, alignment: .right)
            let ipS = ipLbl.measuredSize()
            ipLbl.setFrameIfChanged(CGRect(x: rect.maxX - ipS.width, y: rateY + 2, width: ipS.width, height: ipS.height))
        }

        var sparksUsed = 0
        if preset == .standard {
            sparkline(at: 0).configure(
                frame: CGRect(x: rect.minX, y: rect.maxY - 40, width: rect.width, height: 40),
                values: engine.netRxHistory.values,
                maxValue: nil,
                accent: .cyan,
                isDark: isDark
            )
            sparksUsed = 1
        } else if preset == .wide {
            let halfW = (rect.width - 10) * 0.5
            sparkline(at: 0).configure(
                frame: CGRect(x: rect.minX, y: rect.maxY - 42, width: halfW, height: 42),
                values: engine.netRxHistory.values,
                maxValue: nil,
                accent: .cyan,
                isDark: isDark
            )
            sparkline(at: 1).configure(
                frame: CGRect(x: rect.minX + halfW + 10, y: rect.maxY - 42, width: halfW, height: 42),
                values: engine.netTxHistory.values,
                maxValue: nil,
                accent: .emerald,
                isDark: isDark
            )
            sparksUsed = 2
        }

        hideUnused(labelsUsed: labelsUsed, pillsUsed: pillsUsed, ringsUsed: 0, sparksUsed: sparksUsed)
    }
}

// MARK: - Edit Mode Overlay (Mounted Only When Unlocked)

struct DesktopWidgetEditOverlayView: View {
    let kind: DesktopWidgetKind
    @ObservedObject var settings: SettingsStore
    @ObservedObject var manager: DesktopWidgetManager

    private var preset: WidgetSizePreset {
        manager.sizePreset(for: kind)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    SenseiAccent.cyan.primaryColor.opacity(0.92),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .allowsHitTesting(false)

            VStack {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("8pt")
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.62), in: Capsule())
                    .allowsHitTesting(false)

                    Spacer(minLength: 4)

                    HStack(spacing: 2) {
                        ForEach(WidgetSizePreset.allCases, id: \.self) { option in
                            let isSelected = (option == preset)
                            Button {
                                manager.setSizePreset(option, for: kind)
                            } label: {
                                Text(option.pillLabel)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.88))
                                    .frame(width: 20, height: 18)
                                    .background(
                                        isSelected
                                            ? SenseiAccent.cyan.primaryColor
                                            : Color.white.opacity(0.08),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.black.opacity(0.72), in: Capsule())

                    Button {
                        settings.widgetsLocked = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("完成锁定")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(SenseiAccent.cyan.primaryColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)

                Spacer()
            }
        }
    }
}
