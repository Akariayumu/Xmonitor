import AppKit
import SwiftUI

private func popoverClampUnit(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1.0, max(0.0, value))
}

struct MenuPopoverView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var widgetManager: DesktopWidgetManager
    let onOpenConsole: () -> Void
    var onOpenSettings: () -> Void = {}
    let onClosePopover: () -> Void

    private var snap: SystemSnapshot { engine.snapshot }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(spacing: 10) {
            headerSection
            coreRingsGrid
            throughputStripCard
            topProcessesCard
        }
        .padding(12)
        .frame(width: 340)
        .preferredColorScheme(SenseiPalette.colorScheme(for: settings.themeMode))
    }

    // MARK: - Header Bar

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(SenseiAccent.cyan.primaryColor)
                        .frame(width: 6.5, height: 6.5)
                    Text("Xmonitor")
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(0.3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(SenseiAccent.cyan.primaryColor.opacity(0.14), in: Capsule())

                Text("运行 \(MetricFormat.uptime(snap.uptimeSeconds))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)

                Spacer(minLength: 4)

                Menu {
                    Section("顶部菜单栏样式") {
                        ForEach(MenuBarLayoutStyle.allCases, id: \.rawValue) { style in
                            Button {
                                settings.menuBarStyle = style
                            } label: {
                                HStack {
                                    Text(style.displayTitle)
                                    if settings.menuBarStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("打开自定义偏好设置…") {
                        onClosePopover()
                        onOpenSettings()
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("快速切换菜单栏样式与打开自定义设置")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("退出 Xmonitor")
            }

            HStack(spacing: 6) {
                Button {
                    onClosePopover()
                    onOpenConsole()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("打开控制台")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5.5)
                    .background(SenseiAccent.cyan.primaryColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Menu {
                    Button(widgetManager.enabledKinds.isEmpty ? "显示桌面组件" : "隐藏全部组件") {
                        widgetManager.toggleAllWidgetsVisibility()
                    }
                    Divider()
                    ForEach(DesktopWidgetKind.allCases) { kind in
                        Button {
                            widgetManager.setWidgetEnabled(kind, enabled: !widgetManager.isWidgetEnabled(kind))
                        } label: {
                            HStack {
                                Text(kind.displayTitle)
                                if widgetManager.isWidgetEnabled(kind) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("重置组件位置") {
                        widgetManager.resetAllPositions()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: widgetManager.enabledKinds.isEmpty ? "eye.slash" : "square.grid.2x2")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("桌面组件")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5.5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("桌面组件显隐与位置重置")

                Button {
                    settings.widgetsLocked.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settings.widgetsLocked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(settings.widgetsLocked ? "锁定" : "编辑中")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(settings.widgetsLocked ? Color.primary : Color.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
                    .background(
                        settings.widgetsLocked
                            ? Color.primary.opacity(0.07)
                            : SenseiAccent.cyan.primaryColor,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .help("锁定点击穿透 / 解锁拖拽桌面组件")
            }
        }
    }

    // MARK: - 2x2 RingGauge Cards

    private var coreRingsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 10) {
            cpuPopoverCard
            gpuPopoverCard
            memoryPopoverCard
            powerPopoverCard
        }
    }

    private var cpuPopoverCard: some View {
        GlassCard(padding: 11, cornerRadius: 14, opacity: 0.90) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("处理器")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if snap.cpu.hasTemp {
                        Text(MetricFormat.optionalTemp(true, snap.cpu.packageTempC))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(snap.cpu.packageTempC >= 80 ? SenseiAccent.coral.primaryColor : .secondary)
                            .monospacedDigit()
                    } else {
                        Text(String(format: "%.1fW", snap.cpu.packagePowerW))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 8) {
                    RingGauge(
                        progress: popoverClampUnit(snap.cpu.totalUsage / 100.0),
                        valueText: String(format: "%.0f%%", snap.cpu.totalUsage),
                        subtitle: MetricFormat.menuGHz(snap.cpu.maxFreqMHz).trimmingCharacters(in: .whitespaces),
                        accent: .cyan,
                        size: 58,
                        lineWidth: 6.0
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("峰值 \(MetricFormat.menuGHz(snap.cpu.maxFreqMHz).trimmingCharacters(in: .whitespaces))")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                        Text(String(format: "功耗 %.1fW", snap.cpu.packagePowerW))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("省电 \(Int(snap.cpu.pkgCStatePct.rounded()))%")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gpuPopoverCard: some View {
        GlassCard(padding: 11, cornerRadius: 14, opacity: 0.90) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Iris Xe")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(String(format: "%.1fW", snap.gpu.powerW))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    RingGauge(
                        progress: popoverClampUnit(snap.gpu.usagePct / 100.0),
                        valueText: String(format: "%.0f%%", snap.gpu.usagePct),
                        subtitle: "GT",
                        accent: .indigo,
                        size: 58,
                        lineWidth: 6.0
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        if snap.gpu.hasFreq {
                            Text(
                                MetricFormat.optionalMHz(
                                    true,
                                    snap.gpu.currentFreqMHz,
                                    isRC6: snap.gpu.usagePct < 0.5
                                )
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                        } else {
                            Text("RC6 \(Int(snap.gpu.rc6Pct.rounded()))%")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                        }
                        Text("GART \(MetricFormat.bytes(snap.gpu.gartUsedBytes))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(String(format: "功耗 %.1fW", snap.gpu.powerW))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memoryPopoverCard: some View {
        let pressureLabel: String
        let pressureAccent: SenseiAccent
        switch snap.memory.pressureLevel {
        case 4:
            pressureLabel = "紧张"
            pressureAccent = .coral
        case 2:
            pressureLabel = "警告"
            pressureAccent = .amber
        default:
            pressureLabel = "正常"
            pressureAccent = .emerald
        }

        return GlassCard(padding: 11, cornerRadius: 14, opacity: 0.90) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("内存")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(pressureLabel)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(pressureAccent.primaryColor)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(pressureAccent.primaryColor.opacity(0.14), in: Capsule())
                }

                HStack(spacing: 8) {
                    RingGauge(
                        progress: popoverClampUnit(snap.memory.usedPercent / 100.0),
                        valueText: String(format: "%.0f%%", snap.memory.usedPercent),
                        subtitle: "RAM",
                        accent: .emerald,
                        size: 58,
                        lineWidth: 6.0
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(MetricFormat.bytes(snap.memory.usedBytes))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                        Text("共 \(snap.memory.totalBytes > 0 ? MetricFormat.bytes(snap.memory.totalBytes) : "16.0 GB")")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("压缩 \(MetricFormat.bytes(snap.memory.compressedBytes))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var powerPopoverCard: some View {
        let accent: SenseiAccent = snap.power.isCharging
            ? .emerald
            : (snap.power.present && snap.power.percentage <= 20 ? .coral : .amber)

        let wattsLabel: String
        if snap.power.present && abs(snap.power.batteryWatts) >= 0.05 {
            wattsLabel = String(format: "%+.1fW", snap.power.batteryWatts)
        } else if snap.power.isPluggedIn {
            wattsLabel = "AC 供电"
        } else {
            wattsLabel = String(format: "%.1fW", snap.cpu.packagePowerW)
        }

        return GlassCard(padding: 11, cornerRadius: 14, opacity: 0.90) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("电源 · S0ix")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: snap.power.isPluggedIn ? "bolt.fill" : "battery.100")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent.primaryColor)
                }

                HStack(spacing: 8) {
                    RingGauge(
                        progress: popoverClampUnit(snap.power.percentage / 100.0),
                        valueText: snap.power.present ? String(format: "%.0f%%", snap.power.percentage) : "AC",
                        subtitle: snap.power.isCharging ? "充电" : "电量",
                        accent: accent,
                        size: 58,
                        lineWidth: 6.0
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(wattsLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                        if snap.power.hasS0ix {
                            Text("PC8 \(snap.power.lastPC8Pct)%")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(snap.power.lastDC9 ? "DC9 已达标" : "睡眠 #\(snap.power.sleepCount)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("健康 \(Int(snap.power.healthPct.rounded()))%")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Network & NVMe Throughput Strip

    private var throughputStripCard: some View {
        GlassCard(padding: 10, cornerRadius: 14, opacity: 0.90) {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: snap.wifi.isAssociated ? "wifi" : "network")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.cyan.primaryColor)
                        .frame(width: 14)

                    Text(networkSummaryLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    Text("↓ \(MetricFormat.rate(snap.network.rxBytesPerSec))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.cyan.primaryColor)
                        .monospacedDigit()

                    Text("↑ \(MetricFormat.rate(snap.network.txBytesPerSec))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.emerald.primaryColor)
                        .monospacedDigit()
                }

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.indigo.primaryColor)
                        .frame(width: 14)

                    Text(snap.storage.hasSmart ? "NVMe · \(snap.storage.tempC)°C" : "NVMe 读写")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)

                    Spacer()

                    Text("读 \(MetricFormat.rate(snap.storage.readBytesPerSec))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.cyan.primaryColor)
                        .monospacedDigit()

                    Text("写 \(MetricFormat.rate(snap.storage.writeBytesPerSec))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SenseiAccent.indigo.primaryColor)
                        .monospacedDigit()
                }
            }
        }
    }

    private var networkSummaryLabel: String {
        let iface = snap.network.primaryInterface.isEmpty ? "en1" : snap.network.primaryInterface
        if snap.wifi.isAssociated {
            if let ssid = snap.wifi.ssid, !ssid.isEmpty {
                return "\(ssid) (\(iface))"
            }
            let isWifi6 = snap.wifi.phyMode == "802.11ax"
                || snap.wifi.channelWidthMHz >= 160
                || snap.wifi.txRateMbps >= 1000
            return "\(isWifi6 ? "Wi-Fi 6" : "Wi-Fi") (\(iface))"
        }
        return "网络 (\(iface))"
    }

    // MARK: - Top-3 CPU Processes Strip

    private var topProcessesCard: some View {
        let topThree = Array(snap.topProcesses.prefix(3))
        let scopeTitle = snap.isAllUsersProcessList ? "全系统" : "当前用户"

        return GlassCard(padding: 10, cornerRadius: 14, opacity: 0.90) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("活跃进程 Top 3")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Text(scopeTitle)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(
                            snap.isAllUsersProcessList
                                ? SenseiAccent.cyan.primaryColor
                                : SenseiAccent.amber.primaryColor
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            (snap.isAllUsersProcessList
                                ? SenseiAccent.cyan.primaryColor
                                : SenseiAccent.amber.primaryColor
                            ).opacity(0.14),
                            in: Capsule()
                        )
                }

                if topThree.isEmpty {
                    Text("正在采样进程 CPU 排行…")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(topThree) { proc in
                        HStack(spacing: 8) {
                            Text(proc.name.isEmpty ? "PID \(proc.pid)" : proc.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            Text(MetricFormat.bytes(proc.memoryBytes))
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()

                            Text(String(format: "%5.1f%%", proc.cpuPct))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(
                                    proc.cpuPct >= 50
                                        ? SenseiAccent.amber.primaryColor
                                        : SenseiAccent.cyan.primaryColor
                                )
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
