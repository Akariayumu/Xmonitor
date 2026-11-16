import Foundation

func decodeFixedCString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { rawBuffer in
        let slice = rawBuffer.prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }
}

private func decodeFixedDoubles<T>(_ tuple: T, count: Int) -> [Double] {
    guard count > 0 else { return [] }
    return withUnsafeBytes(of: tuple) { rawBuffer in
        let typed = rawBuffer.bindMemory(to: Double.self)
        let n = min(count, typed.count)
        return Array(typed.prefix(n))
    }
}

struct CpuSnapshot: Codable, Equatable, Sendable {
    var totalUsage: Double
    var userUsage: Double
    var sysUsage: Double
    var threadUsage: [Double]
    var threadFreqMHz: [Double]
    var threadCount: Int
    var avgFreqMHz: Double
    var maxFreqMHz: Double
    var packagePowerW: Double
    var corePowerW: Double
    var pkgCStatePct: Double
    var hasTemp: Bool
    var packageTempC: Double
    var coreTempC: [Double]
    var loadAvg: [Double]

    static let empty = CpuSnapshot(
        totalUsage: 0,
        userUsage: 0,
        sysUsage: 0,
        threadUsage: [],
        threadFreqMHz: [],
        threadCount: 0,
        avgFreqMHz: 0,
        maxFreqMHz: 0,
        packagePowerW: 0,
        corePowerW: 0,
        pkgCStatePct: 0,
        hasTemp: false,
        packageTempC: 0,
        coreTempC: [],
        loadAvg: [0, 0, 0]
    )

    init(
        totalUsage: Double,
        userUsage: Double,
        sysUsage: Double,
        threadUsage: [Double],
        threadFreqMHz: [Double],
        threadCount: Int,
        avgFreqMHz: Double,
        maxFreqMHz: Double,
        packagePowerW: Double,
        corePowerW: Double,
        pkgCStatePct: Double,
        hasTemp: Bool,
        packageTempC: Double,
        coreTempC: [Double],
        loadAvg: [Double]
    ) {
        self.totalUsage = totalUsage
        self.userUsage = userUsage
        self.sysUsage = sysUsage
        self.threadUsage = threadUsage
        self.threadFreqMHz = threadFreqMHz
        self.threadCount = threadCount
        self.avgFreqMHz = avgFreqMHz
        self.maxFreqMHz = maxFreqMHz
        self.packagePowerW = packagePowerW
        self.corePowerW = corePowerW
        self.pkgCStatePct = pkgCStatePct
        self.hasTemp = hasTemp
        self.packageTempC = packageTempC
        self.coreTempC = coreTempC
        self.loadAvg = loadAvg
    }

    init(c: XSCpuMetrics) {
        let count = Int(min(c.threadCount, 16))
        let tempCount = Int(min(c.coreTempCount, 8))
        self.totalUsage = c.totalUsage
        self.userUsage = c.userUsage
        self.sysUsage = c.sysUsage
        self.threadUsage = decodeFixedDoubles(c.threadUsage, count: count)
        self.threadFreqMHz = decodeFixedDoubles(c.threadFreqMHz, count: count)
        self.threadCount = count
        self.avgFreqMHz = c.avgFreqMHz
        self.maxFreqMHz = c.maxFreqMHz
        self.packagePowerW = c.packagePowerW
        self.corePowerW = c.corePowerW
        self.pkgCStatePct = c.pkgCStatePct
        self.hasTemp = c.hasTemp
        self.packageTempC = c.packageTempC
        self.coreTempC = decodeFixedDoubles(c.coreTempC, count: tempCount)
        self.loadAvg = decodeFixedDoubles(c.loadAvg, count: 3)
    }
}

struct GpuSnapshot: Codable, Equatable, Sendable {
    var usagePct: Double
    var rc6Pct: Double
    var powerW: Double
    var hasFreq: Bool
    var currentFreqMHz: UInt32
    var requestedFreqMHz: UInt32
    var gartUsedBytes: UInt64
    var gartSizeBytes: UInt64
    var sinkRestoreOk: UInt32
    var sinkRestoreRetries: UInt32

    var gartUsedPercent: Double {
        gartSizeBytes > 0 ? (Double(gartUsedBytes) / Double(gartSizeBytes)) * 100.0 : 0.0
    }

    static let empty = GpuSnapshot(
        usagePct: 0,
        rc6Pct: 0,
        powerW: 0,
        hasFreq: false,
        currentFreqMHz: 0,
        requestedFreqMHz: 0,
        gartUsedBytes: 0,
        gartSizeBytes: 0,
        sinkRestoreOk: 0,
        sinkRestoreRetries: 0
    )

    init(
        usagePct: Double,
        rc6Pct: Double,
        powerW: Double,
        hasFreq: Bool,
        currentFreqMHz: UInt32,
        requestedFreqMHz: UInt32,
        gartUsedBytes: UInt64,
        gartSizeBytes: UInt64,
        sinkRestoreOk: UInt32,
        sinkRestoreRetries: UInt32
    ) {
        self.usagePct = usagePct
        self.rc6Pct = rc6Pct
        self.powerW = powerW
        self.hasFreq = hasFreq
        self.currentFreqMHz = currentFreqMHz
        self.requestedFreqMHz = requestedFreqMHz
        self.gartUsedBytes = gartUsedBytes
        self.gartSizeBytes = gartSizeBytes
        self.sinkRestoreOk = sinkRestoreOk
        self.sinkRestoreRetries = sinkRestoreRetries
    }

    init(c: XSGpuMetrics) {
        self.usagePct = c.usagePct
        self.rc6Pct = c.rc6Pct
        self.powerW = c.powerW
        self.hasFreq = c.hasFreq
        self.currentFreqMHz = c.currentFreqMHz
        self.requestedFreqMHz = c.requestedFreqMHz
        self.gartUsedBytes = c.gartUsedBytes
        self.gartSizeBytes = c.gartSizeBytes
        self.sinkRestoreOk = c.sinkRestoreOk
        self.sinkRestoreRetries = c.sinkRestoreRetries
    }
}

struct MemorySnapshot: Codable, Equatable, Sendable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var pressureLevel: Int32

    var usedPercent: Double {
        totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) * 100.0 : 0.0
    }

    var availableBytes: UInt64 {
        totalBytes > usedBytes ? (totalBytes - usedBytes) : 0
    }

    static let empty = MemorySnapshot(
        totalBytes: 0,
        usedBytes: 0,
        appBytes: 0,
        wiredBytes: 0,
        compressedBytes: 0,
        cachedBytes: 0,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        pressureLevel: 1
    )

    init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pressureLevel: Int32
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressureLevel = pressureLevel
    }

    init(c: XSMemoryMetrics) {
        self.totalBytes = c.totalBytes
        self.usedBytes = c.usedBytes
        self.appBytes = c.appBytes
        self.wiredBytes = c.wiredBytes
        self.compressedBytes = c.compressedBytes
        self.cachedBytes = c.cachedBytes
        self.swapUsedBytes = c.swapUsedBytes
        self.swapTotalBytes = c.swapTotalBytes
        self.pressureLevel = c.pressureLevel
    }
}

struct StorageSnapshot: Codable, Equatable, Sendable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var availableBytes: UInt64
    var readBytesPerSec: UInt64
    var writeBytesPerSec: UInt64
    var readIOPS: Double
    var writeIOPS: Double
    var hasSmart: Bool
    var tempC: Int32
    var lifeUsedPct: Int32
    var availableSparePct: Int32
    var dataReadTB: Double
    var dataWrittenTB: Double
    var powerOnHours: UInt64
    var powerCycles: UInt64
    var unsafeShutdowns: UInt64
    var model: String

    var usedPercent: Double {
        totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) * 100.0 : 0.0
    }

    static let empty = StorageSnapshot(
        totalBytes: 0,
        usedBytes: 0,
        availableBytes: 0,
        readBytesPerSec: 0,
        writeBytesPerSec: 0,
        readIOPS: 0,
        writeIOPS: 0,
        hasSmart: false,
        tempC: 0,
        lifeUsedPct: 0,
        availableSparePct: 0,
        dataReadTB: 0,
        dataWrittenTB: 0,
        powerOnHours: 0,
        powerCycles: 0,
        unsafeShutdowns: 0,
        model: ""
    )

    init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        availableBytes: UInt64,
        readBytesPerSec: UInt64,
        writeBytesPerSec: UInt64,
        readIOPS: Double,
        writeIOPS: Double,
        hasSmart: Bool,
        tempC: Int32,
        lifeUsedPct: Int32,
        availableSparePct: Int32,
        dataReadTB: Double,
        dataWrittenTB: Double,
        powerOnHours: UInt64,
        powerCycles: UInt64,
        unsafeShutdowns: UInt64,
        model: String
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
        self.readIOPS = readIOPS
        self.writeIOPS = writeIOPS
        self.hasSmart = hasSmart
        self.tempC = tempC
        self.lifeUsedPct = lifeUsedPct
        self.availableSparePct = availableSparePct
        self.dataReadTB = dataReadTB
        self.dataWrittenTB = dataWrittenTB
        self.powerOnHours = powerOnHours
        self.powerCycles = powerCycles
        self.unsafeShutdowns = unsafeShutdowns
        self.model = model
    }

    init(c: XSStorageMetrics, totalBytes: UInt64, availableBytes: UInt64) {
        let clampedAvail = min(availableBytes, totalBytes)
        self.totalBytes = totalBytes
        self.availableBytes = clampedAvail
        self.usedBytes = totalBytes >= clampedAvail ? (totalBytes - clampedAvail) : 0
        self.readBytesPerSec = c.readBytesPerSec
        self.writeBytesPerSec = c.writeBytesPerSec
        self.readIOPS = c.readIOPS
        self.writeIOPS = c.writeIOPS
        self.hasSmart = c.hasSmart
        self.tempC = c.tempC
        self.lifeUsedPct = c.lifeUsedPct
        self.availableSparePct = c.availableSparePct
        self.dataReadTB = c.dataReadTB
        self.dataWrittenTB = c.dataWrittenTB
        self.powerOnHours = c.powerOnHours
        self.powerCycles = c.powerCycles
        self.unsafeShutdowns = c.unsafeShutdowns
        self.model = decodeFixedCString(c.model)
    }
}

struct PowerSnapshot: Codable, Equatable, Sendable {
    var present: Bool
    var isPluggedIn: Bool
    var isCharging: Bool
    var isFullyCharged: Bool
    var percentage: Double
    var batteryWatts: Double
    var healthPct: Double
    var voltageMV: Int32
    var amperageMA: Int32
    var cycleCount: Int32
    var hasS0ix: Bool
    var sleepCount: UInt32
    var lastSleepType: UInt32
    var lastCC7Pct: UInt32
    var lastPC8Pct: UInt32
    var lastDC9: Bool
    var lastWakeSource: String
    var acEcWakeBlock: String
    var batteryFullState: String

    static let empty = PowerSnapshot(
        present: false,
        isPluggedIn: false,
        isCharging: false,
        isFullyCharged: false,
        percentage: 0,
        batteryWatts: 0,
        healthPct: 0,
        voltageMV: 0,
        amperageMA: 0,
        cycleCount: 0,
        hasS0ix: false,
        sleepCount: 0,
        lastSleepType: 0,
        lastCC7Pct: 0,
        lastPC8Pct: 0,
        lastDC9: false,
        lastWakeSource: "",
        acEcWakeBlock: "",
        batteryFullState: ""
    )

    init(
        present: Bool,
        isPluggedIn: Bool,
        isCharging: Bool,
        isFullyCharged: Bool,
        percentage: Double,
        batteryWatts: Double,
        healthPct: Double,
        voltageMV: Int32,
        amperageMA: Int32,
        cycleCount: Int32,
        hasS0ix: Bool,
        sleepCount: UInt32,
        lastSleepType: UInt32,
        lastCC7Pct: UInt32,
        lastPC8Pct: UInt32,
        lastDC9: Bool,
        lastWakeSource: String,
        acEcWakeBlock: String,
        batteryFullState: String
    ) {
        self.present = present
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.percentage = percentage
        self.batteryWatts = batteryWatts
        self.healthPct = healthPct
        self.voltageMV = voltageMV
        self.amperageMA = amperageMA
        self.cycleCount = cycleCount
        self.hasS0ix = hasS0ix
        self.sleepCount = sleepCount
        self.lastSleepType = lastSleepType
        self.lastCC7Pct = lastCC7Pct
        self.lastPC8Pct = lastPC8Pct
        self.lastDC9 = lastDC9
        self.lastWakeSource = lastWakeSource
        self.acEcWakeBlock = acEcWakeBlock
        self.batteryFullState = batteryFullState
    }

    init(c: XSPowerMetrics) {
        self.present = c.present
        self.isPluggedIn = c.isPluggedIn
        self.isCharging = c.isCharging
        self.isFullyCharged = c.isFullyCharged
        self.percentage = c.percentage
        self.batteryWatts = c.batteryWatts
        self.healthPct = c.healthPct
        self.voltageMV = c.voltageMV
        self.amperageMA = c.amperageMA
        self.cycleCount = c.cycleCount
        self.hasS0ix = c.hasS0ix
        self.sleepCount = c.sleepCount
        self.lastSleepType = c.lastSleepType
        self.lastCC7Pct = c.lastCC7Pct
        self.lastPC8Pct = c.lastPC8Pct
        self.lastDC9 = c.lastDC9
        self.lastWakeSource = decodeFixedCString(c.lastWakeSource)
        self.acEcWakeBlock = decodeFixedCString(c.acEcWakeBlock)
        self.batteryFullState = decodeFixedCString(c.batteryFullState)
    }
}

struct NetworkSnapshot: Codable, Equatable, Sendable {
    var primaryInterface: String
    var ipv4: String
    var ipv6: String
    var rxBytesPerSec: UInt64
    var txBytesPerSec: UInt64

    var primaryIf: String { primaryInterface }

    static let empty = NetworkSnapshot(
        primaryInterface: "",
        ipv4: "",
        ipv6: "",
        rxBytesPerSec: 0,
        txBytesPerSec: 0
    )

    init(
        primaryInterface: String,
        ipv4: String,
        ipv6: String,
        rxBytesPerSec: UInt64,
        txBytesPerSec: UInt64
    ) {
        self.primaryInterface = primaryInterface
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
    }

    init(c: XSNetworkMetrics) {
        self.primaryInterface = decodeFixedCString(c.primaryIf)
        self.ipv4 = decodeFixedCString(c.ipv4)
        self.ipv6 = decodeFixedCString(c.ipv6)
        self.rxBytesPerSec = c.rxBytesPerSec
        self.txBytesPerSec = c.txBytesPerSec
    }
}

struct WifiSnapshot: Codable, Equatable, Sendable {
    var isPresent: Bool
    var isPoweredOn: Bool
    var isAssociated: Bool
    var interfaceName: String
    var ssid: String?
    var bssid: String?
    var phyMode: String
    var security: String
    var channelNumber: Int
    var channelBand: String
    var channelWidthMHz: Int
    var rssi: Int
    var noise: Int
    var snr: Int
    var txRateMbps: Double

    static let empty = WifiSnapshot(
        isPresent: false,
        isPoweredOn: false,
        isAssociated: false,
        interfaceName: "",
        ssid: nil,
        bssid: nil,
        phyMode: "—",
        security: "—",
        channelNumber: 0,
        channelBand: "—",
        channelWidthMHz: 0,
        rssi: 0,
        noise: 0,
        snr: 0,
        txRateMbps: 0
    )
}

struct ProcessEntry: Codable, Equatable, Identifiable, Sendable {
    var id: Int32 { pid }
    var pid: Int32
    var uid: UInt32
    var cpuPct: Double
    var memoryBytes: UInt64
    var name: String

    init(pid: Int32, uid: UInt32, cpuPct: Double, memoryBytes: UInt64, name: String) {
        self.pid = pid
        self.uid = uid
        self.cpuPct = cpuPct
        self.memoryBytes = memoryBytes
        self.name = name
    }

    init(c: XSProcessEntry) {
        self.pid = c.pid
        self.uid = c.uid
        self.cpuPct = c.cpuPct
        self.memoryBytes = c.memoryBytes
        self.name = decodeFixedCString(c.name)
    }
}

typealias ProcessSnapshot = ProcessEntry

struct SystemSnapshot: Codable, Equatable, Sendable {
    var cpu: CpuSnapshot
    var gpu: GpuSnapshot
    var memory: MemorySnapshot
    var storage: StorageSnapshot
    var power: PowerSnapshot
    var network: NetworkSnapshot
    var wifi: WifiSnapshot
    var topProcesses: [ProcessEntry]
    var isAllUsersProcessList: Bool
    var uptimeSeconds: TimeInterval
    var timestamp: Date

    static let empty = SystemSnapshot(
        cpu: .empty,
        gpu: .empty,
        memory: .empty,
        storage: .empty,
        power: .empty,
        network: .empty,
        wifi: .empty,
        topProcesses: [],
        isAllUsersProcessList: false,
        uptimeSeconds: 0,
        timestamp: Date(timeIntervalSince1970: 0)
    )
}
