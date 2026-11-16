import Combine
import Foundation

enum AppThemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case darkGraphite
    case lightFrost
}

enum MenuBarLayoutStyle: String, CaseIterable, Codable, Sendable {
    case stacked
    case inline
    case minimal

    var displayTitle: String {
        switch self {
        case .stacked: return "紧凑双行"
        case .inline: return "经典单行"
        case .minimal: return "极简图标"
        }
    }

    var subtitle: String {
        switch self {
        case .stacked: return "上下双行同色排版，省空间且层次清晰"
        case .inline: return "单行等宽同色文字，原生亮色零灰差"
        case .minimal: return "微图标配实时数值，隐藏英文缩写"
        }
    }
}

enum MenuBarModule: String, CaseIterable, Identifiable, Codable, Sendable {
    case cpu
    case temp
    case gpu
    case ram
    case power
    case net

    var id: String { rawValue }

    static let defaultOrder: [MenuBarModule] = [.cpu, .temp, .gpu, .ram, .power, .net]

    var title: String {
        switch self {
        case .cpu: return "处理器占用与频率 (CPU)"
        case .temp: return "处理器封装温度 (TEMP)"
        case .gpu: return "Iris Xe 核显占用 (GPU)"
        case .ram: return "内存使用率 (RAM)"
        case .power: return "整机 / 封装实时功耗 (PWR)"
        case .net: return "实时上下行网速 (NET)"
        }
    }

    var exampleText: String {
        switch self {
        case .cpu: return "12% 3.1G"
        case .temp: return "45°C"
        case .gpu: return "2%"
        case .ram: return "54%"
        case .power: return "4.1W"
        case .net: return "↑ 0 K/s · ↓ 128 K/s"
        }
    }

    var sfSymbol: String {
        switch self {
        case .cpu: return "cpu"
        case .temp: return "thermometer.medium"
        case .gpu: return "display"
        case .ram: return "memorychip"
        case .power: return "bolt.fill"
        case .net: return "arrow.up.arrow.down"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let themeMode = "xmonitor.themeMode"
        static let menuBarStyle = "xmonitor.menuBarStyle"
        static let menuModuleOrder = "xmonitor.menuModuleOrder"
        static let showMenuCPU = "xmonitor.showMenuCPU"
        static let showMenuCpuFreq = "xmonitor.showMenuCpuFreq"
        static let showMenuGPU = "xmonitor.showMenuGPU"
        static let showMenuRAM = "xmonitor.showMenuRAM"
        static let showMenuPower = "xmonitor.showMenuPower"
        static let showMenuNet = "xmonitor.showMenuNet"
        static let showMenuTemp = "xmonitor.showMenuTemp"
        static let showMenuDividers = "xmonitor.showMenuDividers"
        static let ambientRefreshInterval = "xmonitor.ambientRefreshInterval"
        static let widgetsLocked = "xmonitor.widgetsLocked"
        static let widgetOpacity = "xmonitor.widgetOpacity"
    }

    let defaults: UserDefaults

    @Published var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    @Published var menuBarStyle: MenuBarLayoutStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    @Published var menuModuleOrder: [MenuBarModule] {
        didSet {
            let normalized = Self.normalizedOrder(menuModuleOrder)
            if normalized != menuModuleOrder {
                menuModuleOrder = normalized
                return
            }
            defaults.set(normalized.map(\.rawValue), forKey: Keys.menuModuleOrder)
        }
    }

    @Published var showMenuCPU: Bool {
        didSet { defaults.set(showMenuCPU, forKey: Keys.showMenuCPU) }
    }

    @Published var showMenuCpuFreq: Bool {
        didSet { defaults.set(showMenuCpuFreq, forKey: Keys.showMenuCpuFreq) }
    }

    @Published var showMenuGPU: Bool {
        didSet { defaults.set(showMenuGPU, forKey: Keys.showMenuGPU) }
    }

    @Published var showMenuRAM: Bool {
        didSet { defaults.set(showMenuRAM, forKey: Keys.showMenuRAM) }
    }

    @Published var showMenuPower: Bool {
        didSet { defaults.set(showMenuPower, forKey: Keys.showMenuPower) }
    }

    @Published var showMenuNet: Bool {
        didSet { defaults.set(showMenuNet, forKey: Keys.showMenuNet) }
    }

    @Published var showMenuTemp: Bool {
        didSet { defaults.set(showMenuTemp, forKey: Keys.showMenuTemp) }
    }

    @Published var showMenuDividers: Bool {
        didSet { defaults.set(showMenuDividers, forKey: Keys.showMenuDividers) }
    }

    @Published var ambientRefreshInterval: Double {
        didSet {
            let clamped = min(10.0, max(1.0, ambientRefreshInterval))
            if clamped != ambientRefreshInterval {
                ambientRefreshInterval = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.ambientRefreshInterval)
        }
    }

    @Published var widgetsLocked: Bool {
        didSet { defaults.set(widgetsLocked, forKey: Keys.widgetsLocked) }
    }

    @Published var widgetOpacity: Double {
        didSet {
            let clamped = min(1.0, max(0.3, widgetOpacity))
            if clamped != widgetOpacity {
                widgetOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.widgetOpacity)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawTheme = defaults.string(forKey: Keys.themeMode),
           let parsed = AppThemeMode(rawValue: rawTheme) {
            self.themeMode = parsed
        } else {
            self.themeMode = .system
        }

        if let rawStyle = defaults.string(forKey: Keys.menuBarStyle),
           let parsed = MenuBarLayoutStyle(rawValue: rawStyle) {
            self.menuBarStyle = parsed
        } else {
            self.menuBarStyle = .stacked
        }

        if let rawOrder = defaults.stringArray(forKey: Keys.menuModuleOrder) {
            self.menuModuleOrder = Self.normalizedOrder(rawOrder.compactMap(MenuBarModule.init(rawValue:)))
        } else {
            self.menuModuleOrder = MenuBarModule.defaultOrder
        }

        self.showMenuCPU = defaults.object(forKey: Keys.showMenuCPU) as? Bool ?? true
        self.showMenuCpuFreq = defaults.object(forKey: Keys.showMenuCpuFreq) as? Bool ?? true
        self.showMenuGPU = defaults.object(forKey: Keys.showMenuGPU) as? Bool ?? true
        self.showMenuRAM = defaults.object(forKey: Keys.showMenuRAM) as? Bool ?? true
        self.showMenuPower = defaults.object(forKey: Keys.showMenuPower) as? Bool ?? true
        self.showMenuNet = defaults.object(forKey: Keys.showMenuNet) as? Bool ?? false
        self.showMenuTemp = defaults.object(forKey: Keys.showMenuTemp) as? Bool ?? true
        self.showMenuDividers = defaults.object(forKey: Keys.showMenuDividers) as? Bool ?? true

        if let storedInterval = defaults.object(forKey: Keys.ambientRefreshInterval) as? Double {
            self.ambientRefreshInterval = min(10.0, max(1.0, storedInterval))
        } else {
            self.ambientRefreshInterval = 2.0
        }

        self.widgetsLocked = defaults.object(forKey: Keys.widgetsLocked) as? Bool ?? true

        if let storedOpacity = defaults.object(forKey: Keys.widgetOpacity) as? Double {
            self.widgetOpacity = min(1.0, max(0.3, storedOpacity))
        } else {
            self.widgetOpacity = 0.88
        }
    }

    func isModuleEnabled(_ module: MenuBarModule) -> Bool {
        switch module {
        case .cpu: return showMenuCPU
        case .temp: return showMenuTemp
        case .gpu: return showMenuGPU
        case .ram: return showMenuRAM
        case .power: return showMenuPower
        case .net: return showMenuNet
        }
    }

    func setModuleEnabled(_ module: MenuBarModule, enabled: Bool) {
        switch module {
        case .cpu: showMenuCPU = enabled
        case .temp: showMenuTemp = enabled
        case .gpu: showMenuGPU = enabled
        case .ram: showMenuRAM = enabled
        case .power: showMenuPower = enabled
        case .net: showMenuNet = enabled
        }
    }

    func moveMenuModule(_ module: MenuBarModule, by delta: Int) {
        guard let idx = menuModuleOrder.firstIndex(of: module) else { return }
        let dst = idx + delta
        guard dst >= 0 && dst < menuModuleOrder.count else { return }
        var updated = menuModuleOrder
        updated.swapAt(idx, dst)
        menuModuleOrder = updated
    }

    func resetMenuModuleOrder() {
        menuModuleOrder = MenuBarModule.defaultOrder
    }

    func resetAllToDefaults() {
        themeMode = .system
        menuBarStyle = .stacked
        menuModuleOrder = MenuBarModule.defaultOrder
        showMenuCPU = true
        showMenuCpuFreq = true
        showMenuTemp = true
        showMenuGPU = true
        showMenuRAM = true
        showMenuPower = true
        showMenuNet = false
        showMenuDividers = true
        ambientRefreshInterval = 2.0
        widgetsLocked = true
        widgetOpacity = 0.88
    }

    private static func normalizedOrder(_ input: [MenuBarModule]) -> [MenuBarModule] {
        var seen: Set<MenuBarModule> = []
        var result: [MenuBarModule] = []
        for m in input where !seen.contains(m) {
            seen.insert(m)
            result.append(m)
        }
        for m in MenuBarModule.defaultOrder where !seen.contains(m) {
            seen.insert(m)
            result.append(m)
        }
        return result
    }
}
