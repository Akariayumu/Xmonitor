import AppKit
import CoreGraphics
import Foundation
import SwiftUI

enum ConsoleFormat {
    static func percent1(_ value: Double) -> String {
        guard value.isFinite else { return "0.0%" }
        let clamped = min(100.0, max(0.0, value))
        return String(format: "%.1f%%", clamped)
    }

    static func percentInt(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        let clamped = min(100, max(0, Int(value.rounded())))
        return "\(clamped)%"
    }

    static func ghz(_ mhz: Double) -> String {
        guard mhz.isFinite, mhz > 0 else { return "0.00 GHz" }
        return String(format: "%.2f GHz", mhz / 1000.0)
    }

    static func mhzInt(_ mhz: Double) -> String {
        guard mhz.isFinite else { return "0 MHz" }
        return "\(max(0, Int(mhz.rounded()))) MHz"
    }

    static func watts2(_ watts: Double) -> String {
        guard watts.isFinite else { return "0.00 W" }
        return String(format: "%.2f W", max(0.0, watts))
    }

    static func signedWatts(_ watts: Double) -> String {
        guard watts.isFinite else { return "0.0 W" }
        if abs(watts) < 0.05 {
            return "0.0 W"
        }
        return String(format: "%+.1f W", watts)
    }

    static func pressureInfo(_ level: Int32) -> (label: String, detail: String, accent: SenseiAccent) {
        switch level {
        case 4:
            return ("紧急 Critical", "XNU VM 压缩器高负载，建议释放大型驻留进程", .coral)
        case 2:
            return ("警告 Warning", "可用页水位偏低，XNU 正在回收文件缓存", .amber)
        default:
            return ("正常 Normal", "LPDDR4X 内存充裕，零压力运行", .emerald)
        }
    }

    static func seriesStats(_ values: [Double]) -> (min: Double, avg: Double, max: Double) {
        guard !values.isEmpty else { return (0, 0, 0) }
        var lo = values[0]
        var hi = values[0]
        var sum = 0.0
        for v in values {
            if v < lo { lo = v }
            if v > hi { hi = v }
            sum += v
        }
        return (lo, sum / Double(values.count), hi)
    }

    static func activeDisplaySummary() -> (panelSpec: String, activeMode: String, refreshHz: String) {
        let panel = "3840×2400 @ 60Hz"
        let displayID = CGMainDisplayID()
        guard displayID != 0, let mode = CGDisplayCopyDisplayMode(displayID) else {
            return (panel, "HiDPI 2x", "60 Hz")
        }
        let logicalW = mode.width
        let logicalH = mode.height
        let pixelW = mode.pixelWidth
        let pixelH = mode.pixelHeight
        let hz = mode.refreshRate > 0 ? Int(mode.refreshRate.rounded()) : 60
        let hiDPI = (pixelW > logicalW || pixelH > logicalH)
            ? "HiDPI (\(logicalW)×\(logicalH))"
            : "\(logicalW)×\(logicalH)"
        return (panel, hiDPI, "\(hz) Hz")
    }
}

struct ConsoleBadge: View {
    let text: String
    var icon: String? = nil
    var accent: SenseiAccent = .cyan

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(accent.primaryColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(accent.primaryColor.opacity(0.14))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(accent.primaryColor.opacity(0.28), lineWidth: 0.8)
                )
        )
    }
}

struct ConsoleSectionHeader: View {
    let title: String
    var subtitle: String = ""
    var icon: String
    var accent: SenseiAccent = .cyan
    var trailingBadge: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.primaryColor.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.primaryColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let trailingBadge {
                ConsoleBadge(text: trailingBadge, accent: accent)
            }
        }
    }
}

struct ConsoleLinearBar: View {
    let fraction: Double
    var accent: SenseiAccent = .cyan
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1.0, max(0.0, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                Capsule(style: .continuous)
                    .fill(accent.gradient)
                    .frame(width: max(clamped > 0 ? height : 0, geo.size.width * clamped))
            }
        }
        .frame(height: height)
    }
}

struct ConsoleStatRow: View {
    let label: String
    let value: String
    var valueAccent: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueAccent ?? .primary)
                .lineLimit(1)
        }
    }
}

struct ConsoleRootView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var widgetManager: DesktopWidgetManager
    @ObservedObject var navigation: ConsoleNavigationModel

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 256)
        } detail: {
            detailContainer
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 640)
        .preferredColorScheme(SenseiPalette.colorScheme(for: settings.themeMode))
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            sidebarBrandHeader
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: $navigation.selectedTab) {
                Section("全景概览") {
                    sidebarRow(for: .overview, badge: MetricFormat.uptime(engine.snapshot.uptimeSeconds))
                }

                Section("硬件遥测") {
                    sidebarRow(for: .cpu, badge: MetricFormat.menuPercent(engine.snapshot.cpu.totalUsage))
                    sidebarRow(for: .gpu, badge: MetricFormat.menuPercent(engine.snapshot.gpu.usagePct))
                    sidebarRow(for: .memory, badge: MetricFormat.menuPercent(engine.snapshot.memory.usedPercent))
                    sidebarRow(
                        for: .storage,
                        badge: engine.snapshot.storage.hasSmart
                            ? "\(engine.snapshot.storage.tempC)°C"
                            : MetricFormat.menuPercent(engine.snapshot.storage.usedPercent)
                    )
                    sidebarRow(
                        for: .powerS0ix,
                        badge: engine.snapshot.power.present
                            ? "\(Int(engine.snapshot.power.percentage.rounded()))%"
                            : "AC"
                    )
                    sidebarRow(
                        for: .network,
                        badge: MetricFormat.rate(engine.snapshot.network.rxBytesPerSec)
                    )
                }

                Section("系统与偏好") {
                    sidebarRow(
                        for: .processesSettings,
                        badge: "\(engine.snapshot.topProcesses.count)"
                    )
                }
            }
            .listStyle(.sidebar)

            Divider().opacity(0.45)

            sidebarFooter
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private var sidebarBrandHeader: some View {
        HStack(spacing: 10) {
            if let appIcon = NSApp?.applicationIconImage, appIcon.size.width > 0 {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SenseiAccent.cyan.gradient)
                        .frame(width: 34, height: 34)
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 5) {
                    Text("Xmonitor")
                        .font(.system(size: 14.5, weight: .bold))
                    Text("v2.0")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SenseiAccent.cyan.primaryColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SenseiAccent.cyan.primaryColor.opacity(0.15))
                        )
                }
                Text("X-STATION V2 · S0ix Suite")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func sidebarRow(for tab: ConsoleTab, badge: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: tab.iconName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tab.accent.primaryColor)
                .frame(width: 18)

            Text(tab.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(badge.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .tag(tab)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SenseiAccent.emerald.primaryColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    engine.currentInterval <= 1.1
                        ? "1.0s 高速交互采样"
                        : String(format: "%.1fs 常驻节能采样", engine.currentInterval)
                )
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Text("S0ix 零唤醒保护已启用")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                settings.widgetsLocked.toggle()
                widgetManager.refreshVisibilityAndFrames()
            } label: {
                Image(systemName: settings.widgetsLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(
                        settings.widgetsLocked ? Color.secondary : SenseiAccent.cyan.primaryColor
                    )
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help(settings.widgetsLocked ? "解锁桌面小组件以拖拽布局" : "锁定桌面小组件（恢复点击穿透）")

            Button {
                navigation.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help("打开外观与组件设置")
        }
    }

    private var detailContainer: some View {
        ZStack {
            VisualEffectBackground(
                material: .underWindowBackground,
                blendingMode: .behindWindow,
                opacity: settings.widgetOpacity
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    navigation.selectedTab.accent.primaryColor.opacity(0.08),
                    Color.clear,
                    SenseiAccent.indigo.primaryColor.opacity(0.04)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                detailTopBar
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 12)

                Divider().opacity(0.35)

                ScrollView(.vertical, showsIndicators: true) {
                    detailBody
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                }
            }
        }
    }

    private var detailTopBar: some View {
        let tab = navigation.selectedTab
        let snap = engine.snapshot
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tab.accent.primaryColor.opacity(0.16))
                    .frame(width: 36, height: 36)
                Image(systemName: tab.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tab.accent.primaryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(tab.title)
                        .font(.system(size: 18, weight: .bold))
                    Text(tab.englishTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(tab.hardwareSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                ConsoleBadge(
                    text: "运行 \(MetricFormat.uptime(snap.uptimeSeconds))",
                    icon: "clock.fill",
                    accent: .indigo
                )

                if snap.timestamp.timeIntervalSince1970 > 0 {
                    ConsoleBadge(
                        text: Self.timeFormatter.string(from: snap.timestamp),
                        icon: "waveform.path.ecg",
                        accent: tab.accent
                    )
                }

                Button {
                    engine.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(7)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("立即采样刷新")

                GitHubCornerButton(diameter: 26, iconSize: 13.5)
            }
        }
    }

    @ViewBuilder
    private var detailBody: some View {
        switch navigation.selectedTab {
        case .overview:
            OverviewTabView(
                engine: engine,
                settings: settings,
                widgetManager: widgetManager,
                navigation: navigation
            )
        case .cpu:
            CpuDetailView(engine: engine, settings: settings)
        case .gpu:
            GpuDetailView(engine: engine, settings: settings)
        case .memory:
            MemoryDetailView(engine: engine, settings: settings)
        case .storage:
            StorageDetailView(engine: engine, settings: settings)
        case .powerS0ix:
            PowerS0ixDetailView(engine: engine, settings: settings)
        case .network:
            NetworkDetailView(engine: engine, settings: settings)
        case .processesSettings:
            ProcessesSettingsViews(
                engine: engine,
                settings: settings,
                widgetManager: widgetManager,
                navigation: navigation
            )
        }
    }
}
