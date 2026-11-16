import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class DesktopWidgetManager: ObservableObject {
    private enum Keys {
        static let enabledKinds = "xsensei.widgets.enabledKinds"
        static let lastNonEmptyKinds = "xsensei.widgets.lastNonEmptyKinds"
        static func sizePreset(_ kind: DesktopWidgetKind) -> String {
            "xsensei.widgets.sizePreset.\(kind.rawValue)"
        }
        static func normX(_ kind: DesktopWidgetKind) -> String {
            "xsensei.widgets.normX.\(kind.rawValue)"
        }
        static func normY(_ kind: DesktopWidgetKind) -> String {
            "xsensei.widgets.normY.\(kind.rawValue)"
        }
    }

    static let defaultEnabledKinds: Set<DesktopWidgetKind> = [.cpuGpu, .powerS0ix]

    @Published private(set) var enabledKinds: Set<DesktopWidgetKind>

    private let engine: TelemetryEngine
    private let settings: SettingsStore
    private let createPanels: Bool

    private var sizePresets: [DesktopWidgetKind: WidgetSizePreset] = [:]
    private var lastNonEmptyKinds: Set<DesktopWidgetKind>
    private var panels: [DesktopWidgetKind: DesktopWidgetPanel] = [:]
    private var cancellables: Set<AnyCancellable> = []

    convenience init(engine: TelemetryEngine, settings: SettingsStore) {
        self.init(engine: engine, settings: settings, createPanels: true)
    }

    init(engine: TelemetryEngine, settings: SettingsStore, createPanels: Bool) {
        self.engine = engine
        self.settings = settings
        self.createPanels = createPanels

        let defaults = settings.defaults
        let initialEnabled: Set<DesktopWidgetKind>
        if defaults.object(forKey: Keys.enabledKinds) != nil,
           let rawList = defaults.stringArray(forKey: Keys.enabledKinds) {
            initialEnabled = Set(rawList.compactMap(DesktopWidgetKind.init(rawValue:)))
        } else {
            initialEnabled = Self.defaultEnabledKinds
        }
        self.enabledKinds = initialEnabled

        if let rawLast = defaults.stringArray(forKey: Keys.lastNonEmptyKinds) {
            let parsed = Set(rawLast.compactMap(DesktopWidgetKind.init(rawValue:)))
            self.lastNonEmptyKinds = parsed.isEmpty ? Self.defaultEnabledKinds : parsed
        } else {
            self.lastNonEmptyKinds = initialEnabled.isEmpty ? Self.defaultEnabledKinds : initialEnabled
        }

        for kind in DesktopWidgetKind.allCases {
            if let rawPreset = defaults.string(forKey: Keys.sizePreset(kind)),
               let parsed = WidgetSizePreset(rawValue: rawPreset) {
                sizePresets[kind] = parsed
            } else {
                sizePresets[kind] = .standard
            }
        }

        bindObservers()
        refreshVisibilityAndFrames()
    }

    func isWidgetEnabled(_ kind: DesktopWidgetKind) -> Bool {
        enabledKinds.contains(kind)
    }

    func setWidgetEnabled(_ kind: DesktopWidgetKind, enabled: Bool) {
        var updated = enabledKinds
        if enabled {
            updated.insert(kind)
        } else {
            updated.remove(kind)
        }
        guard updated != enabledKinds else { return }
        enabledKinds = updated
        persistEnabledKinds()
        refreshVisibilityAndFrames()
    }

    func toggleAllWidgetsVisibility() {
        if enabledKinds.isEmpty {
            enabledKinds = lastNonEmptyKinds.isEmpty ? Self.defaultEnabledKinds : lastNonEmptyKinds
        } else {
            lastNonEmptyKinds = enabledKinds
            persistLastNonEmptyKinds()
            enabledKinds = []
        }
        persistEnabledKinds()
        refreshVisibilityAndFrames()
    }

    func sizePreset(for kind: DesktopWidgetKind) -> WidgetSizePreset {
        sizePresets[kind] ?? .standard
    }

    func setSizePreset(_ preset: WidgetSizePreset, for kind: DesktopWidgetKind) {
        guard sizePreset(for: kind) != preset else { return }
        objectWillChange.send()
        sizePresets[kind] = preset
        settings.defaults.set(preset.rawValue, forKey: Keys.sizePreset(kind))
        refreshVisibilityAndFrames()
    }

    func resetAllPositions() {
        let defaults = settings.defaults
        for kind in DesktopWidgetKind.allCases {
            defaults.removeObject(forKey: Keys.normX(kind))
            defaults.removeObject(forKey: Keys.normY(kind))
        }

        let vf = currentVisibleFrame()
        for kind in DesktopWidgetKind.allCases {
            let size = kind.size(for: sizePreset(for: kind))
            let defFrame = WidgetLayoutMath.defaultFrame(
                for: kind,
                size: size,
                in: vf,
                presetLookup: { [weak self] k in self?.sizePreset(for: k) ?? .standard }
            )
            storeNormalizedOrigin(WidgetLayoutMath.normalizedOrigin(for: defFrame, in: vf), for: kind)
        }
        refreshVisibilityAndFrames()
    }

    func refreshVisibilityAndFrames() {
        guard createPanels else { return }

        let vf = currentVisibleFrame()
        for kind in DesktopWidgetKind.allCases {
            if enabledKinds.contains(kind) {
                let targetFrame = resolvedFrame(for: kind, in: vf)
                let panel = ensurePanel(for: kind, initialFrame: targetFrame)
                panel.applyLockState(settings.widgetsLocked)
                panel.applyTheme(settings.themeMode)
                if panel.frame != targetFrame {
                    panel.setFrame(targetFrame, display: true)
                }
                panel.refreshVisualState()
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                }
            } else if let existing = panels[kind], existing.isVisible {
                existing.orderOut(nil)
            }
        }
    }

    func activePanel(for kind: DesktopWidgetKind) -> DesktopWidgetPanel? {
        panels[kind]
    }

    // MARK: - Private Helpers

    private func bindObservers() {
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for panel in self.panels.values {
                    panel.applyLockState(self.settings.widgetsLocked)
                    panel.applyTheme(self.settings.themeMode)
                    panel.refreshVisualState()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshVisibilityAndFrames()
            }
            .store(in: &cancellables)
    }

    private func ensurePanel(for kind: DesktopWidgetKind, initialFrame: CGRect) -> DesktopWidgetPanel {
        if let existing = panels[kind] {
            return existing
        }
        let panel = DesktopWidgetPanel(
            kind: kind,
            initialFrame: initialFrame,
            engine: engine,
            settings: settings,
            manager: self
        )
        panel.onFrameCommitted = { [weak self, weak panel] committedFrame in
            guard let self else { return }
            let vf = (panel?.screen ?? NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
                ?? self.currentVisibleFrame()
            let norm = WidgetLayoutMath.normalizedOrigin(for: committedFrame, in: vf)
            self.storeNormalizedOrigin(norm, for: kind)
        }
        panels[kind] = panel
        return panel
    }

    private func resolvedFrame(for kind: DesktopWidgetKind, in visibleFrame: CGRect) -> CGRect {
        let size = kind.size(for: sizePreset(for: kind))
        if let storedNorm = loadNormalizedOrigin(for: kind) {
            return WidgetLayoutMath.resolvedFrame(
                normalizedOrigin: storedNorm,
                size: size,
                visibleFrame: visibleFrame
            )
        }

        let defFrame = WidgetLayoutMath.defaultFrame(
            for: kind,
            size: size,
            in: visibleFrame,
            presetLookup: { [weak self] k in self?.sizePreset(for: k) ?? .standard }
        )
        storeNormalizedOrigin(
            WidgetLayoutMath.normalizedOrigin(for: defFrame, in: visibleFrame),
            for: kind
        )
        return defFrame
    }

    private func loadNormalizedOrigin(for kind: DesktopWidgetKind) -> CGPoint? {
        let defaults = settings.defaults
        guard defaults.object(forKey: Keys.normX(kind)) != nil,
              defaults.object(forKey: Keys.normY(kind)) != nil else {
            return nil
        }
        let x = defaults.double(forKey: Keys.normX(kind))
        let y = defaults.double(forKey: Keys.normY(kind))
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func storeNormalizedOrigin(_ origin: CGPoint, for kind: DesktopWidgetKind) {
        settings.defaults.set(Double(origin.x), forKey: Keys.normX(kind))
        settings.defaults.set(Double(origin.y), forKey: Keys.normY(kind))
    }

    private func persistEnabledKinds() {
        let orderedRaw = DesktopWidgetKind.allCases
            .filter { enabledKinds.contains($0) }
            .map(\.rawValue)
        settings.defaults.set(orderedRaw, forKey: Keys.enabledKinds)
        if !enabledKinds.isEmpty {
            lastNonEmptyKinds = enabledKinds
            persistLastNonEmptyKinds()
        }
    }

    private func persistLastNonEmptyKinds() {
        let orderedRaw = DesktopWidgetKind.allCases
            .filter { lastNonEmptyKinds.contains($0) }
            .map(\.rawValue)
        settings.defaults.set(orderedRaw, forKey: Keys.lastNonEmptyKinds)
    }

    private func currentVisibleFrame() -> CGRect {
        if let vf = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame,
           vf.width > 0, vf.height > 0 {
            return vf
        }
        return CGRect(x: 0, y: 0, width: 2560, height: 1575)
    }
}
