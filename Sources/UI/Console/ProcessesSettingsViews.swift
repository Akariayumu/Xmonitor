import AppKit
import Foundation
import ServiceManagement
import SwiftUI

enum ProcessSortCriterion: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "按 CPU% 排序"
        case .memory: return "按内存排序"
        }
    }
}

struct ProcessesSettingsViews: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var widgetManager: DesktopWidgetManager
    @ObservedObject var navigation: ConsoleNavigationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            subTabSwitcher

            switch navigation.processesSubTab {
            case .processes:
                ProcessesPaneView(engine: engine, settings: settings)
            case .settings:
                SettingsPaneView(
                    engine: engine,
                    settings: settings,
                    widgetManager: widgetManager
                )
            }
        }
    }

    private var subTabSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(ProcessesSettingsSubTab.allCases) { tab in
                let isSelected = (navigation.processesSubTab == tab)
                Button {
                    navigation.processesSubTab = tab
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                isSelected
                                    ? AnyShapeStyle(SenseiAccent.violet.gradient)
                                    : AnyShapeStyle(Color.primary.opacity(0.07))
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }
}

private struct ProcessesPaneView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore

    @State private var sortBy: ProcessSortCriterion = .cpu
    @State private var ascending: Bool = false
    @State private var filterQuery: String = ""

    private var sortedProcesses: [ProcessEntry] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = engine.snapshot.topProcesses.filter { proc in
            guard !query.isEmpty else { return true }
            return proc.name.lowercased().contains(query) || "\(proc.pid)".contains(query)
        }

        return filtered.sorted { lhs, rhs in
            let orderedDescending: Bool
            switch sortBy {
            case .cpu:
                if abs(lhs.cpuPct - rhs.cpuPct) > 0.001 {
                    orderedDescending = lhs.cpuPct > rhs.cpuPct
                } else {
                    orderedDescending = lhs.memoryBytes > rhs.memoryBytes
                }
            case .memory:
                if lhs.memoryBytes != rhs.memoryBytes {
                    orderedDescending = lhs.memoryBytes > rhs.memoryBytes
                } else {
                    orderedDescending = lhs.cpuPct > rhs.cpuPct
                }
            }
            return ascending ? !orderedDescending : orderedDescending
        }
    }

    var body: some View {
        let snap = engine.snapshot
        let rows = sortedProcesses
        let maxMem = max(1, rows.map(\.memoryBytes).max() ?? 1)

        GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ConsoleSectionHeader(
                        title: "实时活跃进程排行 (Top 30)",
                        subtitle: snap.isAllUsersProcessList
                            ? "全系统进程源：libsysmon 订阅（免 root 含 WindowServer / 内核守护）"
                            : "用户态回退源：libproc RUSAGE_INFO_V4（当前登录 UID 进程）",
                        icon: "list.number",
                        accent: .violet
                    )

                    ConsoleBadge(
                        text: snap.isAllUsersProcessList ? "全系统进程" : "当前用户进程",
                        icon: snap.isAllUsersProcessList ? "checkmark.shield.fill" : "person.fill",
                        accent: snap.isAllUsersProcessList ? .emerald : .cyan
                    )
                }

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField("按进程名或 PID 过滤…", text: $filterQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !filterQuery.isEmpty {
                            Button {
                                filterQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Spacer()

                    Picker("排序方式", selection: $sortBy) {
                        ForEach(ProcessSortCriterion.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)

                    Button {
                        ascending.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .bold))
                            Text(ascending ? "升序" : "降序")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider().opacity(0.35)

                tableHeaderRow

                if rows.isEmpty {
                    Text(filterQuery.isEmpty ? "正在收集实时进程采样数据…" : "没有匹配 \"\(filterQuery)\" 的进程")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, proc in
                            processRow(rank: index + 1, proc: proc, maxMemory: maxMem)
                        }
                    }
                }
            }
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 12) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text("进程名称")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("身份")
                .frame(width: 64, alignment: .center)
            Text("PID")
                .frame(width: 66, alignment: .trailing)

            Button {
                toggleColumnSort(.cpu)
            } label: {
                HStack(spacing: 3) {
                    Text("CPU %")
                    if sortBy == .cpu {
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(sortBy == .cpu ? SenseiAccent.cyan.primaryColor : .secondary)
                .frame(width: 136, alignment: .trailing)
            }
            .buttonStyle(.plain)

            Button {
                toggleColumnSort(.memory)
            } label: {
                HStack(spacing: 3) {
                    Text("物理内存")
                    if sortBy == .memory {
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(sortBy == .memory ? SenseiAccent.emerald.primaryColor : .secondary)
                .frame(width: 146, alignment: .trailing)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private func toggleColumnSort(_ target: ProcessSortCriterion) {
        if sortBy == target {
            ascending.toggle()
        } else {
            sortBy = target
            ascending = false
        }
    }

    private func processRow(rank: Int, proc: ProcessEntry, maxMemory: UInt64) -> some View {
        let isRoot = (proc.uid == 0)
        let cpuFraction = min(1.0, max(0.0, proc.cpuPct / 100.0))
        let memFraction = min(1.0, max(0.0, Double(proc.memoryBytes) / Double(max(1, maxMemory))))

        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            HStack(spacing: 7) {
                Image(systemName: isRoot ? "gearshape.2.fill" : "app.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isRoot ? SenseiAccent.indigo.primaryColor : SenseiAccent.cyan.primaryColor)
                Text(proc.name.isEmpty ? "pid-\(proc.pid)" : proc.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isRoot ? "root" : "uid \(proc.uid)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isRoot ? SenseiAccent.indigo.primaryColor : .secondary)
                .frame(width: 64, alignment: .center)

            Text("\(proc.pid)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)

            HStack(spacing: 8) {
                ConsoleLinearBar(
                    fraction: cpuFraction,
                    accent: proc.cpuPct > 60 ? .coral : .cyan,
                    height: 5
                )
                .frame(width: 66)

                Text(String(format: "%.1f%%", proc.cpuPct))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(width: 136, alignment: .trailing)

            HStack(spacing: 8) {
                ConsoleLinearBar(
                    fraction: memFraction,
                    accent: .emerald,
                    height: 5
                )
                .frame(width: 62)

                Text(MetricFormat.bytes(proc.memoryBytes))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }
            .frame(width: 146, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rank % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
        )
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var engine: TelemetryEngine
    @ObservedObject var settings: SettingsStore
    @ObservedObject var widgetManager: DesktopWidgetManager

    @State private var loginStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginErrorMessage: String? = nil
    @State private var presetRefreshCounter: Int = 0
    @State private var didResetToast: Bool = false

    private let twoColumns = [
        GridItem(.flexible(minimum: 300), spacing: 14),
        GridItem(.flexible(minimum: 300), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: twoColumns, spacing: 14) {
                launchAndPolicyCard
                themeAndOpacityCard
            }

            menuBarModulesCard

            desktopWidgetsCard

            aboutAndLifecycleCard
        }
        .onAppear {
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var launchAndPolicyCard: some View {
        let isLaunchEnabled = (loginStatus == .enabled)

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "登录自启与自适应采样策略",
                    subtitle: "ServiceManagement SMAppService.mainApp · 免守护进程",
                    icon: "power.circle.fill",
                    accent: .emerald,
                    trailingBadge: launchStatusBadgeText
                )

                Toggle(
                    isOn: Binding(
                        get: { isLaunchEnabled },
                        set: { shouldEnable in
                            setLaunchAtLogin(shouldEnable)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 macOS 时自动启动 XSensei")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("静默驻留顶部菜单栏与壁纸层小组件（无 Dock 图标干扰）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if loginStatus == .requiresApproval {
                    Text("请在「系统设置 → 通用 → 登录项」中允许 XSensei 在后台运行。")
                        .font(.system(size: 11))
                        .foregroundStyle(SenseiAccent.amber.primaryColor)
                }

                if let loginErrorMessage {
                    Text(loginErrorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(SenseiAccent.coral.primaryColor)
                }

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 5) {
                    ConsoleStatRow(
                        label: "当前活跃采样周期",
                        value: String(format: "%.1f 秒 / 次", engine.currentInterval),
                        valueAccent: SenseiAccent.cyan.primaryColor
                    )
                    ConsoleStatRow(label: "控制台 / 下拉面板展开时", value: "1.0s 高速档 (含 Top 进程)")
                    ConsoleStatRow(label: "仅菜单栏 / 桌面组件常驻时", value: "2.0s 节能档 (< 0.3% CPU)")
                    ConsoleStatRow(label: "屏幕熄灭 / S0ix 睡眠期间", value: "0 Hz 完全挂起定时器")
                }
            }
        }
    }

    private var launchStatusBadgeText: String {
        switch loginStatus {
        case .enabled: return "已开启自启"
        case .requiresApproval: return "待系统授权"
        case .notRegistered: return "未开启"
        case .notFound: return "未注册包"
        @unknown default: return "未知状态"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginErrorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginStatus = SMAppService.mainApp.status
        } catch {
            loginStatus = SMAppService.mainApp.status
            loginErrorMessage = "更新登录启动项失败（请确认应用已安装于 /Applications/XSensei.app）：\(error.localizedDescription)"
        }
    }

    private var themeAndOpacityCard: some View {
        GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "主题模式与毛玻璃通透度",
                    subtitle: "支持跟随系统、深色石墨与浅色磨砂三种 Sensei 视觉风格",
                    icon: "paintbrush.pointed.fill",
                    accent: .indigo,
                    trailingBadge: "\(Int((settings.widgetOpacity * 100).rounded()))%"
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("界面色彩主题")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        themeOptionButton(mode: .system, title: "跟随系统", icon: "circle.lefthalf.filled")
                        themeOptionButton(mode: .darkGraphite, title: "深色石墨", icon: "moon.fill")
                        themeOptionButton(mode: .lightFrost, title: "浅色磨砂", icon: "sun.max.fill")
                    }
                }

                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("毛玻璃卡片与小组件不透明度")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("\(Int((settings.widgetOpacity * 100).rounded()))%")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(SenseiAccent.indigo.primaryColor)
                        Button("重置 88%") {
                            settings.widgetOpacity = 0.88
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }

                    Slider(value: $settings.widgetOpacity, in: 0.30...1.00, step: 0.01)
                        .tint(SenseiAccent.indigo.primaryColor)

                    HStack {
                        Text("30% 轻透壁纸融合")
                        Spacer()
                        Text("100% 高对比实心毛玻璃")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func themeOptionButton(mode: AppThemeMode, title: String, icon: String) -> some View {
        let selected = (settings.themeMode == mode)
        return Button {
            settings.themeMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(SenseiAccent.indigo.gradient)
                            : AnyShapeStyle(Color.primary.opacity(0.07))
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var menuBarModulesCard: some View {
        GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                ConsoleSectionHeader(
                    title: "顶部菜单栏实时显示项",
                    subtitle: "等宽数字固定位宽渲染 · 数字刷新零左右抖动",
                    icon: "menubar.rectangle",
                    accent: .cyan
                )

                LazyVGrid(columns: twoColumns, spacing: 10) {
                    menuToggleTile(
                        title: "处理器占用与峰值频率",
                        example: "CPU  8% 0.9G",
                        icon: "cpu.fill",
                        isOn: $settings.showMenuCPU
                    )
                    menuToggleTile(
                        title: "Iris Xe 核显占用率",
                        example: "GPU  2%",
                        icon: "display",
                        isOn: $settings.showMenuGPU
                    )
                    menuToggleTile(
                        title: "LPDDR4X 内存使用率",
                        example: "RAM 54%",
                        icon: "memorychip.fill",
                        isOn: $settings.showMenuRAM
                    )
                    menuToggleTile(
                        title: "充放电 / 封装实时瓦数",
                        example: "4.1W",
                        icon: "bolt.fill",
                        isOn: $settings.showMenuPower
                    )
                    menuToggleTile(
                        title: "Wi-Fi 6 实时网速",
                        example: "↓ 1.2 MB/s",
                        icon: "wifi",
                        isOn: $settings.showMenuNet
                    )
                    menuToggleTile(
                        title: "CPU 封装温度 (SMC)",
                        example: "46°C",
                        icon: "thermometer.medium",
                        isOn: $settings.showMenuTemp
                    )
                }
            }
        }
    }

    private func menuToggleTile(
        title: String,
        example: String,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? SenseiAccent.cyan.primaryColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("示例：\(example)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var desktopWidgetsCard: some View {
        let _ = presetRefreshCounter

        return GlassCard(padding: 16, cornerRadius: 16, opacity: settings.widgetOpacity) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ConsoleSectionHeader(
                        title: "壁纸层桌面小组件管理",
                        subtitle: "常驻桌面图标层上方 · 锁定态 100% 鼠标与十点触控点击穿透",
                        icon: "uiwindow.split.2x1",
                        accent: .cyan
                    )

                    Button {
                        settings.widgetsLocked.toggle()
                        widgetManager.refreshVisibilityAndFrames()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: settings.widgetsLocked ? "lock.open.fill" : "lock.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(settings.widgetsLocked ? "解锁拖拽布局" : "完成并锁定穿透")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(settings.widgetsLocked ? Color.primary : .white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    settings.widgetsLocked
                                        ? AnyShapeStyle(Color.primary.opacity(0.09))
                                        : AnyShapeStyle(SenseiAccent.cyan.gradient)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        widgetManager.resetAllPositions()
                        widgetManager.refreshVisibilityAndFrames()
                        didResetToast = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didResetToast = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: didResetToast ? "checkmark" : "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text(didResetToast ? "已重置布局" : "重置默认位置")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(didResetToast ? SenseiAccent.emerald.primaryColor : .secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Image(systemName: settings.widgetsLocked ? "hand.point.up.braille.fill" : "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 12))
                        .foregroundStyle(settings.widgetsLocked ? SenseiAccent.emerald.primaryColor : SenseiAccent.cyan.primaryColor)
                    Text(
                        settings.widgetsLocked
                            ? "当前状态：已锁定（点击穿透启用）— 触摸屏手势与鼠标点击直接穿透至桌面，不抢窗口焦点。"
                            : "当前状态：编辑模式已开启 — 可直接在桌面拖拽小组件（8pt 网格吸附），调整完毕请点击「完成并锁定穿透」。"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            (settings.widgetsLocked ? SenseiAccent.emerald : SenseiAccent.cyan)
                                .primaryColor.opacity(0.10)
                        )
                )

                VStack(spacing: 8) {
                    ForEach(DesktopWidgetKind.allCases) { kind in
                        widgetConfigRow(kind: kind)
                    }
                }
            }
        }
    }

    private func widgetConfigRow(kind: DesktopWidgetKind) -> some View {
        let enabled = widgetManager.isWidgetEnabled(kind)
        let currentPreset = widgetManager.sizePreset(for: kind)

        return HStack(spacing: 12) {
            Image(systemName: widgetIcon(for: kind))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(enabled ? SenseiAccent.cyan.primaryColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(widgetSubtitle(for: kind))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(WidgetSizePreset.allCases, id: \.rawValue) { preset in
                    let isSelected = (currentPreset == preset)
                    Button {
                        widgetManager.setSizePreset(preset, for: kind)
                        presetRefreshCounter += 1
                    } label: {
                        Text(sizeLabel(for: preset))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? AnyShapeStyle(SenseiAccent.cyan.gradient)
                                            : AnyShapeStyle(Color.primary.opacity(0.06))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1.0 : 0.45)
                }
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { widgetManager.isWidgetEnabled(kind) },
                    set: { newValue in
                        widgetManager.setWidgetEnabled(kind, enabled: newValue)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func widgetIcon(for kind: DesktopWidgetKind) -> String {
        switch kind {
        case .cpuGpu: return "cpu.fill"
        case .memoryStorage: return "memorychip.fill"
        case .powerS0ix: return "bolt.batteryblock.fill"
        case .network: return "wifi"
        }
    }

    private func widgetSubtitle(for kind: DesktopWidgetKind) -> String {
        switch kind {
        case .cpuGpu:
            return "双圆环仪表 + 60 点实时负载曲线 + 睿频与功耗胶囊"
        case .memoryStorage:
            return "LPDDR4X 分段占用条 + Kingston NVMe 读写速率与 SMART 温度"
        case .powerS0ix:
            return "电量环 + 充放电瓦数 + S0ix CC7/PC8 驻留率与唤醒源"
        case .network:
            return "Wi-Fi 6 上下行波形图 + AX201 协商速率、RSSI 与局域网 IP"
        }
    }

    private func sizeLabel(for preset: WidgetSizePreset) -> String {
        switch preset {
        case .compact: return "S 紧凑"
        case .standard: return "M 标准"
        case .wide: return "L 宽幅"
        }
    }

    private var aboutAndLifecycleCard: some View {
        GlassCard(padding: 15, cornerRadius: 16, opacity: settings.widgetOpacity) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SenseiAccent.emerald.primaryColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("XSensei Hardware Telemetry Suite · X-STATION V2 Edition")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("关闭本控制台窗口将自动隐藏 Dock 图标，顶部菜单栏与桌面小组件继续以 2.0s 节能档后台常驻。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .bold))
                        Text("退出 XSensei")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(SenseiAccent.coral.primaryColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(SenseiAccent.coral.primaryColor.opacity(0.14))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
