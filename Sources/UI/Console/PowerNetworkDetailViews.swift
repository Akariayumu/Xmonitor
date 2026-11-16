import AppKit
import Foundation
import SwiftUI

struct PowerS0ixDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: twoColumns, spacing: 14) {
                batteryPackCard(pwr: snap.power)
                powerHistoryCard(pwr: snap.power, cpu: snap.cpu, gpu: snap.gpu)
            }

            s0ixDiagnosticsCard(pwr: snap.power)
        }
    }

    private func batteryPackCard(pwr: PowerSnapshot) -> some View {
        let stateBadge: (text: String, accent: SenseiAccent)
        if !pwr.present {
            stateBadge = ("未检测到电池 · AC 供电", .indigo)
        } else if pwr.isCharging {
            stateBadge = ("正在充电 (Charging)", .emerald)
        } else if pwr.isPluggedIn {
            stateBadge = pwr.isFullyCharged
                ? ("已充满 · 外接供电", .emerald)
                : ("外接电源已连接", .cyan)
        } else {
            stateBadge = ("电池放电供电", .amber)
        }

        let voltageV = Double(pwr.voltageMV) / 1000.0

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "智能电池与充放电电气状态",
                    subtitle: "AppleSmartBattery + SMCBatteryManager · 有符号瞬时瓦数",
                    icon: "battery.100.bolt",
                    accent: stateBadge.accent,
                    trailingBadge: stateBadge.text
                )

                HStack(spacing: 18) {
                    RingGauge(
                        progress: pwr.present ? (pwr.percentage / 100.0) : 1.0,
                        valueText: pwr.present ? ConsoleFormat.percentInt(pwr.percentage) : "AC",
                        subtitle: "当前电量",
                        accent: .emerald,
                        size: 84,
                        lineWidth: 7.5
                    )

                    RingGauge(
                        progress: min(1.0, max(0.0, pwr.healthPct / 100.0)),
                        valueText: pwr.present ? ConsoleFormat.percentInt(pwr.healthPct) : "—",
                        subtitle: "容量健康",
                        accent: .cyan,
                        size: 84,
                        lineWidth: 7.5
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        ConsoleStatRow(
                            label: "充放电净功率 (Battery W)",
                            value: ConsoleFormat.signedWatts(pwr.batteryWatts),
                            valueAccent: pwr.batteryWatts > 0.1
                                ? SenseiAccent.emerald.primaryColor
                                : (pwr.batteryWatts < -0.1 ? SenseiAccent.amber.primaryColor : nil)
                        )
                        ConsoleStatRow(
                            label: "电芯总电压 (Voltage)",
                            value: pwr.present ? String(format: "%.3f V (%d mV)", voltageV, pwr.voltageMV) : "—"
                        )
                        ConsoleStatRow(
                            label: "瞬时电流 (Amperage)",
                            value: pwr.present ? String(format: "%+d mA", pwr.amperageMA) : "—"
                        )
                        ConsoleStatRow(
                            label: "电池健康度 / 循环计数",
                            value: pwr.present ? "\(String(format: "%.1f%%", pwr.healthPct)) · \(pwr.cycleCount) 次" : "—"
                        )
                        ConsoleStatRow(
                            label: "满电标志 (FullyCharged)",
                            value: pwr.isFullyCharged ? "True (已满)" : "False"
                        )
                    }
                }
            }
        }
    }

    private func powerHistoryCard(pwr: PowerSnapshot, cpu: CpuSnapshot, gpu: GpuSnapshot) -> some View {
        let history = engine.powerHistory.values
        let stats = ConsoleFormat.seriesStats(history)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "实时功耗曲线与子系统功率分布",
                    subtitle: "RAPL Package / IA Core / GT 功耗 vs 电池端净瓦数",
                    icon: "bolt.fill",
                    accent: .amber,
                    trailingBadge: ConsoleFormat.watts2(cpu.packagePowerW)
                )

                AreaSparkline(values: history, accent: .amber, height: 78)

                HStack {
                    Text("封装均值 \(ConsoleFormat.watts2(stats.avg))")
                    Spacer()
                    Text("封装峰值 \(ConsoleFormat.watts2(stats.max))")
                    Spacer()
                    Text("电池净流 \(ConsoleFormat.signedWatts(pwr.batteryWatts))")
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)

                Divider().opacity(0.3)

                HStack(spacing: 14) {
                    ConsoleStatRow(label: "CPU 封装", value: ConsoleFormat.watts2(cpu.packagePowerW))
                    Divider().frame(height: 12)
                    ConsoleStatRow(label: "IA 核心", value: ConsoleFormat.watts2(cpu.corePowerW))
                    Divider().frame(height: 12)
                    ConsoleStatRow(label: "Iris Xe GT", value: ConsoleFormat.watts2(gpu.powerW))
                }
            }
        }
    }

    private func s0ixDiagnosticsCard(pwr: PowerSnapshot) -> some View {
        let verdict: (label: String, accent: SenseiAccent)
        if !pwr.hasS0ix {
            verdict = ("未检测到 S0ixStandby.kext", .coral)
        } else if pwr.sleepCount == 0 {
            verdict = ("S0ix v2.0 已就绪 · 等待首次睡眠", .cyan)
        } else if pwr.lastSleepType == 7 && pwr.lastDC9 {
            verdict = ("S0ix Deep Idle + 真 DC9 验证通过", .emerald)
        } else {
            verdict = ("已记录 \(pwr.sleepCount) 次睡眠 · PC8 \(pwr.lastPC8Pct)%", .amber)
        }

        let sleepTypeLabel: String
        if !pwr.hasS0ix {
            sleepTypeLabel = "—"
        } else if pwr.lastSleepType == 7 {
            sleepTypeLabel = "SleepType = 7 (Deep Idle)"
        } else if pwr.sleepCount == 0 && pwr.lastSleepType == 0 {
            sleepTypeLabel = "待睡眠 (Target = 7)"
        } else {
            sleepTypeLabel = "SleepType = \(pwr.lastSleepType)"
        }

        let dc9Label: String
        if !pwr.hasS0ix {
            dc9Label = "—"
        } else if pwr.lastDC9 {
            dc9Label = "True · 显示域已断电 (DC9)"
        } else if pwr.sleepCount == 0 {
            dc9Label = "待首次睡眠采样"
        } else {
            dc9Label = "False (未进入 DC9)"
        }

        return GlassCard(padding: 18, cornerRadius: 18, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 16) {
                ConsoleSectionHeader(
                    title: "S0ix 现代待机专属诊断面板 (X-STATION V2 Exclusive)",
                    subtitle: "IORegistry S0ixStandby 节点直读 · 验证 Tiger Lake CC7 / PC8 / DC9 与插电防误唤醒",
                    icon: "moon.stars.fill",
                    accent: verdict.accent,
                    trailingBadge: verdict.label
                )

                HStack(spacing: 22) {
                    VStack(spacing: 10) {
                        HStack(spacing: 16) {
                            RingGauge(
                                progress: Double(pwr.lastCC7Pct) / 100.0,
                                valueText: pwr.hasS0ix ? "\(pwr.lastCC7Pct)%" : "—",
                                subtitle: "CC7 驻留",
                                accent: .cyan,
                                size: 84,
                                lineWidth: 7.5
                            )

                            RingGauge(
                                progress: Double(pwr.lastPC8Pct) / 100.0,
                                valueText: pwr.hasS0ix ? "\(pwr.lastPC8Pct)%" : "—",
                                subtitle: "PC8 驻留",
                                accent: .emerald,
                                size: 84,
                                lineWidth: 7.5
                            )
                        }

                        HStack(spacing: 6) {
                            Image(systemName: pwr.lastDC9 ? "checkmark.seal.fill" : "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(
                                    pwr.lastDC9 ? SenseiAccent.emerald.primaryColor : SenseiAccent.cyan.primaryColor
                                )
                            Text(pwr.lastDC9 ? "WhateverXe 真 DC9 已确认" : "S0ix 零定时器挂起保护中")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    LazyVGrid(columns: twoColumns, spacing: 9) {
                        s0ixMetricTile(
                            icon: "bed.double.fill",
                            title: "Sleep count (累计睡眠次数)",
                            value: pwr.hasS0ix ? "\(pwr.sleepCount) 次" : "—"
                        )
                        s0ixMetricTile(
                            icon: "moon.circle.fill",
                            title: "Last sleep type (睡眠模式)",
                            value: sleepTypeLabel,
                            highlight: pwr.lastSleepType == 7 ? SenseiAccent.emerald.primaryColor : nil
                        )
                        s0ixMetricTile(
                            icon: "cpu",
                            title: "CC7% (核心 C7 深度休眠率)",
                            value: pwr.hasS0ix ? "\(pwr.lastCC7Pct)%" : "—"
                        )
                        s0ixMetricTile(
                            icon: "memorychip.fill",
                            title: "PC8% (封装 PC8 省电驻留率)",
                            value: pwr.hasS0ix ? "\(pwr.lastPC8Pct)%" : "—",
                            highlight: pwr.lastPC8Pct >= 70 ? SenseiAccent.emerald.primaryColor : nil
                        )
                        s0ixMetricTile(
                            icon: "display.trianglebadge.exclamationmark",
                            title: "DC9 (核显显示域睡眠断电)",
                            value: dc9Label,
                            highlight: pwr.lastDC9 ? SenseiAccent.emerald.primaryColor : nil
                        )
                        s0ixMetricTile(
                            icon: "bolt.horizontal.fill",
                            title: "Last wake source (上次唤醒源)",
                            value: pwr.lastWakeSource.isEmpty ? "—" : pwr.lastWakeSource
                        )
                        s0ixMetricTile(
                            icon: "powerplug.fill",
                            title: "AC EC wake block (GPE 0x6E 屏蔽)",
                            value: pwr.acEcWakeBlock.isEmpty ? "—" : pwr.acEcWakeBlock
                        )
                        s0ixMetricTile(
                            icon: "battery.100.circle.fill",
                            title: "Battery full state (满电修正)",
                            value: pwr.batteryFullState.isEmpty ? "—" : pwr.batteryFullState
                        )
                    }
                }
            }
        }
    }

    private func s0ixMetricTile(
        icon: String,
        title: String,
        value: String,
        highlight: Color? = nil
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(highlight ?? .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(value)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

struct NetworkDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    @State private var copiedIPv4 = false

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let snap = engine.snapshot
        VStack(alignment: .leading, spacing: 16) {
            wifiLinkHeroCard(wifi: snap.wifi, net: snap.network)

            LazyVGrid(columns: twoColumns, spacing: 14) {
                throughputCard(
                    title: "实时下行带宽波形 (↓ RX)",
                    subtitle: "BSD getifaddrs AF_LINK ifi_ibytes 差分速率",
                    icon: "arrow.down.circle.fill",
                    accent: .cyan,
                    rateBytesPerSec: snap.network.rxBytesPerSec,
                    history: engine.netRxHistory.values
                )
                throughputCard(
                    title: "实时上行带宽波形 (↑ TX)",
                    subtitle: "BSD getifaddrs AF_LINK ifi_obytes 差分速率",
                    icon: "arrow.up.circle.fill",
                    accent: .emerald,
                    rateBytesPerSec: snap.network.txBytesPerSec,
                    history: engine.netTxHistory.values
                )
            }

            ipAddressingCard(net: snap.network, wifi: snap.wifi)
        }
    }

    private func wifiLinkHeroCard(wifi: WifiSnapshot, net: NetworkSnapshot) -> some View {
        let ifName = !wifi.interfaceName.isEmpty
            ? wifi.interfaceName
            : (net.primaryInterface.isEmpty ? "en1" : net.primaryInterface)

        let ssidTitle: String
        if !wifi.isPresent {
            ssidTitle = "未检测到无线网卡"
        } else if !wifi.isPoweredOn {
            ssidTitle = "Wi-Fi 已关闭 (\(ifName))"
        } else if !wifi.isAssociated {
            ssidTitle = "Wi-Fi 未关联网络 (\(ifName))"
        } else if let ssid = wifi.ssid, !ssid.isEmpty {
            ssidTitle = "\(ssid) (\(ifName))"
        } else {
            ssidTitle = "Wi-Fi 6 已连接 (\(ifName))"
        }

        let hasNoiseFloor = wifi.isAssociated && wifi.noise < 0
        let rssiProgress = wifi.isAssociated
            ? min(1.0, max(0.0, Double(wifi.rssi + 90) / 60.0))
            : 0.0
        let noiseProgress = hasNoiseFloor
            ? min(1.0, max(0.0, Double(-wifi.noise - 60) / 40.0))
            : 0.0
        let snrProgress = (hasNoiseFloor && wifi.snr > 0)
            ? min(1.0, max(0.0, Double(wifi.snr) / 55.0))
            : 0.0
        let txProgress = wifi.isAssociated
            ? min(1.0, max(0.0, wifi.txRateMbps / 2402.0))
            : 0.0

        let channelDesc: String
        if wifi.isAssociated && wifi.channelNumber > 0 {
            let widthStr = wifi.channelWidthMHz > 0 ? " · \(wifi.channelWidthMHz) MHz" : ""
            channelDesc = "Ch \(wifi.channelNumber) (\(wifi.channelBand)\(widthStr))"
        } else {
            channelDesc = "—"
        }

        return GlassCard(padding: 18, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 16) {
                ConsoleSectionHeader(
                    title: ssidTitle,
                    subtitle: "Intel Wi-Fi 6 AX201 · \(wifi.phyMode) · 信道 \(channelDesc) · 加密 \(wifi.security)",
                    icon: "wifi",
                    accent: wifi.isAssociated ? .cyan : .amber,
                    trailingBadge: wifi.isAssociated ? "\(Int(wifi.txRateMbps.rounded())) Mbps" : "离线"
                )

                HStack(spacing: 16) {
                    wifiGaugeTile(
                        title: "信号强度 RSSI",
                        progress: rssiProgress,
                        valueText: wifi.isAssociated ? "\(wifi.rssi)" : "—",
                        unit: "dBm",
                        quality: rssiQualityLabel(wifi.rssi, associated: wifi.isAssociated),
                        accent: .cyan
                    )

                    wifiGaugeTile(
                        title: "环境底噪 Noise",
                        progress: noiseProgress,
                        valueText: hasNoiseFloor ? "\(wifi.noise)" : "—",
                        unit: hasNoiseFloor ? "dBm" : "N/A",
                        quality: hasNoiseFloor ? "越低越纯净" : (wifi.isAssociated ? "驱动未上报底噪" : "未连接"),
                        accent: .indigo
                    )

                    wifiGaugeTile(
                        title: "信噪比 SNR",
                        progress: snrProgress,
                        valueText: (hasNoiseFloor && wifi.snr > 0) ? "\(wifi.snr)" : "—",
                        unit: (hasNoiseFloor && wifi.snr > 0) ? "dB" : "N/A",
                        quality: hasNoiseFloor
                            ? snrQualityLabel(wifi.snr, associated: wifi.isAssociated)
                            : (wifi.isAssociated ? "参考 RSSI 强度" : "未连接"),
                        accent: .emerald
                    )

                    wifiGaugeTile(
                        title: "协商速率 TxRate",
                        progress: txProgress,
                        valueText: wifi.isAssociated ? "\(Int(wifi.txRateMbps.rounded()))" : "—",
                        unit: "Mbps",
                        quality: wifi.phyMode,
                        accent: .violet
                    )
                }
            }
        }
    }

    private func wifiGaugeTile(
        title: String,
        progress: Double,
        valueText: String,
        unit: String,
        quality: String,
        accent: SenseiAccent
    ) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            RingGauge(
                progress: progress,
                valueText: valueText,
                subtitle: unit,
                accent: accent,
                size: 82,
                lineWidth: 7.5
            )

            Text(quality)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(accent.primaryColor)
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func rssiQualityLabel(_ rssi: Int, associated: Bool) -> String {
        guard associated else { return "未连接" }
        if rssi >= -55 { return "极佳信号" }
        if rssi >= -67 { return "信号良好" }
        if rssi >= -75 { return "信号一般" }
        return "边缘弱信号"
    }

    private func snrQualityLabel(_ snr: Int, associated: Bool) -> String {
        guard associated else { return "未连接" }
        if snr >= 35 { return "高吞吐链路" }
        if snr >= 25 { return "稳定链路" }
        return "存在干扰"
    }

    private func throughputCard(
        title: String,
        subtitle: String,
        icon: String,
        accent: SenseiAccent,
        rateBytesPerSec: UInt64,
        history: [Double]
    ) -> some View {
        let stats = ConsoleFormat.seriesStats(history)
        let peakRate = UInt64(max(0.0, stats.max))
        let avgRate = UInt64(max(0.0, stats.avg))

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: title,
                    subtitle: subtitle,
                    icon: icon,
                    accent: accent,
                    trailingBadge: MetricFormat.rate(rateBytesPerSec)
                )

                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.rate(rateBytesPerSec))
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                    Spacer()
                    Text("均值 \(MetricFormat.rate(avgRate)) · 峰值 \(MetricFormat.rate(peakRate))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                AreaSparkline(values: history, accent: accent, height: 84)
            }
        }
    }

    private func ipAddressingCard(net: NetworkSnapshot, wifi: WifiSnapshot) -> some View {
        let ifName = net.primaryInterface.isEmpty
            ? (wifi.interfaceName.isEmpty ? "en1" : wifi.interfaceName)
            : net.primaryInterface

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ConsoleSectionHeader(
                        title: "网络接口路由与 IPv4 / IPv6 地址详情",
                        subtitle: "零定位授权隐私友好设计 · 自动锁定主活跃网卡",
                        icon: "network",
                        accent: .indigo
                    )

                    if !net.ipv4.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(net.ipv4, forType: .string)
                            copiedIPv4 = true
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copiedIPv4 = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: copiedIPv4 ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(copiedIPv4 ? "已复制 IPv4" : "复制 IPv4")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(copiedIPv4 ? SenseiAccent.emerald.primaryColor : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                LazyVGrid(columns: twoColumns, spacing: 10) {
                    ConsoleStatRow(label: "当前采样主接口", value: ifName)
                    ConsoleStatRow(label: "局域网 IPv4 地址", value: net.ipv4.isEmpty ? "—" : net.ipv4)
                    ConsoleStatRow(label: "IPv6 链路/全局地址", value: net.ipv6.isEmpty ? "—" : net.ipv6)
                    ConsoleStatRow(
                        label: "无线接入点 BSSID",
                        value: wifi.bssid ?? "系统隐私保护隐藏 (免定位权限)"
                    )
                }
            }
        }
    }
}
