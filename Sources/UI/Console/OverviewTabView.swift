import Foundation
import SwiftUI

private struct InteractiveCardButton<Content: View>: View {
    let accent: SenseiAccent
    let action: () -> Void
    private let content: Content

    @State private var isHovering = false

    init(
        accent: SenseiAccent,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.accent = accent
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isHovering ? accent.primaryColor.opacity(0.55) : Color.clear,
                            lineWidth: 1.3
                        )
                )
                .scaleEffect(isHovering ? 1.006 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

struct OverviewTabView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var widgetManager: DesktopWidgetManager
    @ObservedObject var navigation: ConsoleNavigationModel

    private let gridColumns = [
        GridItem(.flexible(minimum: 320), spacing: 14),
        GridItem(.flexible(minimum: 320), spacing: 14)
    ]

    var body: some View {
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 16) {
            heroBanner(snap: snap)

            LazyVGrid(columns: gridColumns, spacing: 14) {
                cpuSummaryCard(cpu: snap.cpu)
                gpuSummaryCard(gpu: snap.gpu)
                memorySummaryCard(mem: snap.memory)
                storageSummaryCard(sto: snap.storage)
                powerSummaryCard(pwr: snap.power, cpu: snap.cpu)
                networkSummaryCard(net: snap.network, wifi: snap.wifi)
            }

            topProcessesStrip(snap: snap)
        }
    }

    private func heroBanner(snap: SystemSnapshot) -> some View {
        let display = ConsoleFormat.activeDisplaySummary()
        return GlassCard(padding: 18, cornerRadius: 18, opacity: settings.widgetOpacity) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    SenseiAccent.cyan.primaryColor.opacity(0.24),
                                    SenseiAccent.indigo.primaryColor.opacity(0.22)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 64, height: 64)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(SenseiAccent.cyan.primaryColor.opacity(0.35), lineWidth: 1)
                        )

                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(SenseiAccent.cyan.gradient)
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("X-STATION V2")
                            .font(.system(size: 19, weight: .bold))
                        ConsoleBadge(
                            text: (snap.cpu.hasTemp && snap.gpu.hasFreq)
                                ? "EFI v2.0.1 · Sensors & S0ix"
                                : (snap.power.hasS0ix ? "EFI v2.0 · S0ix Active" : "EFI v2.0 Ready"),
                            icon: "moon.stars.fill",
                            accent: .emerald
                        )
                        ConsoleBadge(
                            text: "\(display.panelSpec) · \(display.activeMode)",
                            icon: "sparkles.tv",
                            accent: .indigo
                        )
                    }

                    Text("X-STATION V2 · i7-1165G7 · Iris Xe 96EU · 16GB LPDDR4X · 1TB NVMe")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 14) {
                        heroMiniChip(
                            icon: "cpu",
                            label: "峰值频率",
                            value: ConsoleFormat.ghz(snap.cpu.maxFreqMHz)
                        )
                        heroMiniChip(
                            icon: "bolt.fill",
                            label: "封装功耗",
                            value: ConsoleFormat.watts2(snap.cpu.packagePowerW)
                        )
                        heroMiniChip(
                            icon: "wifi",
                            label: snap.wifi.interfaceName.isEmpty ? "Wi-Fi 6 (en1)" : "Wi-Fi 6 (\(snap.wifi.interfaceName))",
                            value: snap.wifi.isAssociated ? "\(Int(snap.wifi.txRateMbps.rounded())) Mbps" : "未连接"
                        )
                        heroMiniChip(
                            icon: "bed.double.fill",
                            label: "S0ix 驻留",
                            value: snap.power.hasS0ix ? "PC8 \(snap.power.lastPC8Pct)% · CC7 \(snap.power.lastCC7Pct)%" : "—"
                        )
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        settings.widgetsLocked.toggle()
                        widgetManager.refreshVisibilityAndFrames()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: settings.widgetsLocked ? "lock.open" : "checkmark.shield.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(settings.widgetsLocked ? "编辑桌面组件" : "完成组件锁定")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(settings.widgetsLocked ? Color.primary : SenseiAccent.cyan.primaryColor)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    settings.widgetsLocked
                                        ? Color.primary.opacity(0.08)
                                        : SenseiAccent.cyan.primaryColor.opacity(0.18)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    Text("已启用 \(widgetManager.enabledKinds.count)/4 款桌面卡片")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func heroMiniChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func cardHeader(
        title: String,
        subtitle: String,
        icon: String,
        accent: SenseiAccent
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.primaryColor)
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.tertiary)
        }
    }

    private func cpuSummaryCard(cpu: CpuSnapshot) -> some View {
        InteractiveCardButton(accent: .cyan, action: { navigation.select(.cpu) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "处理器 CPU",
                        subtitle: "Core i7-1165G7 · 8 Threads",
                        icon: "cpu.fill",
                        accent: .cyan
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: cpu.totalUsage / 100.0,
                            valueText: ConsoleFormat.percentInt(cpu.totalUsage),
                            subtitle: MetricFormat.menuGHz(cpu.maxFreqMHz),
                            accent: .cyan,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(label: "峰值 / 均值频率", value: "\(ConsoleFormat.ghz(cpu.maxFreqMHz)) / \(ConsoleFormat.ghz(cpu.avgFreqMHz))")
                            ConsoleStatRow(label: "封装 / 核心功耗", value: "\(ConsoleFormat.watts2(cpu.packagePowerW)) / \(ConsoleFormat.watts2(cpu.corePowerW))")
                            ConsoleStatRow(label: "Pkg C-State 省电", value: ConsoleFormat.percent1(cpu.pkgCStatePct))
                            ConsoleStatRow(label: "封装温度", value: MetricFormat.optionalTemp(cpu.hasTemp, cpu.packageTempC))
                        }
                    }

                    AreaSparkline(
                        values: engine.cpuHistory.values,
                        maxValue: 100,
                        accent: .cyan,
                        height: 40
                    )
                }
            }
        }
    }

    private func gpuSummaryCard(gpu: GpuSnapshot) -> some View {
        let isRC6 = gpu.usagePct < 0.5
        return InteractiveCardButton(accent: .indigo, action: { navigation.select(.gpu) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "核显 Iris Xe",
                        subtitle: "96 EU · GT2 8086:9A49",
                        icon: "display",
                        accent: .indigo
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: gpu.usagePct / 100.0,
                            valueText: ConsoleFormat.percentInt(gpu.usagePct),
                            subtitle: ConsoleFormat.watts2(gpu.powerW),
                            accent: .indigo,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(
                                label: "核显实时频率",
                                value: MetricFormat.optionalMHz(gpu.hasFreq, gpu.currentFreqMHz, isRC6: isRC6)
                            )
                            ConsoleStatRow(label: "RC6 深度休眠率", value: ConsoleFormat.percent1(gpu.rc6Pct))
                            ConsoleStatRow(
                                label: "GART 动态显存",
                                value: "\(MetricFormat.bytes(gpu.gartUsedBytes)) / \(MetricFormat.bytes(gpu.gartSizeBytes))"
                            )
                            ConsoleStatRow(
                                label: "TGLSinkRestore",
                                value: "OK \(gpu.sinkRestoreOk) · 重试 \(gpu.sinkRestoreRetries)"
                            )
                        }
                    }

                    AreaSparkline(
                        values: engine.gpuHistory.values,
                        maxValue: 100,
                        accent: .indigo,
                        height: 40
                    )
                }
            }
        }
    }

    private func memorySummaryCard(mem: MemorySnapshot) -> some View {
        let pInfo = ConsoleFormat.pressureInfo(mem.pressureLevel)
        return InteractiveCardButton(accent: .emerald, action: { navigation.select(.memory) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "物理内存 Memory",
                        subtitle: "16 GB LPDDR4X-4267",
                        icon: "memorychip.fill",
                        accent: .emerald
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: mem.usedPercent / 100.0,
                            valueText: ConsoleFormat.percentInt(mem.usedPercent),
                            subtitle: MetricFormat.bytes(mem.usedBytes),
                            accent: .emerald,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(
                                label: "已用 / 总容量",
                                value: "\(MetricFormat.bytes(mem.usedBytes)) / \(MetricFormat.bytes(mem.totalBytes))"
                            )
                            ConsoleStatRow(
                                label: "应用 / 联动内存",
                                value: "\(MetricFormat.bytes(mem.appBytes)) / \(MetricFormat.bytes(mem.wiredBytes))"
                            )
                            ConsoleStatRow(
                                label: "压缩 / 交换区",
                                value: "\(MetricFormat.bytes(mem.compressedBytes)) / \(MetricFormat.bytes(mem.swapUsedBytes))"
                            )
                            ConsoleStatRow(
                                label: "XNU 内存压力",
                                value: pInfo.label,
                                valueAccent: pInfo.accent.primaryColor
                            )
                        }
                    }

                    AreaSparkline(
                        values: engine.ramHistory.values,
                        maxValue: 100,
                        accent: .emerald,
                        height: 40
                    )
                }
            }
        }
    }

    private func storageSummaryCard(sto: StorageSnapshot) -> some View {
        let readSeries = engine.diskReadHistory.values
        let writeSeries = engine.diskWriteHistory.values
        let combinedThroughput = zip(readSeries, writeSeries).map { $0 + $1 }
        let modelLabel = sto.model.isEmpty ? "Kingston 1TB NVMe" : sto.model

        return InteractiveCardButton(accent: .amber, action: { navigation.select(.storage) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "存储 NVMe SSD",
                        subtitle: modelLabel,
                        icon: "internaldrive.fill",
                        accent: .amber
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: sto.usedPercent / 100.0,
                            valueText: ConsoleFormat.percentInt(sto.usedPercent),
                            subtitle: sto.hasSmart ? "\(sto.tempC)°C" : "APFS",
                            accent: .amber,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(
                                label: "可用 / 总空间",
                                value: "\(MetricFormat.bytes(sto.availableBytes)) / \(MetricFormat.bytes(sto.totalBytes))"
                            )
                            ConsoleStatRow(
                                label: "实时读取 / 写入",
                                value: "\(MetricFormat.rate(sto.readBytesPerSec)) / \(MetricFormat.rate(sto.writeBytesPerSec))"
                            )
                            ConsoleStatRow(
                                label: "IOPS (读 / 写)",
                                value: "\(Int(sto.readIOPS.rounded())) / \(Int(sto.writeIOPS.rounded()))"
                            )
                            ConsoleStatRow(
                                label: "SMART 寿命健康度",
                                value: sto.hasSmart ? "\(max(0, 100 - sto.lifeUsedPct))% · \(sto.tempC)°C" : "—"
                            )
                        }
                    }

                    AreaSparkline(
                        values: combinedThroughput,
                        accent: .amber,
                        height: 40
                    )
                }
            }
        }
    }

    private func powerSummaryCard(pwr: PowerSnapshot, cpu: CpuSnapshot) -> some View {
        let stateText: String
        if !pwr.present {
            stateText = "外接电源 AC"
        } else if pwr.isCharging {
            stateText = "正在充电"
        } else if pwr.isPluggedIn {
            stateText = pwr.isFullyCharged ? "满电保护 (AC)" : "外接供电"
        } else {
            stateText = "电池放电中"
        }

        return InteractiveCardButton(accent: .emerald, action: { navigation.select(.powerS0ix) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "电源与 S0ix 待机",
                        subtitle: stateText,
                        icon: "bolt.batteryblock.fill",
                        accent: .emerald
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: pwr.present ? (pwr.percentage / 100.0) : 1.0,
                            valueText: pwr.present ? ConsoleFormat.percentInt(pwr.percentage) : "AC",
                            subtitle: ConsoleFormat.signedWatts(pwr.batteryWatts),
                            accent: .emerald,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(
                                label: "充放电 / 封装瓦数",
                                value: "\(ConsoleFormat.signedWatts(pwr.batteryWatts)) / \(ConsoleFormat.watts2(cpu.packagePowerW))"
                            )
                            ConsoleStatRow(
                                label: "电池健康 / 循环",
                                value: pwr.present ? "\(String(format: "%.1f%%", pwr.healthPct)) · \(pwr.cycleCount)次" : "—"
                            )
                            ConsoleStatRow(
                                label: "S0ix CC7 / PC8",
                                value: pwr.hasS0ix ? "\(pwr.lastCC7Pct)% / \(pwr.lastPC8Pct)%" : "—"
                            )
                            ConsoleStatRow(
                                label: "DC9 / 睡眠计数",
                                value: pwr.hasS0ix ? "\(pwr.lastDC9 ? "DC9 真断电" : "未触发") · \(pwr.sleepCount)次" : "—"
                            )
                        }
                    }

                    AreaSparkline(
                        values: engine.powerHistory.values,
                        accent: .amber,
                        height: 40
                    )
                }
            }
        }
    }

    private func networkSummaryCard(net: NetworkSnapshot, wifi: WifiSnapshot) -> some View {
        let ifName = !wifi.interfaceName.isEmpty
            ? wifi.interfaceName
            : (net.primaryInterface.isEmpty ? "en1" : net.primaryInterface)
        let signalProgress: Double = wifi.isAssociated
            ? min(1.0, max(0.0, Double(wifi.rssi + 90) / 60.0))
            : 0.0

        return InteractiveCardButton(accent: .cyan, action: { navigation.select(.network) }) {
            GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
                VStack(alignment: .leading, spacing: 12) {
                    cardHeader(
                        title: "无线网络 Wi-Fi 6",
                        subtitle: "Intel AX201 (\(ifName))",
                        icon: "wifi",
                        accent: .cyan
                    )

                    HStack(spacing: 14) {
                        RingGauge(
                            progress: signalProgress,
                            valueText: wifi.isAssociated ? "\(wifi.rssi)" : "—",
                            subtitle: wifi.isAssociated ? "dBm" : "离线",
                            accent: .cyan,
                            size: 74,
                            lineWidth: 7
                        )

                        VStack(alignment: .leading, spacing: 5) {
                            ConsoleStatRow(
                                label: "协商速率 / 协议",
                                value: wifi.isAssociated ? "\(Int(wifi.txRateMbps.rounded())) Mbps · \(wifi.phyMode)" : "未关联"
                            )
                            ConsoleStatRow(
                                label: "实时下行 ↓ RX",
                                value: MetricFormat.rate(net.rxBytesPerSec)
                            )
                            ConsoleStatRow(
                                label: "实时上行 ↑ TX",
                                value: MetricFormat.rate(net.txBytesPerSec)
                            )
                            ConsoleStatRow(
                                label: "局域网 IPv4",
                                value: net.ipv4.isEmpty ? "—" : net.ipv4
                            )
                        }
                    }

                    AreaSparkline(
                        values: engine.netRxHistory.values,
                        accent: .cyan,
                        height: 40
                    )
                }
            }
        }
    }

    private func topProcessesStrip(snap: SystemSnapshot) -> some View {
        let topFive = Array(snap.topProcesses.prefix(5))
        return GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ConsoleSectionHeader(
                        title: "活跃进程快照 (Top 5 CPU)",
                        subtitle: snap.isAllUsersProcessList ? "全系统进程视图 (libsysmon)" : "当前用户进程视图 (libproc)",
                        icon: "waveform.badge.magnifyingglass",
                        accent: .violet
                    )

                    Button {
                        navigation.openProcesses()
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看全部 Top 30")
                                .font(.system(size: 11.5, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                        .foregroundStyle(SenseiAccent.violet.primaryColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(SenseiAccent.violet.primaryColor.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if topFive.isEmpty {
                    Text("正在采样实时进程负载…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    HStack(spacing: 10) {
                        ForEach(topFive) { proc in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(proc.name)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(String(format: "%.1f%%", proc.cpuPct))
                                        .font(.system(size: 11, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(SenseiAccent.cyan.primaryColor)
                                }
                                Text("PID \(proc.pid) · \(MetricFormat.bytes(proc.memoryBytes))")
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                ConsoleLinearBar(
                                    fraction: min(1.0, proc.cpuPct / 100.0),
                                    accent: proc.cpuPct > 50 ? .coral : .cyan,
                                    height: 4
                                )
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
    }
}
