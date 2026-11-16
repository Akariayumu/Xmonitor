import AppKit
import CoreGraphics
import SwiftUI

private final class AreaSparklineNSView: NSView {
    private var normalized: [Double] = [0.0, 0.0]
    private var quantizedKey: [Int] = []
    private var accent: SenseiAccent = .cyan
    private var targetHeight: CGFloat = 44

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: targetHeight)
    }

    func apply(normalized: [Double], accent: SenseiAccent, height: CGFloat) {
        let scale = Double(max(12.0, height) * 2.0)
        let key = normalized.map { Int(($0 * scale).rounded()) }
        let heightChanged = abs(self.targetHeight - height) > 0.01
        if key == self.quantizedKey, self.accent == accent, !heightChanged {
            return
        }
        self.normalized = normalized
        self.quantizedKey = key
        self.accent = accent
        self.targetHeight = height
        if heightChanged {
            invalidateIntrinsicContentSize()
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 2, normalized.count >= 2 else { return }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let topPad: CGFloat = 1.5
            let bottomPad: CGFloat = 1.0
            let plotHeight = max(1.0, size.height - topPad - bottomPad)
            let baselineY = size.height - bottomPad

            // 1. Subtle mid-scale dashed reference hairline
            let midY = topPad + plotHeight * 0.5
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.06).cgColor)
            ctx.setLineWidth(0.75)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: 0, y: midY))
            ctx.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.strokePath()
            ctx.restoreGState()

            let stepX = size.width / CGFloat(normalized.count - 1)
            func point(at index: Int) -> CGPoint {
                let x = CGFloat(index) * stepX
                let y = baselineY - CGFloat(normalized[index]) * plotHeight
                return CGPoint(x: x, y: y)
            }

            // 2. Monotone horizontal-tangent cubic Bezier path
            let linePath = CGMutablePath()
            var prev = point(at: 0)
            linePath.move(to: prev)
            for idx in 1..<normalized.count {
                let curr = point(at: idx)
                let midX = (prev.x + curr.x) * 0.5
                linePath.addCurve(
                    to: curr,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: curr.y)
                )
                prev = curr
            }

            guard let areaPath = linePath.mutableCopy() else { return }
            areaPath.addLine(to: CGPoint(x: size.width, y: baselineY))
            areaPath.addLine(to: CGPoint(x: 0, y: baselineY))
            areaPath.closeSubpath()

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

            // 3. Vertical area fill gradient
            let fillColors = [
                accent.primaryNSColor.withAlphaComponent(0.30).cgColor,
                accent.secondaryNSColor.withAlphaComponent(0.02).cgColor
            ] as CFArray
            if let fillGrad = CGGradient(colorsSpace: colorSpace, colors: fillColors, locations: [0.0, 1.0]) {
                ctx.saveGState()
                ctx.addPath(areaPath)
                ctx.clip()
                ctx.drawLinearGradient(
                    fillGrad,
                    start: CGPoint(x: 0, y: topPad),
                    end: CGPoint(x: 0, y: baselineY),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }

            // 4. Horizontal stroke gradient
            let strokedLine = linePath.copy(
                strokingWithWidth: 1.6,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            let strokeColors = [
                accent.primaryNSColor.cgColor,
                accent.secondaryNSColor.cgColor
            ] as CFArray
            if let strokeGrad = CGGradient(colorsSpace: colorSpace, colors: strokeColors, locations: [0.0, 1.0]) {
                ctx.saveGState()
                ctx.addPath(strokedLine)
                ctx.clip()
                ctx.drawLinearGradient(
                    strokeGrad,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
                ctx.restoreGState()
            }
        }
    }
}

private struct AreaSparklineRepresentable: NSViewRepresentable {
    let normalized: [Double]
    let accent: SenseiAccent
    let height: CGFloat

    func makeNSView(context: Context) -> AreaSparklineNSView {
        let view = AreaSparklineNSView(frame: NSRect(x: 0, y: 0, width: 120, height: height))
        view.apply(normalized: normalized, accent: accent, height: height)
        return view
    }

    func updateNSView(_ nsView: AreaSparklineNSView, context: Context) {
        nsView.apply(normalized: normalized, accent: accent, height: height)
    }
}

struct AreaSparkline: View {
    private let values: [Double]
    private let maxValue: Double?
    private let accent: SenseiAccent
    private let height: CGFloat

    init(
        values: [Double],
        maxValue: Double? = nil,
        accent: SenseiAccent = .cyan,
        height: CGFloat = 44
    ) {
        self.values = values
        self.maxValue = maxValue
        self.accent = accent
        self.height = max(12, height)
    }

    init(
        buffer: FixedRingBuffer<Double>,
        maxValue: Double? = nil,
        accent: SenseiAccent = .cyan,
        height: CGFloat = 44
    ) {
        self.init(values: buffer.values, maxValue: maxValue, accent: accent, height: height)
    }

    static func normalizedSamples(values: [Double], maxValue: Double?) -> [Double] {
        let sanitized = values.map { $0.isFinite ? max(0.0, $0) : 0.0 }
        guard !sanitized.isEmpty else {
            return [0.0, 0.0]
        }

        let ceiling: Double
        if let explicitMax = maxValue, explicitMax.isFinite, explicitMax > 0 {
            ceiling = explicitMax
        } else {
            let peak = sanitized.max() ?? 0.0
            ceiling = peak > 0 ? (peak * 1.10) : 1.0
        }

        let scaled = sanitized.map { min(max($0 / ceiling, 0.0), 1.0) }
        if scaled.count == 1 {
            return [scaled[0], scaled[0]]
        }
        return scaled
    }

    var body: some View {
        let normalized = Self.normalizedSamples(values: values, maxValue: maxValue)
        AreaSparklineRepresentable(
            normalized: normalized,
            accent: accent,
            height: height
        )
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
