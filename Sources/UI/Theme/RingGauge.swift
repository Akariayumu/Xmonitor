import AppKit
import CoreGraphics
import SwiftUI

private final class RingGaugeNSView: NSView {
    private var quantizedProgress: Int = -1
    private var progress: Double = 0
    private var valueText: String = ""
    private var subtitle: String = ""
    private var accent: SenseiAccent = .cyan
    private var gaugeSize: CGFloat = 76
    private var lineWidth: CGFloat = 7.5

    override var intrinsicContentSize: NSSize {
        NSSize(width: gaugeSize, height: gaugeSize)
    }

    func apply(
        progress: Double,
        valueText: String,
        subtitle: String,
        accent: SenseiAccent,
        size: CGFloat,
        lineWidth: CGFloat
    ) {
        let q = Int((progress * 360.0).rounded())
        let sizeChanged = abs(self.gaugeSize - size) > 0.01
        if q == self.quantizedProgress,
           self.valueText == valueText,
           self.subtitle == subtitle,
           self.accent == accent,
           !sizeChanged,
           abs(self.lineWidth - lineWidth) <= 0.01 {
            return
        }
        self.quantizedProgress = q
        self.progress = progress
        self.valueText = valueText
        self.subtitle = subtitle
        self.accent = accent
        self.gaugeSize = size
        self.lineWidth = lineWidth
        if sizeChanged {
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
        let b = bounds
        guard b.width > 4, b.height > 4 else { return }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let diameter = min(b.width, b.height)
            let radius = max(1.0, (diameter - lineWidth) * 0.5)
            let center = CGPoint(x: b.midX, y: b.midY)

            // 1. Track circle
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.10).cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2.0, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()

            // 2. Active arc (12 o'clock clockwise in unflipped AppKit coordinates)
            if progress > 0.0005 {
                let startAngle = CGFloat.pi * 0.5
                let endAngle = startAngle - CGFloat.pi * 2.0 * CGFloat(progress)
                let arcPath = CGMutablePath()
                arcPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: true
                )
                let strokedArc = arcPath.copy(
                    strokingWithWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round,
                    miterLimit: 10
                )
                let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let colors = [accent.primaryNSColor.cgColor, accent.secondaryNSColor.cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                    ctx.saveGState()
                    ctx.addPath(strokedArc)
                    ctx.clip()
                    ctx.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: b.minX, y: b.maxY),
                        end: CGPoint(x: b.maxX, y: b.minY),
                        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                    )
                    ctx.restoreGState()
                }
            }

            // 3. Value & subtitle labels
            let innerWidth = max(16.0, diameter - lineWidth * 2.5)
            let valAttrs = fittedAttributes(
                text: valueText,
                baseSize: max(10.5, diameter * 0.21),
                minScale: 0.6,
                weight: .semibold,
                color: .labelColor,
                maxWidth: innerWidth
            )
            let valSize = (valueText as NSString).size(withAttributes: valAttrs)

            if subtitle.isEmpty {
                let valRect = CGRect(
                    x: center.x - valSize.width * 0.5,
                    y: center.y - valSize.height * 0.5,
                    width: valSize.width,
                    height: valSize.height
                )
                (valueText as NSString).draw(in: valRect, withAttributes: valAttrs)
            } else {
                let subAttrs = fittedAttributes(
                    text: subtitle,
                    baseSize: max(8.5, diameter * 0.125),
                    minScale: 0.65,
                    weight: .medium,
                    color: .secondaryLabelColor,
                    maxWidth: innerWidth
                )
                let subSize = (subtitle as NSString).size(withAttributes: subAttrs)
                let spacing: CGFloat = 1.0
                let totalH = valSize.height + spacing + subSize.height
                let subY = center.y - totalH * 0.5
                let valY = subY + subSize.height + spacing

                (valueText as NSString).draw(
                    in: CGRect(
                        x: center.x - valSize.width * 0.5,
                        y: valY,
                        width: valSize.width,
                        height: valSize.height
                    ),
                    withAttributes: valAttrs
                )
                (subtitle as NSString).draw(
                    in: CGRect(
                        x: center.x - subSize.width * 0.5,
                        y: subY,
                        width: subSize.width,
                        height: subSize.height
                    ),
                    withAttributes: subAttrs
                )
            }
        }
    }

    private func fittedAttributes(
        text: String,
        baseSize: CGFloat,
        minScale: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        maxWidth: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var font = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: weight)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rawSize = (text as NSString).size(withAttributes: attrs)
        if rawSize.width > maxWidth, rawSize.width > 0 {
            let scale = max(minScale, maxWidth / rawSize.width)
            font = NSFont.monospacedDigitSystemFont(ofSize: baseSize * scale, weight: weight)
            attrs[.font] = font
        }
        return attrs
    }
}

private struct RingGaugeRepresentable: NSViewRepresentable {
    let progress: Double
    let valueText: String
    let subtitle: String
    let accent: SenseiAccent
    let size: CGFloat
    let lineWidth: CGFloat

    func makeNSView(context: Context) -> RingGaugeNSView {
        let view = RingGaugeNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.apply(
            progress: progress,
            valueText: valueText,
            subtitle: subtitle,
            accent: accent,
            size: size,
            lineWidth: lineWidth
        )
        return view
    }

    func updateNSView(_ nsView: RingGaugeNSView, context: Context) {
        nsView.apply(
            progress: progress,
            valueText: valueText,
            subtitle: subtitle,
            accent: accent,
            size: size,
            lineWidth: lineWidth
        )
    }
}

struct RingGauge: View, Equatable {
    private let progress: Double
    private let valueText: String
    private let subtitle: String
    private let accent: SenseiAccent
    private let size: CGFloat
    private let lineWidth: CGFloat

    /// `progress` is a fractional value in `0.0...1.0` (callers pass `pct / 100.0`).
    init(
        progress: Double,
        valueText: String,
        subtitle: String = "",
        accent: SenseiAccent = .cyan,
        size: CGFloat = 76,
        lineWidth: CGFloat = 7.5
    ) {
        self.progress = Self.clampedProgress(progress)
        self.valueText = valueText
        self.subtitle = subtitle
        self.accent = accent
        self.size = max(24, size)
        self.lineWidth = max(2, lineWidth)
    }

    static func clampedProgress(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0.0 }
        return min(max(raw, 0.0), 1.0)
    }

    static func == (lhs: RingGauge, rhs: RingGauge) -> Bool {
        Int((lhs.progress * 360.0).rounded()) == Int((rhs.progress * 360.0).rounded()) &&
        lhs.valueText == rhs.valueText &&
        lhs.subtitle == rhs.subtitle &&
        lhs.accent == rhs.accent &&
        abs(lhs.size - rhs.size) <= 0.01 &&
        abs(lhs.lineWidth - rhs.lineWidth) <= 0.01
    }

    var body: some View {
        RingGaugeRepresentable(
            progress: progress,
            valueText: valueText,
            subtitle: subtitle,
            accent: accent,
            size: size,
            lineWidth: lineWidth
        )
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle.isEmpty ? "Gauge" : subtitle)
        .accessibilityValue(valueText)
    }
}
