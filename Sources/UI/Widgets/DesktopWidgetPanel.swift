import AppKit
import Combine
import CoreGraphics
import SwiftUI

private final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class WidgetRootContainerNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class DesktopWidgetPanel: NSPanel {
    let kind: DesktopWidgetKind
    var onFrameCommitted: ((CGRect) -> Void)?

    private var isTrackingMouse = false
    private var isDraggingPanel = false
    private var dragStartMouseScreen: CGPoint = .zero
    private var dragStartFrameOrigin: CGPoint = .zero

    private var effectView: NSVisualEffectView?
    private var canvasView: WidgetCardCanvasNSView?
    private var editOverlayHost: NSView?
    private weak var boundEngine: TelemetryEngine?
    private weak var boundSettings: SettingsStore?
    private weak var boundManager: DesktopWidgetManager?
    private var cancellables: Set<AnyCancellable> = []

    static var wallpaperAboveIconsLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    init(
        kind: DesktopWidgetKind,
        initialFrame: CGRect,
        engine: TelemetryEngine,
        settings: SettingsStore,
        manager: DesktopWidgetManager
    ) {
        self.kind = kind
        self.boundEngine = engine
        self.boundSettings = settings
        self.boundManager = manager
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindowCommon(locked: settings.widgetsLocked, themeMode: settings.themeMode)

        let boundsRect = CGRect(origin: .zero, size: initialFrame.size)
        let container = WidgetRootContainerNSView(frame: boundsRect)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        let vfx = NSVisualEffectView(frame: boundsRect)
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.isEmphasized = false
        vfx.autoresizingMask = [.width, .height]
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = 16.0
        vfx.layer?.cornerCurve = .continuous
        vfx.layer?.masksToBounds = true
        container.addSubview(vfx)
        self.effectView = vfx

        let canvas = WidgetCardCanvasNSView(kind: kind, frame: boundsRect)
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        self.canvasView = canvas

        self.contentView = container

        syncVisualEffectMaterial(settings: settings)
        syncEditOverlay(locked: settings.widgetsLocked)
        canvas.updateContent(
            preset: manager.sizePreset(for: kind),
            opacity: settings.widgetOpacity,
            snapshot: engine.snapshot,
            engine: engine,
            force: true
        )

        engine.$snapshot
            .sink { [weak self] newSnap in
                guard let self,
                      let engine = self.boundEngine,
                      let settings = self.boundSettings,
                      let manager = self.boundManager else { return }
                self.canvasView?.updateContent(
                    preset: manager.sizePreset(for: self.kind),
                    opacity: settings.widgetOpacity,
                    snapshot: newSnap,
                    engine: engine
                )
            }
            .store(in: &cancellables)
    }

    init<Content: View>(
        kind: DesktopWidgetKind,
        initialFrame: CGRect,
        locked: Bool,
        themeMode: AppThemeMode,
        rootView: Content
    ) {
        self.kind = kind
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindowCommon(locked: locked, themeMode: themeMode)

        let hostingView = WidgetHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
    }

    private func configureWindowCommon(locked: Bool, themeMode: AppThemeMode) {
        isFloatingPanel = false
        level = Self.wallpaperAboveIconsLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        applyLockState(locked)
        applyTheme(themeMode)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyLockState(_ locked: Bool) {
        ignoresMouseEvents = locked
        if locked {
            isTrackingMouse = false
            isDraggingPanel = false
        }
        syncEditOverlay(locked: locked)
    }

    func applyTheme(_ themeMode: AppThemeMode) {
        switch themeMode {
        case .system:
            appearance = nil
        case .darkGraphite:
            appearance = NSAppearance(named: .darkAqua)
        case .lightFrost:
            appearance = NSAppearance(named: .aqua)
        }
        if let settings = boundSettings {
            syncVisualEffectMaterial(settings: settings)
        }
        if let engine = boundEngine, let settings = boundSettings, let manager = boundManager {
            canvasView?.updateContent(
                preset: manager.sizePreset(for: kind),
                opacity: settings.widgetOpacity,
                snapshot: engine.snapshot,
                engine: engine,
                force: true
            )
        }
    }

    func refreshVisualState() {
        guard let engine = boundEngine,
              let settings = boundSettings,
              let manager = boundManager else { return }
        syncVisualEffectMaterial(settings: settings)
        canvasView?.updateContent(
            preset: manager.sizePreset(for: kind),
            opacity: settings.widgetOpacity,
            snapshot: engine.snapshot,
            engine: engine,
            force: true
        )
    }

    private func syncVisualEffectMaterial(settings: SettingsStore) {
        guard let vfx = effectView else { return }
        let isDark: Bool
        switch settings.themeMode {
        case .darkGraphite:
            isDark = true
        case .lightFrost:
            isDark = false
        case .system:
            let appEff = NSApp?.effectiveAppearance
            isDark = appEff?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let targetMaterial: NSVisualEffectView.Material = isDark ? .hudWindow : .underWindowBackground
        if vfx.material != targetMaterial {
            vfx.material = targetMaterial
        }
        let targetAlpha = CGFloat(min(1.0, max(0.3, settings.widgetOpacity)))
        if abs(vfx.alphaValue - targetAlpha) > 0.001 {
            vfx.alphaValue = targetAlpha
        }
    }

    private func syncEditOverlay(locked: Bool) {
        guard let container = contentView,
              let settings = boundSettings,
              let manager = boundManager else { return }
        if locked {
            editOverlayHost?.removeFromSuperview()
            editOverlayHost = nil
        } else if editOverlayHost == nil {
            let overlayView = DesktopWidgetEditOverlayView(
                kind: kind,
                settings: settings,
                manager: manager
            )
            let host = WidgetHostingView(rootView: overlayView)
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            editOverlayHost = host
        }
    }

    override func sendEvent(_ event: NSEvent) {
        guard !ignoresMouseEvents else {
            super.sendEvent(event)
            return
        }

        switch event.type {
        case .leftMouseDown:
            isTrackingMouse = true
            isDraggingPanel = false
            dragStartMouseScreen = NSEvent.mouseLocation
            dragStartFrameOrigin = frame.origin
            super.sendEvent(event)

        case .leftMouseDragged:
            guard isTrackingMouse else {
                super.sendEvent(event)
                return
            }
            let currentMouse = NSEvent.mouseLocation
            let dx = currentMouse.x - dragStartMouseScreen.x
            let dy = currentMouse.y - dragStartMouseScreen.y

            if !isDraggingPanel && hypot(dx, dy) >= 4.0 {
                isDraggingPanel = true
            }

            if isDraggingPanel {
                let rawOrigin = CGPoint(
                    x: dragStartFrameOrigin.x + dx,
                    y: dragStartFrameOrigin.y + dy
                )
                if let vf = activeVisibleFrame {
                    let snapped = WidgetLayoutMath.snappedAndClampedFrame(
                        origin: rawOrigin,
                        size: frame.size,
                        visibleFrame: vf,
                        step: WidgetLayoutMath.defaultGridStep
                    )
                    setFrameOrigin(snapped.origin)
                } else {
                    let snapped = WidgetLayoutMath.snapToGrid(rawOrigin, step: WidgetLayoutMath.defaultGridStep)
                    setFrameOrigin(snapped)
                }
            } else {
                super.sendEvent(event)
            }

        case .leftMouseUp:
            let wasDragging = isDraggingPanel
            isTrackingMouse = false
            isDraggingPanel = false

            if wasDragging {
                if let cancelUp = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: NSPoint(x: -1000, y: -1000),
                    modifierFlags: event.modifierFlags,
                    timestamp: event.timestamp,
                    windowNumber: windowNumber,
                    context: nil,
                    eventNumber: event.eventNumber,
                    clickCount: 0,
                    pressure: 0
                ) {
                    super.sendEvent(cancelUp)
                }
                onFrameCommitted?(frame)
            } else {
                super.sendEvent(event)
            }

        default:
            super.sendEvent(event)
        }
    }

    private var activeVisibleFrame: CGRect? {
        (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
    }
}
