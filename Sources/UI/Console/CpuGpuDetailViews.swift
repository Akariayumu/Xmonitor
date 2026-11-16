import Foundation
import SwiftUI

struct CpuDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let cpu = engine.snapshot.cpu
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: twoColumns, spacing: 14) {
                cpuOverviewCard(cpu: cpu)
                cpuFreqPowerCard(cpu: cpu)
            }

            LazyVGrid(columns: twoColumns, spacing: 14) {
                cpuLoadChartCard(cpu: cpu)
                cpuPowerChartCard(cpu: cpu)
            }

            perThreadMatrixCard(cpu: cpu)

            cStateAndThermalCard(cpu: cpu)
        }
    }

    private func cpuOverviewCard(cpu: CpuSnapshot) -> some View {
        let load1 = cpu.loadAvg.count > 0 ? cpu.loadAvg[0] : 0
        let load5 = cpu.loadAvg.count > 1 ? cpu.loadAvg[1] : 0
        let load15 = cpu.loadAvg.count > 2 ? cpu.loadAvg[2] : 0
        let idlePct = max(0.0, 100.0 - cpu.totalUsage)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "处理器总览与内核负载",
                    subtitle: "Mach PROCESSOR_CPU_LOAD_INFO · 4 核 8 线程",
                    icon: "cpu.fill",
                    accent: .cyan,
                    trailingBadge: "Load \(String(format: "%.2f", load1))"
                )

                HStack(spacing: 18) {
                    RingGauge(
                        progress: cpu.totalUsage / 100.0,
                        valueText: ConsoleFormat.percentInt(cpu.totalUsage),
                        subtitle: "总占用",
                        accent: .cyan,
                        size: 86,
                        lineWidth: 8
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            ConsoleStatRow(label: "用户态 User", value: ConsoleFormat.percent1(cpu.userUsage))
                            ConsoleLinearBar(fraction: cpu.userUsage / 100.0, accent: .cyan, height: 6)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            ConsoleStatRow(label: "内核态 System", value: ConsoleFormat.percent1(cpu.sysUsage))
                            ConsoleLinearBar(fraction: cpu.sysUsage / 100.0, accent: .indigo, height: 6)
                        }

                        ConsoleStatRow(label: "空闲率 Idle", value: ConsoleFormat.percent1(idlePct))
                        ConsoleStatRow(
                            label: "平均负载 (1 / 5 / 15m)",
                            value: String(format: "%.2f · %.2f · %.2f", load1, load5, load15)
                        )
                    }
                }
            }
        }
    }

    private func cpuFreqPowerCard(cpu: CpuSnapshot) -> some View {
        let uncoreWatts = max(0.0, cpu.packagePowerW - cpu.corePowerW)
        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "频率与 RAPL 能耗遥测",
                    subtitle: "libIOReport pmtelemetry_cpu · 免 sudo 直读",
                    icon: "bolt.horizontal.circle.fill",
                    accent: .amber,
                    trailingBadge: ConsoleFormat.watts2(cpu.packagePowerW)
                )

                HStack(spacing: 18) {
                    RingGauge(
                        progress: min(1.0, cpu.maxFreqMHz / 4700.0),
                        valueText: MetricFormat.menuGHz(cpu.maxFreqMHz).trimmingCharacters(in: .whitespaces),
                        subtitle: "峰值睿频",
                        accent: .indigo,
                        size: 86,
                        lineWidth: 8
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        ConsoleStatRow(
                            label: "当前最高线程频点",
                            value: "\(ConsoleFormat.ghz(cpu.maxFreqMHz)) (\(ConsoleFormat.mhzInt(cpu.maxFreqMHz)))"
                        )
                        ConsoleStatRow(
                            label: "全核平均有效频率",
                            value: "\(ConsoleFormat.ghz(cpu.avgFreqMHz)) (\(ConsoleFormat.mhzInt(cpu.avgFreqMHz)))"
                        )
                        ConsoleStatRow(
                            label: "Package 封装总功耗",
                            value: ConsoleFormat.watts2(cpu.packagePowerW),
                            valueAccent: SenseiAccent.amber.primaryColor
                        )
                        ConsoleStatRow(
                            label: "IA Cores / Uncore 功耗",
                            value: "\(ConsoleFormat.watts2(cpu.corePowerW)) / \(ConsoleFormat.watts2(uncoreWatts))"
                        )
                        ConsoleStatRow(
                            label: "CPU 封装温度 (SMC)",
                            value: MetricFormat.optionalTemp(cpu.hasTemp, cpu.packageTempC)
                        )
                    }
                }
            }
        }
    }

    private func cpuLoadChartCard(cpu: CpuSnapshot) -> some View {
        let history = engine.cpuHistory.values
        let stats = ConsoleFormat.seriesStats(history)
        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "60 点处理器负载曲线",
                    subtitle: "平滑历史窗口 · 零堆内存重分配环形缓冲",
                    icon: "chart.xyaxis.line",
                    accent: .cyan,
                    trailingBadge: ConsoleFormat.percent1(cpu.totalUsage)
                )

                AreaSparkline(values: history, maxValue: 100, accent: .cyan, height: 88)

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

    private func cpuPowerChartCard(cpu: CpuSnapshot) -> some View {
        let history = engine.powerHistory.values
        let stats = ConsoleFormat.seriesStats(history)
        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "60 点 RAPL 封装功耗曲线",
                    subtitle: "MSR_IA32_PKG_ENERGY_STATUS (uint32 回绕安全)",
                    icon: "flame.fill",
                    accent: .amber,
                    trailingBadge: ConsoleFormat.watts2(cpu.packagePowerW)
                )

                AreaSparkline(values: history, accent: .amber, height: 88)

                HStack {
                    Text("最低 \(ConsoleFormat.watts2(stats.min))")
                    Spacer()
                    Text("均值 \(ConsoleFormat.watts2(stats.avg))")
                    Spacer()
                    Text("峰值 \(ConsoleFormat.watts2(stats.max))")
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func perThreadMatrixCard(cpu: CpuSnapshot) -> some View {
        let displayThreads = max(8, cpu.threadCount)
        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "8 线程实时利用率与 APERF/MPERF 频率矩阵",
                    subtitle: "Tiger Lake Willow Cove 4 物理核心 × 超线程 SMT (基频 2800 MHz · 单核睿频 4700 MHz)",
                    icon: "square.grid.4x3.fill",
                    accent: .cyan,
                    trailingBadge: "\(displayThreads) Threads"
                )

                LazyVGrid(columns: twoColumns, spacing: 10) {
                    ForEach(0..<displayThreads, id: \.self) { idx in
                        let usage = idx < cpu.threadUsage.count ? cpu.threadUsage[idx] : 0.0
                        let freq = idx < cpu.threadFreqMHz.count ? cpu.threadFreqMHz[idx] : 0.0
                        let physCore = idx / 2
                        let smtSlot = idx % 2

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("T\(idx)")
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(SenseiAccent.cyan.primaryColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(SenseiAccent.cyan.primaryColor.opacity(0.15))
                                    )

                                Text("Core \(physCore) · SMT \(smtSlot)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(ConsoleFormat.mhzInt(freq))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(SenseiAccent.indigo.primaryColor)

                                Text(ConsoleFormat.percent1(usage))
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                            }

                            ConsoleLinearBar(
                                fraction: usage / 100.0,
                                accent: usage > 75 ? .coral : .cyan,
                                height: 6
                            )

                            ConsoleLinearBar(
                                fraction: min(1.0, freq / 4700.0),
                                accent: .indigo,
                                height: 3.5
                            )
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                    }
                }
            }
        }
    }

    private func cStateAndThermalCard(cpu: CpuSnapshot) -> some View {
        let cStateClamped = min(100.0, max(0.0, cpu.pkgCStatePct))
        let activeResidency = max(0.0, 100.0 - cStateClamped)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "Package C-State 省电驻留与数字热传感器 (DTS)",
                    subtitle: "MSR_IA32_PKG_C2..C10_RESIDENCY 深度节能比例 & AppleSMC 温度",
                    icon: "leaf.fill",
                    accent: .emerald,
                    trailingBadge: "Pkg C-State \(ConsoleFormat.percent1(cStateClamped))"
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("深度省电驻留 (Pkg C2–C10): \(ConsoleFormat.percent1(cStateClamped))", systemImage: "moon.zzz.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SenseiAccent.emerald.primaryColor)
                        Spacer()
                        Text("活跃执行态 (C0/C1): \(ConsoleFormat.percent1(activeResidency))")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geo in
                        let w = geo.size.width
                        let greenW = w * (cStateClamped / 100.0)
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(SenseiAccent.emerald.gradient)
                                .frame(width: max(0, greenW))
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(SenseiAccent.cyan.primaryColor.opacity(0.35))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 11)
                }

                Divider().opacity(0.3)

                if cpu.hasTemp {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("物理核心温度传感器 (AppleSMC TC0P / TC0C..TC3C)")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            ConsoleBadge(
                                text: "封装 \(MetricFormat.optionalTemp(true, cpu.packageTempC))",
                                icon: "thermometer.medium",
                                accent: cpu.packageTempC > 80 ? .coral : .emerald
                            )
                        }

                        if !cpu.coreTempC.isEmpty {
                            HStack(spacing: 10) {
                                ForEach(Array(cpu.coreTempC.enumerated()), id: \.offset) { index, temp in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text("Core \(index)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(MetricFormat.optionalTemp(true, temp))
                                                .font(.system(size: 12.5, weight: .bold))
                                                .monospacedDigit()
                                        }
                                        ConsoleLinearBar(
                                            fraction: min(1.0, max(0.0, temp / 100.0)),
                                            accent: temp > 80 ? .coral : (temp > 65 ? .amber : .emerald),
                                            height: 5
                                        )
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.primary.opacity(0.045))
                                    )
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "thermometer.medium")
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("CPU 核心温度：\(MetricFormat.optionalTemp(false, 0))  ·  当前 EFI v2.0 未加载 SMCProcessor.kext，已优雅降级；启用可选 EFI v2.0.1 传感器包后将自动显示实时 °C。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }
}

struct GpuDetailView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        let gpu = engine.snapshot.gpu
        VStack(alignment: .leading, spacing: 16) {
            gpuHeroCard(gpu: gpu)

            gpuBusyChartCard(gpu: gpu)

            LazyVGrid(columns: twoColumns, spacing: 14) {
                gartApertureCard(gpu: gpu)
                displaySinkHealthCard(gpu: gpu)
            }
        }
    }

    private func gpuHeroCard(gpu: GpuSnapshot) -> some View {
        let isRC6 = gpu.usagePct < 0.5
        let reqText: String
        if !gpu.hasFreq {
            reqText = "—"
        } else if isRC6 {
            reqText = "0 MHz (RC6)"
        } else {
            reqText = "\(gpu.requestedFreqMHz) MHz"
        }

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "Intel Iris Xe Graphics (96 EU · Tiger Lake GT2)",
                    subtitle: "PCI 8086:9A49 · WhateverXe 0.8.2 · libIOReport GPU C-States 真实驻留采样",
                    icon: "display",
                    accent: .indigo,
                    trailingBadge: "Zero-Forcewake"
                )

                HStack(spacing: 22) {
                    RingGauge(
                        progress: gpu.usagePct / 100.0,
                        valueText: ConsoleFormat.percentInt(gpu.usagePct),
                        subtitle: "RC0 活跃",
                        accent: .indigo,
                        size: 88,
                        lineWidth: 8
                    )

                    RingGauge(
                        progress: gpu.rc6Pct / 100.0,
                        valueText: ConsoleFormat.percentInt(gpu.rc6Pct),
                        subtitle: "RC6 休眠",
                        accent: .emerald,
                        size: 88,
                        lineWidth: 8
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        ConsoleStatRow(
                            label: "GT 渲染域忙碌率 (RC0 + RC1)",
                            value: ConsoleFormat.percent1(gpu.usagePct),
                            valueAccent: SenseiAccent.indigo.primaryColor
                        )
                        ConsoleStatRow(
                            label: "RC6 深度门控休眠率",
                            value: ConsoleFormat.percent1(gpu.rc6Pct),
                            valueAccent: SenseiAccent.emerald.primaryColor
                        )
                        ConsoleStatRow(
                            label: "核显实际频率 (GEN12_RPSTAT1)",
                            value: MetricFormat.optionalMHz(gpu.hasFreq, gpu.currentFreqMHz, isRC6: isRC6)
                        )
                        ConsoleStatRow(
                            label: "软件请求频点 (GEN6_RPNSWREQ)",
                            value: reqText
                        )
                        ConsoleStatRow(
                            label: "GT 独立功耗 (RAPL PP1)",
                            value: ConsoleFormat.watts2(gpu.powerW),
                            valueAccent: SenseiAccent.amber.primaryColor
                        )
                    }
                }

                if !gpu.hasFreq {
                    Text("提示：当前运行在标准 S0ixStandby v2.0 固件上（核显频率显示为 —），所有采集均严格零 FORCEWAKE，绝不打断 RC6 休眠。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func gpuBusyChartCard(gpu: GpuSnapshot) -> some View {
        let history = engine.gpuHistory.values
        let stats = ConsoleFormat.seriesStats(history)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "Iris Xe RC0 实时负载面积图 (60 点历史)",
                    subtitle: "通过 ΔRC0 / (ΔRC0 + ΔRC1 + ΔRC6) 计算真实引擎利用率（绕过恒为 0 的 Device Utilization %）",
                    icon: "waveform.path.ecg.rectangle.fill",
                    accent: .indigo,
                    trailingBadge: ConsoleFormat.percent1(gpu.usagePct)
                )

                AreaSparkline(values: history, maxValue: 100, accent: .indigo, height: 104)

                HStack {
                    Text("最低 \(ConsoleFormat.percent1(stats.min))")
                    Spacer()
                    Text("均值 \(ConsoleFormat.percent1(stats.avg))")
                    Spacer()
                    Text("峰值 \(ConsoleFormat.percent1(stats.max))")
                    Spacer()
                    Text("当前 GT 功耗 \(ConsoleFormat.watts2(gpu.powerW))")
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func gartApertureCard(gpu: GpuSnapshot) -> some View {
        let freeBytes = gpu.gartSizeBytes > gpu.gartUsedBytes
            ? (gpu.gartSizeBytes - gpu.gartUsedBytes)
            : 0

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "GART 共享显存映射池",
                    subtitle: "IntelAccelerator PerformanceStatistics · 64 位防下溢",
                    icon: "memorychip",
                    accent: .cyan,
                    trailingBadge: ConsoleFormat.percent1(gpu.gartUsedPercent)
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(MetricFormat.bytes(gpu.gartUsedBytes))
                            .font(.system(size: 22, weight: .bold))
                            .monospacedDigit()
                        Text("/ \(MetricFormat.bytes(gpu.gartSizeBytes)) 映射池")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ConsoleLinearBar(
                        fraction: gpu.gartUsedPercent / 100.0,
                        accent: .cyan,
                        height: 9
                    )
                }

                VStack(alignment: .leading, spacing: 5) {
                    ConsoleStatRow(label: "已映射 GART 页容量", value: MetricFormat.bytes(gpu.gartUsedBytes))
                    ConsoleStatRow(label: "剩余可映射空间", value: MetricFormat.bytes(freeBytes))
                    ConsoleStatRow(label: "GART 总孔径上限", value: MetricFormat.bytes(gpu.gartSizeBytes))
                }
            }
        }
    }

    private func displaySinkHealthCard(gpu: GpuSnapshot) -> some View {
        let display = ConsoleFormat.activeDisplaySummary()
        let totalAttempts = gpu.sinkRestoreOk + gpu.sinkRestoreRetries
        let successPct: Double = totalAttempts > 0
            ? (Double(gpu.sinkRestoreOk) / Double(totalAttempts)) * 100.0
            : 100.0

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 12) {
                ConsoleSectionHeader(
                    title: "内屏 eDP 链路与 TGLSinkRestoreRate",
                    subtitle: "13.4\" 3840×2400 @ 60Hz · 唤醒重训练健康度监控",
                    icon: "sparkles.tv.fill",
                    accent: .emerald,
                    trailingBadge: gpu.sinkRestoreRetries == 0 ? "100% 稳定" : ConsoleFormat.percent1(successPct)
                )

                VStack(alignment: .leading, spacing: 6) {
                    ConsoleStatRow(
                        label: "物理面板原生规格",
                        value: display.panelSpec,
                        valueAccent: SenseiAccent.cyan.primaryColor
                    )
                    ConsoleStatRow(
                        label: "当前渲染缩放模式",
                        value: "\(display.activeMode) · \(display.refreshHz)"
                    )
                    ConsoleStatRow(
                        label: "TGLSinkRestore 成功点亮次数",
                        value: "\(gpu.sinkRestoreOk) 次",
                        valueAccent: SenseiAccent.emerald.primaryColor
                    )
                    ConsoleStatRow(
                        label: "TGLSinkRestore 链路重试次数",
                        value: "\(gpu.sinkRestoreRetries) 次",
                        valueAccent: gpu.sinkRestoreRetries > 0 ? SenseiAccent.amber.primaryColor : nil
                    )
                    ConsoleStatRow(
                        label: "S0ix / DC9 唤醒链路完好率",
                        value: ConsoleFormat.percent1(successPct)
                    )
                }
            }
        }
    }
}
