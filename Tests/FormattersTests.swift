import AppKit
import Foundation
import SwiftUI

@MainActor
func runFormattersTests() throws {
    // 1. Fixed character length guarantees zero menu-bar width jitter under monospaced digits
    try expectEqual(MetricFormat.menuPercent(0).count, MetricFormat.menuPercent(99.6).count, "menu % fixed width")
    try expectEqual(MetricFormat.menuPercent(0), "  0%", "menu % zero")
    try expectEqual(MetricFormat.menuPercent(4), "  4%", "menu % single digit")
    try expectEqual(MetricFormat.menuPercent(42.3), " 42%", "menu % double digit")
    try expectEqual(MetricFormat.menuPercent(99.6), "100%", "menu % rounds to 100%")
    for sample in [-15.0, 0.0, 4.2, 42.8, 99.6, 100.0, 240.0, Double.nan, Double.infinity] {
        try expectEqual(MetricFormat.menuPercent(sample).count, 4, "menu % always 4 chars for \(sample)")
    }

    // 2. Menu GHz fixed width
    try expectEqual(MetricFormat.menuGHz(845).count, MetricFormat.menuGHz(4665).count, "menu GHz fixed width")
    try expectEqual(MetricFormat.menuGHz(0), "0.0G", "menu GHz zero")
    try expectEqual(MetricFormat.menuGHz(845), "0.8G", "menu GHz 845 MHz")
    try expectEqual(MetricFormat.menuGHz(4665), "4.7G", "menu GHz 4665 MHz")
    for sample in [-500.0, 0.0, 845.0, 2800.0, 4665.0, 12000.0, Double.nan] {
        try expectEqual(MetricFormat.menuGHz(sample).count, 4, "menu GHz always 4 chars for \(sample)")
    }

    // 3. Menu Watts fixed width
    try expectEqual(MetricFormat.menuWatts(4.1), " 4.1W", "menu Watts single digit")
    try expectEqual(MetricFormat.menuWatts(38.5), "38.5W", "menu Watts double digit")
    try expectEqual(MetricFormat.menuWatts(-6.2), " 6.2W", "menu Watts signed discharge magnitude")
    for sample in [-18.4, -4.1, 0.0, 4.1, 38.5, 99.9, 145.0, Double.nan] {
        try expectEqual(MetricFormat.menuWatts(sample).count, 5, "menu Watts always 5 chars for \(sample)")
    }

    // 4. Bytes & throughput rates
    try expectEqual(MetricFormat.bytes(0), "0 B", "0 bytes")
    try expectEqual(MetricFormat.bytes(512), "512 B", "512 bytes")
    try expectEqual(MetricFormat.bytes(4 * 1024), "4.0 KB", "4 KB")
    try expectEqual(MetricFormat.bytes(512 * 1024), "512 KB", "512 KB")
    try expectEqual(MetricFormat.bytes(24 * 1024 * 1024), "24.0 MB", "24 MB")
    try expectEqual(MetricFormat.bytes(16 * 1024 * 1024 * 1024), "16.0 GB", "16 GB RAM")
    try expectEqual(MetricFormat.bytes(1024 * 1024 * 1024 * 1024), "1.00 TB", "1 TB")

    try expectEqual(MetricFormat.rate(0), "0 B/s", "0 rate")
    try expectEqual(MetricFormat.rate(2048), "2.0 KB/s", "2 KB/s")
    try expectEqual(MetricFormat.rate(512 * 1024), "512 KB/s", "512 KB/s")
    try expectEqual(MetricFormat.rate(15 * 1024 * 1024), "15.0 MB/s", "15 MB/s")
    try expectEqual(MetricFormat.rate(2 * 1024 * 1024 * 1024), "2.00 GB/s", "2 GB/s")

    // 5. Uptime formatting
    try expectEqual(MetricFormat.uptime(0), "0m", "zero uptime")
    try expectEqual(MetricFormat.uptime(45), "45s", "sub-minute uptime")
    try expectEqual(MetricFormat.uptime(300), "5m", "minutes uptime")
    try expectEqual(MetricFormat.uptime(3661), "1h 1m", "hours + minutes uptime")
    try expectEqual(MetricFormat.uptime(90061), "1d 1h 1m", "days + hours + minutes uptime")
    try expectEqual(MetricFormat.uptime(.nan), "0m", "NaN uptime safe fallback")

    // 6. Optional sensor graceful degradation
    try expectEqual(MetricFormat.optionalTemp(false, 0), "—", "missing SMC temp graceful dash")
    try expectEqual(MetricFormat.optionalTemp(true, 46.4), "46°C", "present SMC temp")
    try expectEqual(MetricFormat.optionalTemp(true, 46.6), "47°C", "present SMC temp rounds")
    try expectEqual(MetricFormat.optionalTemp(true, .nan), "—", "NaN temp fallback")

    try expectEqual(MetricFormat.optionalMHz(false, 0, isRC6: true), "—", "missing GPU MHz graceful dash")
    try expectEqual(MetricFormat.optionalMHz(true, 0, isRC6: true), "0 MHz (RC6)", "RC6 idle label")
    try expectEqual(MetricFormat.optionalMHz(true, 1150, isRC6: false), "1150 MHz", "active GPU MHz")

    // 7. SenseiPalette & SenseiAccent contract
    try expectEqual(SenseiAccent.allCases.count, 6, "all 6 Sensei accents")
    for accent in SenseiAccent.allCases {
        _ = accent.primaryColor
        _ = accent.secondaryColor
        _ = accent.gradient
    }
    try expectEqual(SenseiPalette.colorScheme(for: .system), nil, "system mode maps to nil ColorScheme")
    try expectEqual(SenseiPalette.colorScheme(for: .darkGraphite), .dark, "darkGraphite maps to .dark")
    try expectEqual(SenseiPalette.colorScheme(for: .lightFrost), .light, "lightFrost maps to .light")

    // 8. RingGauge fractional clamping & AreaSparkline normalization
    try expectApprox(RingGauge.clampedProgress(-0.25), 0.0, tol: 1e-9, "RingGauge negative clamps to 0")
    try expectApprox(RingGauge.clampedProgress(0.42), 0.42, tol: 1e-9, "RingGauge fractional pass-through")
    try expectApprox(RingGauge.clampedProgress(1.35), 1.0, tol: 1e-9, "RingGauge >1 clamps to 1")
    try expectApprox(RingGauge.clampedProgress(.nan), 0.0, tol: 1e-9, "RingGauge NaN clamps to 0")

    let normFixed = AreaSparkline.normalizedSamples(values: [0, 50, 100, 150, -10, .nan], maxValue: 100)
    try expectEqual(normFixed.count, 6, "sparkline normalized sample count")
    try expectApprox(normFixed[0], 0.0, tol: 1e-9, "sparkline 0%")
    try expectApprox(normFixed[1], 0.5, tol: 1e-9, "sparkline 50%")
    try expectApprox(normFixed[2], 1.0, tol: 1e-9, "sparkline 100%")
    try expectApprox(normFixed[3], 1.0, tol: 1e-9, "sparkline >max clamps to 1")
    try expectApprox(normFixed[4], 0.0, tol: 1e-9, "sparkline negative clamps to 0")
    try expectApprox(normFixed[5], 0.0, tol: 1e-9, "sparkline NaN clamps to 0")

    let normEmpty = AreaSparkline.normalizedSamples(values: [], maxValue: nil)
    try expectEqual(normEmpty, [0.0, 0.0], "empty sparkline produces flat 2-point baseline")

    // 9. Smoke-render all SwiftUI theme components inside NSHostingView (verifies exact init signatures & layout)
    var ringBuf = FixedRingBuffer<Double>(capacity: 60, repeating: 0)
    for i in 0..<60 {
        ringBuf.append(Double(i))
    }

    let compositeView = GlassCard(padding: 14, cornerRadius: 16, opacity: 0.88) {
        VStack(spacing: 8) {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow, opacity: 0.9)
                .frame(width: 120, height: 20)
            RingGauge(
                progress: 0.64,
                valueText: "64%",
                subtitle: "2.8G",
                accent: .cyan,
                size: 76,
                lineWidth: 7.5
            )
            AreaSparkline(values: ringBuf.values, maxValue: 100, accent: .indigo, height: 44)
            AreaSparkline(buffer: ringBuf, maxValue: nil, accent: .emerald, height: 36)
        }
    }
    .preferredColorScheme(SenseiPalette.colorScheme(for: .darkGraphite))

    let hosting = NSHostingView(rootView: compositeView)
    hosting.frame = CGRect(x: 0, y: 0, width: 240, height: 220)
    hosting.layoutSubtreeIfNeeded()
    try expectTrue(hosting.fittingSize.width > 0 && hosting.fittingSize.height > 0, "SwiftUI GlassCard/RingGauge/AreaSparkline layout valid")
}
