import Combine
import Foundation

enum AppThemeMode: String, CaseIterable, Codable, Sendable {
    case system
    case darkGraphite
    case lightFrost
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let themeMode = "xsensei.themeMode"
        static let showMenuCPU = "xsensei.showMenuCPU"
        static let showMenuGPU = "xsensei.showMenuGPU"
        static let showMenuRAM = "xsensei.showMenuRAM"
        static let showMenuPower = "xsensei.showMenuPower"
        static let showMenuNet = "xsensei.showMenuNet"
        static let showMenuTemp = "xsensei.showMenuTemp"
        static let widgetsLocked = "xsensei.widgetsLocked"
        static let widgetOpacity = "xsensei.widgetOpacity"
    }

    let defaults: UserDefaults

    @Published var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    @Published var showMenuCPU: Bool {
        didSet { defaults.set(showMenuCPU, forKey: Keys.showMenuCPU) }
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

        self.showMenuCPU = defaults.object(forKey: Keys.showMenuCPU) as? Bool ?? true
        self.showMenuGPU = defaults.object(forKey: Keys.showMenuGPU) as? Bool ?? true
        self.showMenuRAM = defaults.object(forKey: Keys.showMenuRAM) as? Bool ?? true
        self.showMenuPower = defaults.object(forKey: Keys.showMenuPower) as? Bool ?? true
        self.showMenuNet = defaults.object(forKey: Keys.showMenuNet) as? Bool ?? false
        self.showMenuTemp = defaults.object(forKey: Keys.showMenuTemp) as? Bool ?? false
        self.widgetsLocked = defaults.object(forKey: Keys.widgetsLocked) as? Bool ?? true

        if let storedOpacity = defaults.object(forKey: Keys.widgetOpacity) as? Double {
            self.widgetOpacity = min(1.0, max(0.3, storedOpacity))
        } else {
            self.widgetOpacity = 0.88
        }
    }
}
