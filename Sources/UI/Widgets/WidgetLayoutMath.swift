import CoreGraphics
import Foundation

enum DesktopWidgetKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpuGpu
    case memoryStorage
    case powerS0ix
    case network

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .cpuGpu:
            return "性能双核 (CPU + Iris Xe)"
        case .memoryStorage:
            return "内存与存储 (RAM + NVMe)"
        case .powerS0ix:
            return "电源与 S0ix 待机"
        case .network:
            return "无线网络 (Wi-Fi 6)"
        }
    }

    var shortTitle: String {
        switch self {
        case .cpuGpu:
            return "性能双核"
        case .memoryStorage:
            return "内存与存储"
        case .powerS0ix:
            return "电源与 S0ix"
        case .network:
            return "Wi-Fi 6 网络"
        }
    }

    var symbolName: String {
        switch self {
        case .cpuGpu:
            return "cpu"
        case .memoryStorage:
            return "memorychip"
        case .powerS0ix:
            return "bolt.batteryblock"
        case .network:
            return "wifi"
        }
    }

    func size(for preset: WidgetSizePreset) -> CGSize {
        switch (self, preset) {
        case (.cpuGpu, .compact):
            return CGSize(width: 264, height: 144)
        case (.cpuGpu, .standard):
            return CGSize(width: 320, height: 192)
        case (.cpuGpu, .wide):
            return CGSize(width: 392, height: 208)

        case (.memoryStorage, .compact):
            return CGSize(width: 264, height: 144)
        case (.memoryStorage, .standard):
            return CGSize(width: 320, height: 184)
        case (.memoryStorage, .wide):
            return CGSize(width: 392, height: 200)

        case (.powerS0ix, .compact):
            return CGSize(width: 264, height: 136)
        case (.powerS0ix, .standard):
            return CGSize(width: 320, height: 176)
        case (.powerS0ix, .wide):
            return CGSize(width: 392, height: 192)

        case (.network, .compact):
            return CGSize(width: 264, height: 136)
        case (.network, .standard):
            return CGSize(width: 320, height: 176)
        case (.network, .wide):
            return CGSize(width: 392, height: 192)
        }
    }
}

enum WidgetSizePreset: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case wide

    var pillLabel: String {
        switch self {
        case .compact: return "S"
        case .standard: return "M"
        case .wide: return "L"
        }
    }

    var displayTitle: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .wide: return "宽幅"
        }
    }
}

enum WidgetLayoutMath {
    static let defaultGridStep: CGFloat = 8.0
    static let defaultScreenMargin: CGFloat = 24.0
    static let defaultStackSpacing: CGFloat = 16.0

    /// Default stacking order from top-right downward so `.cpuGpu` and `.powerS0ix`
    /// sit flush together on first launch with zero gap between them.
    private static let stackOrder: [DesktopWidgetKind] = [
        .cpuGpu,
        .powerS0ix,
        .memoryStorage,
        .network
    ]

    static func snapToGrid(_ point: CGPoint, step: CGFloat = 8.0) -> CGPoint {
        guard step.isFinite, step > 0 else { return point }
        let sx = point.x.isFinite ? (point.x / step).rounded() * step : 0
        let sy = point.y.isFinite ? (point.y / step).rounded() * step : 0
        return CGPoint(x: sx, y: sy)
    }

    static func resolvedFrame(
        normalizedOrigin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let vf = visibleFrame.standardized
        guard vf.width > 0, vf.height > 0 else {
            return CGRect(origin: vf.origin, size: .zero)
        }

        let rawW = size.width.isFinite ? max(0, size.width) : 0
        let rawH = size.height.isFinite ? max(0, size.height) : 0
        let clampedW = min(rawW, vf.width)
        let clampedH = min(rawH, vf.height)

        let nx = normalizedOrigin.x.isFinite ? min(1.0, max(0.0, normalizedOrigin.x)) : 0.0
        let ny = normalizedOrigin.y.isFinite ? min(1.0, max(0.0, normalizedOrigin.y)) : 0.0

        let travelX = max(0, vf.width - clampedW)
        let travelY = max(0, vf.height - clampedH)

        var x = min(vf.minX + travelX, max(vf.minX, vf.minX + nx * travelX))
        var y = min(vf.minY + travelY, max(vf.minY, vf.minY + ny * travelY))

        if x + clampedW > vf.maxX {
            x = max(vf.minX, (vf.maxX - clampedW).nextDown)
        }
        if y + clampedH > vf.maxY {
            y = max(vf.minY, (vf.maxY - clampedH).nextDown)
        }

        return CGRect(x: x, y: y, width: clampedW, height: clampedH)
    }

    static func normalizedOrigin(for frame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let vf = visibleFrame.standardized
        let stdFrame = frame.standardized
        guard vf.width > 0, vf.height > 0 else {
            return .zero
        }

        let clampedW = min(max(0, stdFrame.width), vf.width)
        let clampedH = min(max(0, stdFrame.height), vf.height)
        let travelX = vf.width - clampedW
        let travelY = vf.height - clampedH

        let nx: CGFloat
        if travelX > 0, stdFrame.minX.isFinite {
            nx = min(1.0, max(0.0, (stdFrame.minX - vf.minX) / travelX))
        } else {
            nx = 0.0
        }

        let ny: CGFloat
        if travelY > 0, stdFrame.minY.isFinite {
            ny = min(1.0, max(0.0, (stdFrame.minY - vf.minY) / travelY))
        } else {
            ny = 0.0
        }

        return CGPoint(x: nx, y: ny)
    }

    static func snappedAndClampedFrame(
        origin: CGPoint,
        size: CGSize,
        visibleFrame: CGRect,
        step: CGFloat = defaultGridStep
    ) -> CGRect {
        let vf = visibleFrame.standardized
        guard vf.width > 0, vf.height > 0 else {
            return CGRect(origin: vf.origin, size: .zero)
        }

        let clampedW = min(max(0, size.width), vf.width)
        let clampedH = min(max(0, size.height), vf.height)
        let snapped = snapToGrid(origin, step: step)

        var x = min(vf.maxX - clampedW, max(vf.minX, snapped.x))
        var y = min(vf.maxY - clampedH, max(vf.minY, snapped.y))
        if x + clampedW > vf.maxX {
            x = max(vf.minX, (vf.maxX - clampedW).nextDown)
        }
        if y + clampedH > vf.maxY {
            y = max(vf.minY, (vf.maxY - clampedH).nextDown)
        }
        return CGRect(x: x, y: y, width: clampedW, height: clampedH)
    }

    static func defaultFrame(
        for targetKind: DesktopWidgetKind,
        size: CGSize,
        in visibleFrame: CGRect,
        presetLookup: (DesktopWidgetKind) -> WidgetSizePreset = { _ in .standard },
        margin: CGFloat = defaultScreenMargin,
        spacing: CGFloat = defaultStackSpacing
    ) -> CGRect {
        let vf = visibleFrame.standardized
        guard vf.width > 0, vf.height > 0 else {
            return CGRect(origin: vf.origin, size: .zero)
        }

        var cursorTopY = vf.maxY - margin
        var columnRightX = vf.maxX - margin
        var columnMaxWidth: CGFloat = 0

        for kind in stackOrder {
            let itemSize = (kind == targetKind) ? size : kind.size(for: presetLookup(kind))
            let clampedW = min(max(0, itemSize.width), vf.width)
            let clampedH = min(max(0, itemSize.height), vf.height)

            if cursorTopY - clampedH < vf.minY + margin && columnMaxWidth > 0 {
                columnRightX -= (columnMaxWidth + spacing)
                cursorTopY = vf.maxY - margin
                columnMaxWidth = 0
            }

            let rawOrigin = CGPoint(
                x: columnRightX - clampedW,
                y: cursorTopY - clampedH
            )
            let candidate = snappedAndClampedFrame(
                origin: rawOrigin,
                size: CGSize(width: clampedW, height: clampedH),
                visibleFrame: vf,
                step: defaultGridStep
            )

            if kind == targetKind {
                return candidate
            }

            cursorTopY = candidate.minY - spacing
            columnMaxWidth = max(columnMaxWidth, clampedW)
        }

        return snappedAndClampedFrame(
            origin: CGPoint(x: vf.maxX - margin - size.width, y: vf.maxY - margin - size.height),
            size: size,
            visibleFrame: vf,
            step: defaultGridStep
        )
    }
}
