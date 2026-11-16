import AppKit
import Combine
import CoreGraphics
import CoreWLAN
import Darwin
import Foundation

private final class EngineCleanupBox: @unchecked Sendable {
    let bridgeCtx: OpaquePointer?
    var tokens: [NSObjectProtocol] = []

    init(bridgeCtx: OpaquePointer?) {
        self.bridgeCtx = bridgeCtx
    }
}

@MainActor
final class TelemetryEngine: ObservableObject {
    static let historyCapacity = 60
    private static let ambientInterval: TimeInterval = 2.0
    private static let interactiveInterval: TimeInterval = 1.0
    private static let smartRefreshSeconds: TimeInterval = 30.0
    private static let volumeRefreshSeconds: TimeInterval = 30.0
    private static let ambientWifiRefreshSeconds: TimeInterval = 60.0

    @Published private(set) var snapshot: SystemSnapshot = .empty
    private(set) var cpuHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var gpuHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var ramHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var powerHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var netRxHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var netTxHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var diskReadHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    private(set) var diskWriteHistory = FixedRingBuffer<Double>(capacity: historyCapacity, repeating: 0)
    @Published private(set) var currentInterval: TimeInterval = ambientInterval
    var requiresFastAmbientIoNet: (() -> Bool)?

    private nonisolated let cleanupBox: EngineCleanupBox
    private var bridgeCtx: OpaquePointer? { cleanupBox.bridgeCtx }

    private let autoStart: Bool
    private var timer: Timer?
    private var interactiveTokens: Set<UUID> = []
    private var isSystemSleeping = false
    private var isScreenSleeping = false

    private var hasSampledOnce = false
    private var lastSmartRefreshUptime: TimeInterval = 0
    private var lastVolumeRefreshUptime: TimeInterval = 0
    private var lastWifiRefreshUptime: TimeInterval = 0
    private var lastIoNetRefreshUptime: TimeInterval = 0

    private var cachedVolumeTotalBytes: UInt64 = 0
    private var cachedVolumeAvailableBytes: UInt64 = 0
    private var cachedWifi: WifiSnapshot = .empty
    private var procScratch = [XSProcessEntry](repeating: XSProcessEntry(), count: 30)

    init(autoStart: Bool = true) {
        self.autoStart = autoStart
        let createdCtx = xs_bridge_create()
        self.cleanupBox = EngineCleanupBox(bridgeCtx: createdCtx)

        if let wifiIf = CWWiFiClient.shared().interface()?.interfaceName,
           !wifiIf.isEmpty,
           let ctx = createdCtx {
            wifiIf.withCString { xs_bridge_set_preferred_net_if(ctx, $0) }
        }

        if autoStart {
            registerWorkspaceObservers()
            refreshNow()
            applySchedule(triggerImmediateSample: false)
        } else {
            currentInterval = Self.ambientInterval
        }
    }

    deinit {
        let tokens = cleanupBox.tokens
        if !tokens.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for token in tokens {
                center.removeObserver(token)
            }
        }
        if let ctx = cleanupBox.bridgeCtx {
            xs_bridge_destroy(ctx)
        }
    }

    func beginInteractiveSession() -> UUID {
        let wasEmpty = interactiveTokens.isEmpty
        let token = UUID()
        interactiveTokens.insert(token)
        applySchedule(triggerImmediateSample: autoStart && wasEmpty && !isSuspended)
        return token
    }

    func endInteractiveSession(_ token: UUID) {
        guard interactiveTokens.remove(token) != nil else { return }
        applySchedule(triggerImmediateSample: false)
    }

    func handleSleep() {
        isSystemSleeping = true
        applySchedule(triggerImmediateSample: false)
    }

    func handleWake() {
        isSystemSleeping = false
        if isScreenSleeping && CGDisplayIsAsleep(CGMainDisplayID()) == 0 {
            isScreenSleeping = false
        }
        resetBaselinesForWake()
        applySchedule(triggerImmediateSample: autoStart && !isSuspended)
    }

    private func handleScreenSleep() {
        isScreenSleeping = true
        applySchedule(triggerImmediateSample: false)
    }

    private func handleScreenWake() {
        isScreenSleeping = false
        isSystemSleeping = false
        resetBaselinesForWake()
        applySchedule(triggerImmediateSample: autoStart)
    }

    private var isSuspended: Bool {
        isSystemSleeping || isScreenSleeping
    }

    private func resetBaselinesForWake() {
        if let bridgeCtx {
            xs_bridge_reset_baselines(bridgeCtx)
        }
        lastSmartRefreshUptime = 0
        lastVolumeRefreshUptime = 0
        lastWifiRefreshUptime = 0
        lastIoNetRefreshUptime = 0
    }

    private func applySchedule(triggerImmediateSample: Bool) {
        let target: TimeInterval
        if isSuspended {
            target = 0.0
        } else if !interactiveTokens.isEmpty {
            target = Self.interactiveInterval
        } else {
            target = Self.ambientInterval
        }

        let intervalChanged = (currentInterval != target)
        currentInterval = target

        guard autoStart else {
            invalidateTimer()
            return
        }

        if target <= 0.0 {
            invalidateTimer()
            return
        }

        if triggerImmediateSample {
            refreshNow()
        }

        if intervalChanged || timer == nil {
            invalidateTimer()
            let newTimer = Timer(timeInterval: target, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshNow()
                }
            }
            newTimer.tolerance = target * 0.15
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        cleanupBox.tokens.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleSleep() }
            }
        )
        cleanupBox.tokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleWake() }
            }
        )
        cleanupBox.tokens.append(
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleScreenSleep() }
            }
        )
        cleanupBox.tokens.append(
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleScreenWake() }
            }
        )
    }

    func refreshNow() {
        let uptime = Self.systemUptimeSeconds()
        let isInteractive = !interactiveTokens.isEmpty

        let shouldRefreshWifi = !hasSampledOnce ||
            isInteractive ||
            (uptime - lastWifiRefreshUptime >= Self.ambientWifiRefreshSeconds)
        if shouldRefreshWifi {
            let queryIdentity = !hasSampledOnce || isInteractive || (cachedWifi.ssid != nil) || !cachedWifi.isAssociated
            cachedWifi = Self.sampleWifi(queryIdentity: queryIdentity, previous: cachedWifi)
            lastWifiRefreshUptime = uptime
            if !cachedWifi.interfaceName.isEmpty, let bridgeCtx {
                cachedWifi.interfaceName.withCString { xs_bridge_set_preferred_net_if(bridgeCtx, $0) }
            }
        }

        let shouldRefreshVolume = !hasSampledOnce ||
            (uptime - lastVolumeRefreshUptime >= Self.volumeRefreshSeconds)
        if shouldRefreshVolume {
            let cap = Self.sampleRootVolumeCapacity()
            cachedVolumeTotalBytes = cap.total
            cachedVolumeAvailableBytes = cap.available
            lastVolumeRefreshUptime = uptime
        }

        let shouldRefreshSmart = !hasSampledOnce ||
            (uptime - lastSmartRefreshUptime >= Self.smartRefreshSeconds)
        if shouldRefreshSmart {
            lastSmartRefreshUptime = uptime
        }

        var cCpu = XSCpuMetrics()
        var cGpu = XSGpuMetrics()
        var cMem = XSMemoryMetrics()
        var cPwr = XSPowerMetrics()
        var cSto = XSStorageMetrics()
        var cNet = XSNetworkMetrics()

        let shouldRefreshIoNet = !hasSampledOnce ||
            isInteractive ||
            shouldRefreshSmart ||
            (requiresFastAmbientIoNet?() ?? true) ||
            (uptime - lastIoNetRefreshUptime >= 6.0)

        if let bridgeCtx {
            xs_bridge_sample_core(bridgeCtx, &cCpu, &cGpu, &cMem, &cPwr)
            if shouldRefreshIoNet {
                xs_bridge_sample_io_net(bridgeCtx, shouldRefreshSmart, &cSto, &cNet)
                lastIoNetRefreshUptime = uptime
            }
        }

        var procs: [ProcessEntry] = snapshot.topProcesses
        var allUsers: Bool = snapshot.isAllUsersProcessList
        if isInteractive, let bridgeCtx {
            var rawAllUsers = false
            let count = Int(xs_bridge_sample_processes(
                bridgeCtx, &procScratch, UInt32(procScratch.count), &rawAllUsers))
            procs = procScratch.prefix(count).map(ProcessEntry.init(c:))
            allUsers = rawAllUsers
        }

        let cpuSnap = CpuSnapshot(c: cCpu)
        let gpuSnap = GpuSnapshot(c: cGpu)
        let memSnap = MemorySnapshot(c: cMem)
        let stoSnap: StorageSnapshot
        let netSnap: NetworkSnapshot
        if shouldRefreshIoNet {
            stoSnap = StorageSnapshot(
                c: cSto,
                totalBytes: cachedVolumeTotalBytes,
                availableBytes: cachedVolumeAvailableBytes
            )
            netSnap = NetworkSnapshot(c: cNet)
        } else {
            var reusedSto = snapshot.storage
            reusedSto.totalBytes = cachedVolumeTotalBytes
            reusedSto.availableBytes = cachedVolumeAvailableBytes
            stoSnap = reusedSto
            netSnap = snapshot.network
        }
        let pwrSnap = PowerSnapshot(c: cPwr)

        cpuHistory.append(cpuSnap.totalUsage)
        gpuHistory.append(gpuSnap.usagePct)
        ramHistory.append(memSnap.usedPercent)
        powerHistory.append(cpuSnap.packagePowerW)
        netRxHistory.append(Double(netSnap.rxBytesPerSec))
        netTxHistory.append(Double(netSnap.txBytesPerSec))
        diskReadHistory.append(Double(stoSnap.readBytesPerSec))
        diskWriteHistory.append(Double(stoSnap.writeBytesPerSec))

        snapshot = SystemSnapshot(
            cpu: cpuSnap,
            gpu: gpuSnap,
            memory: memSnap,
            storage: stoSnap,
            power: pwrSnap,
            network: netSnap,
            wifi: cachedWifi,
            topProcesses: procs,
            isAllUsersProcessList: allUsers,
            uptimeSeconds: uptime,
            timestamp: Date()
        )

        hasSampledOnce = true
    }

    private static func systemUptimeSeconds() -> TimeInterval {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        if sysctl(&mib, 2, &boottime, &size, nil, 0) == 0, boottime.tv_sec > 0 {
            let now = Date().timeIntervalSince1970
            let boot = TimeInterval(boottime.tv_sec) + TimeInterval(boottime.tv_usec) / 1_000_000.0
            if now > boot {
                return now - boot
            }
        }
        return ProcessInfo.processInfo.systemUptime
    }

    private static func sampleRootVolumeCapacity() -> (total: UInt64, available: UInt64) {
        let rootURL = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let vals = try? rootURL.resourceValues(forKeys: keys) else {
            return (0, 0)
        }
        let total = UInt64(max(0, vals.volumeTotalCapacity ?? 0))
        let avail: UInt64
        if let important = vals.volumeAvailableCapacityForImportantUsage, important > 0 {
            avail = UInt64(important)
        } else {
            avail = UInt64(max(0, vals.volumeAvailableCapacity ?? 0))
        }
        return (total, min(avail, total))
    }

    private static func sampleWifi(queryIdentity: Bool = true, previous: WifiSnapshot = .empty) -> WifiSnapshot {
        guard let iface = CWWiFiClient.shared().interface() else {
            return .empty
        }
        let ifName = iface.interfaceName ?? "en1"
        let powered = iface.powerOn()
        let rawSSID = queryIdentity ? iface.ssid() : previous.ssid
        let rawBSSID = queryIdentity ? iface.bssid() : previous.bssid
        let channel = iface.wlanChannel()
        let rssi = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let txRate = iface.transmitRate()
        let phy = iface.activePHYMode()

        // On macOS Sonoma/Sequoia, ssid()/bssid() return nil without Location Services
        // even when actively associated; detect association via channel / PHY / link metrics.
        let associated = powered && (
            rawSSID != nil ||
            channel != nil ||
            phy != .modeNone ||
            txRate > 0 ||
            rssi < 0
        )

        let chNum = channel?.channelNumber ?? 0
        let chBand: String
        if let band = channel?.channelBand {
            switch band {
            case .band2GHz: chBand = "2.4 GHz"
            case .band5GHz: chBand = "5 GHz"
            case .band6GHz: chBand = "6 GHz"
            case .bandUnknown: chBand = "—"
            @unknown default: chBand = "—"
            }
        } else {
            chBand = "—"
        }

        let chWidth: Int
        if let width = channel?.channelWidth {
            switch width {
            case .width20MHz: chWidth = 20
            case .width40MHz: chWidth = 40
            case .width80MHz: chWidth = 80
            case .width160MHz: chWidth = 160
            case .widthUnknown: chWidth = 0
            @unknown default: chWidth = 0
            }
        } else {
            chWidth = 0
        }

        let phyLabel: String
        switch phy {
        case .modeNone: phyLabel = "—"
        case .mode11a: phyLabel = "802.11a"
        case .mode11b: phyLabel = "802.11b"
        case .mode11g: phyLabel = "802.11g"
        case .mode11n: phyLabel = "802.11n"
        case .mode11ac: phyLabel = "802.11ac"
        case .mode11ax: phyLabel = "802.11ax"
        @unknown default:
            phyLabel = phy.rawValue == 7 ? "802.11be" : "802.11"
        }

        let secLabel = associated ? describeSecurity(iface.security()) : "—"
        let snr = (associated && rssi != 0 && noise != 0) ? (rssi - noise) : 0

        return WifiSnapshot(
            isPresent: true,
            isPoweredOn: powered,
            isAssociated: associated,
            interfaceName: ifName,
            ssid: rawSSID,
            bssid: rawBSSID,
            phyMode: phyLabel,
            security: secLabel,
            channelNumber: chNum,
            channelBand: chBand,
            channelWidthMHz: chWidth,
            rssi: associated ? rssi : 0,
            noise: associated ? noise : 0,
            snr: snr,
            txRateMbps: associated ? txRate : 0
        )
    }

    private static func describeSecurity(_ sec: CWSecurity) -> String {
        switch sec {
        case .none: return "Open"
        case .WEP: return "WEP"
        case .wpaPersonal: return "WPA Personal"
        case .wpaPersonalMixed: return "WPA/WPA2 Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "WPA Personal"
        case .dynamicWEP: return "Dynamic WEP"
        case .wpaEnterprise: return "WPA Enterprise"
        case .wpaEnterpriseMixed: return "WPA/WPA2 Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "WPA Enterprise"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .OWE: return "OWE"
        case .oweTransition: return "OWE Transition"
        case .unknown: return "—"
        @unknown default: return "WPA"
        }
    }
}
