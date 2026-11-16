import Foundation
import SwiftUI

private struct MemoryBreakdownDonut: View {
    let totalBytes: UInt64
    let appBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let usedPercent: Double
    let usedBytes: UInt64

    var body: some View {
        let denom = Double(max(1, totalBytes))
        let fApp = min(1.0, Double(appBytes) / denom)
        let fWired = min(max(0.0, 1.0 - fApp), Double(wiredBytes) / denom)
        let fComp = min(max(0.0, 1.0 - fApp - fWired), Double(compressedBytes) / denom)
        let fCached = min(max(0.0, 1.0 - fApp - fWired - fComp), Double(cachedBytes) / denom)

        let s0 = 0.0
        let e0 = s0 + fApp
        let e1 = e0 + fWired
        let e2 = e1 + fComp
        let e3 = e2 + fCached

        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: 14)

            if fCached > 0.002 {
                Circle()
                    .trim(from: e2, to: e3)
                    .stroke(SenseiAccent.violet.primaryColor.opacity(0.55), style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            if fComp > 0.002 {
                Circle()
                    .trim(from: e1, to: e2)
                    .stroke(SenseiAccent.amber.primaryColor, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            if fWired > 0.002 {
                Circle()
                    .trim(from: e0, to: e1)
                    .stroke(SenseiAccent.indigo.primaryColor, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            if fApp > 0.002 {
                Circle()
                    .trim(from: s0, to: e0)
                    .stroke(SenseiAccent.cyan.primaryColor, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 2) {
                Text(ConsoleFormat.percentInt(usedPercent))
                    .font(.system(size: 22, weight: .bold))
                    .monospacedDigit()
                Text(MetricFormat.bytes(usedBytes))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("已用物理内存")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 136, height: 136)
    }
}

struct MemoryDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let mem = engine.snapshot.memory
        VStack(alignment: .leading, spacing: 16) {
            memoryBreakdownCard(mem: mem)

            LazyVGrid(columns: twoColumns, spacing: 14) {
                pressureAndHistoryCard(mem: mem)
                swapDetailCard(mem: mem)
            }
        }
    }

    private func memoryBreakdownCard(mem: MemorySnapshot) -> some View {
        let total = max(1, mem.totalBytes)
        return GlassCard(padding: 18, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 16) {
                ConsoleSectionHeader(
                    title: "LPDDR4X-4267 内存构成环形拆解",
                    subtitle: "对齐 macOS 活动监视器口径：已用 = 应用内存 + 联动内存 + 压缩器占用",
                    icon: "memorychip.fill",
                    accent: .emerald,
                    trailingBadge: "\(MetricFormat.bytes(mem.usedBytes)) / \(MetricFormat.bytes(mem.totalBytes))"
                )

                HStack(alignment: .center, spacing: 26) {
                    MemoryBreakdownDonut(
                        totalBytes: mem.totalBytes,
                        appBytes: mem.appBytes,
                        wiredBytes: mem.wiredBytes,
                        compressedBytes: mem.compressedBytes,
                        cachedBytes: mem.cachedBytes,
                        usedPercent: mem.usedPercent,
                        usedBytes: mem.usedBytes
                    )
                    .padding(.leading, 6)

                    LazyVGrid(columns: twoColumns, spacing: 10) {
                        segmentTile(
                            title: "应用内存 (App Memory)",
                            subtitle: "匿名页 (internal - purgeable)",
                            bytes: mem.appBytes,
                            total: total,
                            accent: .cyan
                        )
                        segmentTile(
                            title: "联动内存 (Wired Kernel)",
                            subtitle: "内核与驱动锁定不可换出页",
                            bytes: mem.wiredBytes,
                            total: total,
                            accent: .indigo
                        )
                        segmentTile(
                            title: "已压缩 (VM Compressor)",
                            subtitle: "WKdm 内存压缩器驻留页",
                            bytes: mem.compressedBytes,
                            total: total,
                            accent: .amber
                        )
                        segmentTile(
                            title: "已缓存文件 (Cached Files)",
                            subtitle: "Unified Buffer Cache 可随时回收",
                            bytes: mem.cachedBytes,
                            total: total,
                            accent: .violet
                        )
                    }
                }

                Divider().opacity(0.3)

                HStack(spacing: 18) {
                    ConsoleStatRow(label: "物理总容量 (hw.memsize)", value: MetricFormat.bytes(mem.totalBytes))
                    Divider().frame(height: 14)
                    ConsoleStatRow(label: "活跃已用容量", value: MetricFormat.bytes(mem.usedBytes))
                    Divider().frame(height: 14)
                    ConsoleStatRow(
                        label: "立即可用空间 (Available)",
                        value: MetricFormat.bytes(mem.availableBytes),
                        valueAccent: SenseiAccent.emerald.primaryColor
                    )
                }
            }
        }
    }

    private func segmentTile(
        title: String,
        subtitle: String,
        bytes: UInt64,
        total: UInt64,
        accent: SenseiAccent
    ) -> some View {
        let pct = (Double(bytes) / Double(max(1, total))) * 100.0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent.primaryColor)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(ConsoleFormat.percent1(pct))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(MetricFormat.bytes(bytes))
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()

            ConsoleLinearBar(fraction: pct / 100.0, accent: accent, height: 5)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func pressureAndHistoryCard(mem: MemorySnapshot) -> some View {
        let pInfo = ConsoleFormat.pressureInfo(mem.pressureLevel)
        let history = engine.ramHistory.values
        let stats = ConsoleFormat.seriesStats(history)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "内存压力等级与 60 点曲线",
                    subtitle: "kern.memorystatus_vm_pressure_level",
                    icon: "gauge.with.needle.fill",
                    accent: pInfo.accent,
                    trailingBadge: pInfo.label
                )

                HStack(spacing: 10) {
                    Circle()
                        .fill(pInfo.accent.primaryColor)
                        .frame(width: 10, height: 10)
                    Text(pInfo.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(pInfo.accent.primaryColor.opacity(0.10))
                )

                AreaSparkline(values: history, maxValue: 100, accent: .emerald, height: 84)

                HStack {
                    Text("最低 \(ConsoleFormat.percent1(stats.min))")
                    Spacer()
                    Text("均值 \(ConsoleFormat.percent1(stats.avg))")
                    Spacer()
                    Text("峰值 \(ConsoleFormat.percent1(stats.max))")
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func swapDetailCard(mem: MemorySnapshot) -> some View {
        let swapPct: Double = mem.swapTotalBytes > 0
            ? (Double(mem.swapUsedBytes) / Double(mem.swapTotalBytes)) * 100.0
            : 0.0
        let swapFree = mem.swapTotalBytes > mem.swapUsedBytes
            ? (mem.swapTotalBytes - mem.swapUsedBytes)
            : 0

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "虚拟内存交换区 (VM Swap)",
                    subtitle: "sysctl vm.swapusage 动态加密交换文件",
                    icon: "arrow.left.arrow.right.circle.fill",
                    accent: mem.swapUsedBytes == 0 ? .emerald : .amber,
                    trailingBadge: mem.swapUsedBytes == 0 ? "零交换写入" : ConsoleFormat.percent1(swapPct)
                )

                HStack(spacing: 18) {
                    RingGauge(
                        progress: swapPct / 100.0,
                        valueText: mem.swapTotalBytes > 0 ? ConsoleFormat.percentInt(swapPct) : "0%",
                        subtitle: "Swap",
                        accent: mem.swapUsedBytes == 0 ? .emerald : .amber,
                        size: 84,
                        lineWidth: 7.5
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        ConsoleStatRow(label: "已使用 Swap 容量", value: MetricFormat.bytes(mem.swapUsedBytes))
                        ConsoleStatRow(label: "当前已分配 Swap 总池", value: MetricFormat.bytes(mem.swapTotalBytes))
                        ConsoleStatRow(label: "剩余已分配 Swap 空间", value: MetricFormat.bytes(swapFree))
                        ConsoleStatRow(
                            label: "NVMe 交换磨损保护",
                            value: mem.swapUsedBytes == 0 ? "理想 (全驻留 RAM)" : "活跃交换中",
                            valueAccent: mem.swapUsedBytes == 0
                                ? SenseiAccent.emerald.primaryColor
                                : SenseiAccent.amber.primaryColor
                        )
                    }
                }

                Spacer(minLength: 0)

                ConsoleLinearBar(
                    fraction: swapPct / 100.0,
                    accent: mem.swapUsedBytes == 0 ? .emerald : .amber,
                    height: 7
                )
            }
        }
    }
}

struct StorageDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let sto = engine.snapshot.storage
        VStack(alignment: .leading, spacing: 16) {
            apfsCapacityCard(sto: sto)

            LazyVGrid(columns: twoColumns, spacing: 14) {
                ioChartCard(
                    title: "NVMe 实时读取吞吐与 IOPS",
                    subtitle: "IOBlockStorageDriver Bytes / Operations (Read)",
                    icon: "arrow.down.circle.fill",
                    accent: .cyan,
                    bytesPerSec: sto.readBytesPerSec,
                    iops: sto.readIOPS,
                    history: engine.diskReadHistory.values
                )
                ioChartCard(
                    title: "NVMe 实时写入吞吐与 IOPS",
                    subtitle: "IOBlockStorageDriver Bytes / Operations (Write)",
                    icon: "arrow.up.circle.fill",
                    accent: .amber,
                    bytesPerSec: sto.writeBytesPerSec,
                    iops: sto.writeIOPS,
                    history: engine.diskWriteHistory.values
                )
            }

            nvmeSmartCard(sto: sto)
        }
    }

    private func apfsCapacityCard(sto: StorageSnapshot) -> some View {
        let modelTitle = sto.model.isEmpty ? "Kingston NVMe PCIe SSD (1 TB)" : sto.model
        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "APFS 根卷容量与空间分布 (/)",
                    subtitle: "\(modelTitle) · 对齐 macOS 访达重要可用容量口径",
                    icon: "internaldrive.fill",
                    accent: .amber,
                    trailingBadge: "已用 \(ConsoleFormat.percent1(sto.usedPercent))"
                )

                HStack(spacing: 20) {
                    RingGauge(
                        progress: sto.usedPercent / 100.0,
                        valueText: ConsoleFormat.percentInt(sto.usedPercent),
                        subtitle: "APFS",
                        accent: .amber,
                        size: 82,
                        lineWidth: 7.5
                    )

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("剩余可用 \(MetricFormat.bytes(sto.availableBytes))")
                                .font(.system(size: 20, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(SenseiAccent.emerald.primaryColor)
                            Text("共 \(MetricFormat.bytes(sto.totalBytes))（已使用 \(MetricFormat.bytes(sto.usedBytes))）")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        ConsoleLinearBar(fraction: sto.usedPercent / 100.0, accent: .amber, height: 10)

                        HStack(spacing: 20) {
                            ConsoleStatRow(label: "已占用空间", value: MetricFormat.bytes(sto.usedBytes))
                            Divider().frame(height: 13)
                            ConsoleStatRow(label: "可清理后可用空间", value: MetricFormat.bytes(sto.availableBytes))
                            Divider().frame(height: 13)
                            ConsoleStatRow(label: "物理卷总容量", value: MetricFormat.bytes(sto.totalBytes))
                        }
                    }
                }
            }
        }
    }

    private func ioChartCard(
        title: String,
        subtitle: String,
        icon: String,
        accent: SenseiAccent,
        bytesPerSec: UInt64,
        iops: Double,
        history: [Double]
    ) -> some View {
        let stats = ConsoleFormat.seriesStats(history)
        let peakRate = UInt64(max(0.0, stats.max))

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: title,
                    subtitle: subtitle,
                    icon: icon,
                    accent: accent,
                    trailingBadge: "\(Int(iops.rounded())) IOPS"
                )

                HStack(alignment: .firstTextBaseline) {
                    Text(MetricFormat.rate(bytesPerSec))
                        .font(.system(size: 22, weight: .bold))
                        .monospacedDigit()
                    Spacer()
                    Text("60点峰值 \(MetricFormat.rate(peakRate))")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                AreaSparkline(values: history, accent: accent, height: 76)
            }
        }
    }

    private func nvmeSmartCard(sto: StorageSnapshot) -> some View {
        let remainingHealth = max(0, min(100, 100 - Int(sto.lifeUsedPct)))
        let modelName = sto.model.isEmpty ? "Kingston NVMe SSD" : sto.model
        let tempAccent: SenseiAccent = sto.tempC >= 65 ? .coral : (sto.tempC >= 52 ? .amber : .emerald)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "NVMe SMART 完整性健康诊断表",
                    subtitle: "IONVMeController NVMeSMARTLib.plugin · Log Page 0x02 (每 30s 免唤醒轮询)",
                    icon: "stethoscope",
                    accent: sto.hasSmart ? .emerald : .indigo,
                    trailingBadge: sto.hasSmart ? "健康度 \(remainingHealth)%" : "采集中"
                )

                if sto.hasSmart {
                    HStack(spacing: 22) {
                        RingGauge(
                            progress: Double(remainingHealth) / 100.0,
                            valueText: "\(remainingHealth)%",
                            subtitle: "剩余寿命",
                            accent: remainingHealth >= 85 ? .emerald : .amber,
                            size: 84,
                            lineWidth: 7.5
                        )

                        RingGauge(
                            progress: min(1.0, max(0.0, Double(sto.tempC) / 85.0)),
                            valueText: "\(sto.tempC)°C",
                            subtitle: "主控温度",
                            accent: tempAccent,
                            size: 84,
                            lineWidth: 7.5
                        )

                        LazyVGrid(columns: twoColumns, spacing: 8) {
                            smartCell(
                                icon: "cpu",
                                label: "固态硬盘型号",
                                value: modelName
                            )
                            smartCell(
                                icon: "thermometer.medium",
                                label: "SMART 复合温度",
                                value: "\(sto.tempC) °C",
                                accent: tempAccent.primaryColor
                            )
                            smartCell(
                                icon: "heart.text.square.fill",
                                label: "NAND 寿命已用 / 剩余",
                                value: "已用 \(sto.lifeUsedPct)% · 健康 \(remainingHealth)%"
                            )
                            smartCell(
                                icon: "shippingbox.fill",
                                label: "可用备用闪存块 (Spare)",
                                value: "\(sto.availableSparePct)%"
                            )
                            smartCell(
                                icon: "arrow.down.doc.fill",
                                label: "累计主机读取总量",
                                value: String(format: "%.2f TB", sto.dataReadTB)
                            )
                            smartCell(
                                icon: "arrow.up.doc.fill",
                                label: "累计主机写入总量 (TBW)",
                                value: String(format: "%.2f TB", sto.dataWrittenTB)
                            )
                            smartCell(
                                icon: "clock.badge.checkmark.fill",
                                label: "累计通电时长 / 通电次数",
                                value: "\(sto.powerOnHours) 小时 · \(sto.powerCycles) 次"
                            )
                            smartCell(
                                icon: "exclamationmark.triangle.fill",
                                label: "不安全断电计数 (Unsafe Shutdowns)",
                                value: "\(sto.unsafeShutdowns) 次"
                            )
                        }
                    }
                } else {
                    Text("当前未能读取 NVMe SMART Log Page 0x02 数据（非 NVMe 根分区或设备不支持 SMART 接口）。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func smartCell(
        icon: String,
        label: String,
        value: String,
        accent: Color? = nil
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(accent ?? .primary)
                    .lineLimit(1)
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
