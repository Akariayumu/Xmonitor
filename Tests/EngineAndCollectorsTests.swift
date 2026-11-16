import Darwin
import Foundation

private func collectorsMachPortCount() -> UInt32 {
    var names: mach_port_name_array_t?
    var namesCount: mach_msg_type_number_t = 0
    var types: mach_port_type_array_t?
    var typesCount: mach_msg_type_number_t = 0
    let kr = mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount)
    guard kr == KERN_SUCCESS else { return 0 }
    if let names {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: names),
            vm_size_t(namesCount) * vm_size_t(MemoryLayout<mach_port_name_t>.stride)
        )
    }
    if let types {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(bitPattern: types),
            vm_size_t(typesCount) * vm_size_t(MemoryLayout<mach_port_type_t>.stride)
        )
    }
    return namesCount
}

@MainActor
func runEngineAndCollectorsTests() throws {
    // 1. FixedRingBuffer capacity, sliding window & latest element
    var rb = FixedRingBuffer<Double>(capacity: 4, repeating: 0)
    try expectEqual(rb.values, [0.0, 0.0, 0.0, 0.0], "initial ring buffer values")
    try expectEqual(rb.latest, 0.0, "initial ring buffer latest")
    for v in [1.0, 2.0, 3.0, 4.0, 5.0] { rb.append(v) }
    try expectEqual(rb.values, [2.0, 3.0, 4.0, 5.0], "ring buffer sliding window")
    try expectEqual(rb.latest, 5.0, "ring buffer latest after wrap")
    for v in [6.0, 7.0, 8.0, 9.0, 10.0] { rb.append(v) }
    try expectEqual(rb.values, [7.0, 8.0, 9.0, 10.0], "ring buffer multi-wrap ordering")

    // 1b. Bounded fixed-size C char tuple decoder (no NUL terminator in tuple)
    let rawNonNullTuple: (CChar, CChar, CChar, CChar) = (0x58, 0x53, 0x32, 0x21) // "XS2!"
    try expectEqual(decodeFixedCString(rawNonNullTuple), "XS2!", "bounded non-NUL C tuple decode")

    // 1c. SettingsStore cross-task contract & persistence
    let suiteName = "com.xstation.sensei.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults)
    try expectEqual(store.showMenuCPU, true, "default showMenuCPU")
    try expectEqual(store.showMenuGPU, true, "default showMenuGPU")
    try expectEqual(store.showMenuRAM, true, "default showMenuRAM")
    try expectEqual(store.showMenuPower, true, "default showMenuPower")
    try expectEqual(store.showMenuNet, false, "default showMenuNet")
    try expectEqual(store.showMenuTemp, false, "default showMenuTemp")
    try expectEqual(store.widgetsLocked, true, "default widgetsLocked")
    try expectApprox(store.widgetOpacity, 0.88, tol: 1e-6, "default widgetOpacity")
    store.themeMode = .lightFrost
    store.showMenuNet = true
    store.widgetsLocked = false
    store.widgetOpacity = 0.75
    let reloadedStore = SettingsStore(defaults: defaults)
    try expectEqual(reloadedStore.themeMode, AppThemeMode.lightFrost, "persisted themeMode")
    try expectEqual(reloadedStore.showMenuNet, true, "persisted showMenuNet")
    try expectEqual(reloadedStore.widgetsLocked, false, "persisted widgetsLocked")
    try expectApprox(reloadedStore.widgetOpacity, 0.75, tol: 1e-6, "persisted widgetOpacity")

    // 2. Reference-counted scheduler transitions (Review Focus #5)
    let engine = TelemetryEngine(autoStart: false)
    try expectEqual(engine.currentInterval, 2.0, "default ambient 2.0s")
    let t1 = engine.beginInteractiveSession()
    let t2 = engine.beginInteractiveSession()
    try expectEqual(engine.currentInterval, 1.0, "interactive 1.0s")
    engine.endInteractiveSession(t1)
    try expectEqual(engine.currentInterval, 1.0, "still 1.0s while second consumer open")
    // Duplicate end token must be idempotent and not decrement refcount twice
    engine.endInteractiveSession(t1)
    try expectEqual(engine.currentInterval, 1.0, "idempotent duplicate endInteractiveSession")
    engine.endInteractiveSession(t2)
    try expectEqual(engine.currentInterval, 2.0, "drops back to 2.0s when all closed")
    engine.handleSleep()
    try expectEqual(engine.currentInterval, 0.0, "0 Hz while asleep")
    let t3 = engine.beginInteractiveSession()
    try expectEqual(engine.currentInterval, 0.0, "stays 0 Hz while asleep even if session acquired")
    engine.handleWake()
    try expectEqual(engine.currentInterval, 1.0, "resumes at 1.0s on wake when interactive session open")
    engine.endInteractiveSession(t3)
    try expectEqual(engine.currentInterval, 2.0, "returns to 2.0s after post-wake session ends")

    // 3. Live NVMe SMART + Network + Process collector check
    let ctx = xs_bridge_create()!
    var sto = XSStorageMetrics(), net = XSNetworkMetrics()
    var procs = [XSProcessEntry](repeating: XSProcessEntry(), count: 30)
    var allUsers = false
    xs_bridge_sample_io_net(ctx, true, &sto, &net)
    _ = xs_bridge_sample_processes(ctx, &procs, 30, &allUsers)
    usleep(400_000)
    xs_bridge_sample_io_net(ctx, false, &sto, &net)
    let n = Int(xs_bridge_sample_processes(ctx, &procs, 30, &allUsers))
    try expectTrue(sto.hasSmart && sto.tempC > 5 && sto.tempC < 95, "Kingston NVMe SMART °C: \(sto.tempC)")
    try expectTrue(sto.availableSparePct > 0 && sto.availableSparePct <= 100, "NVMe spare %: \(sto.availableSparePct)")
    try expectTrue(sto.powerOnHours > 0, "NVMe powerOnHours > 0: \(sto.powerOnHours)")
    try expectTrue(!decodeFixedCString(sto.model).isEmpty, "NVMe model non-empty")
    try expectTrue(!decodeFixedCString(net.primaryIf).isEmpty, "primary network interface detected")
    try expectTrue(n >= 5, "process list populated: \(n)")
    for i in 1..<n {
        try expectTrue(procs[i - 1].cpuPct + 1e-9 >= procs[i].cpuPct, "processes sorted descending by cpuPct")
    }

    // Verify full PID table scan (must not truncate early-boot/session PIDs like Finder/Dock)
    var fullProcs = [XSProcessEntry](repeating: XSProcessEntry(), count: 512)
    let fullCount = Int(xs_bridge_sample_processes(ctx, &fullProcs, 512, &allUsers))
    let fullNames = fullProcs.prefix(fullCount).map { decodeFixedCString($0.name) }
    try expectTrue(
        fullCount >= 60 && (fullNames.contains("Finder") || fullNames.contains("Dock")),
        "full PID scan includes early session processes (count=\(fullCount))"
    )

    // 4. Mach port & COM plugin refcount hygiene across repeated IO/Net/Process ticks & lifecycles
    for _ in 0..<5 {
        xs_bridge_sample_io_net(ctx, false, &sto, &net)
        _ = xs_bridge_sample_processes(ctx, &procs, 30, &allUsers)
    }
    let portsBefore = collectorsMachPortCount()
    for i in 0..<40 {
        xs_bridge_sample_io_net(ctx, i % 10 == 0, &sto, &net)
        _ = xs_bridge_sample_processes(ctx, &procs, 30, &allUsers)
    }
    let portsAfter = collectorsMachPortCount()
    xs_bridge_destroy(ctx)
    try expectEqual(portsAfter, portsBefore, "zero Mach port leaks across 40 IO/Net/Process samples")

    let portsPreLifecycle = collectorsMachPortCount()
    for _ in 0..<5 {
        let tmp = xs_bridge_create()!
        xs_bridge_sample_io_net(tmp, true, &sto, &net)
        _ = xs_bridge_sample_processes(tmp, &procs, 30, &allUsers)
        xs_bridge_destroy(tmp)
    }
    let portsPostLifecycle = collectorsMachPortCount()
    try expectEqual(portsPostLifecycle, portsPreLifecycle, "zero Mach port/COM plugin leaks across 5 create/destroy cycles")

    // 5. End-to-end TelemetryEngine live 2-tick snapshot + Codable JSON verification
    let tSnap = engine.beginInteractiveSession()
    defer { engine.endInteractiveSession(tSnap) }
    engine.refreshNow()
    usleep(300_000)
    engine.refreshNow()
    let snap = engine.snapshot
    try expectTrue(snap.storage.totalBytes > 100_000_000_000, "APFS volume totalBytes > 100 GB: \(snap.storage.totalBytes)")
    try expectTrue(snap.storage.hasSmart, "snapshot storage hasSmart")
    try expectTrue(snap.topProcesses.count >= 5, "snapshot topProcesses populated")
    try expectTrue(snap.uptimeSeconds > 0, "snapshot uptimeSeconds > 0")
    let jsonData = try JSONEncoder().encode(snap)
    let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: jsonData)
    try expectEqual(decoded.storage.tempC, snap.storage.tempC, "SystemSnapshot JSON roundtrip")

    let topSummary = snap.topProcesses.prefix(3).map {
        String(format: "%@(pid=%d,%.1f%%,%.0fMB)", $0.name, $0.pid, $0.cpuPct, Double($0.memoryBytes) / 1_048_576.0)
    }.joined(separator: ", ")
    print(String(
        format: "[Live Collectors] NVMe='%@' temp=%d°C wear=%d%% spare=%d%% R=%.2fTB W=%.2fTB POH=%llu cycles=%llu unsafe=%llu APFS=%.1f/%.1fGB | Net=%@ (%@) | WiFi=%@ assoc=%@ phy=%@ ch=%d(%@,%dMHz) rssi=%ddBm noise=%ddBm snr=%ddB tx=%.0fMbps ssid=%@ | Procs=%d (allUsers=%@): [%@] | Ports=%u->%u lifecycle=%u->%u",
        snap.storage.model, snap.storage.tempC, snap.storage.lifeUsedPct, snap.storage.availableSparePct,
        snap.storage.dataReadTB, snap.storage.dataWrittenTB,
        snap.storage.powerOnHours, snap.storage.powerCycles, snap.storage.unsafeShutdowns,
        Double(snap.storage.usedBytes) / 1_000_000_000.0, Double(snap.storage.totalBytes) / 1_000_000_000.0,
        snap.network.primaryInterface, snap.network.ipv4,
        snap.wifi.interfaceName, snap.wifi.isAssociated ? "true" : "false", snap.wifi.phyMode,
        snap.wifi.channelNumber, snap.wifi.channelBand, snap.wifi.channelWidthMHz,
        snap.wifi.rssi, snap.wifi.noise, snap.wifi.snr, snap.wifi.txRateMbps,
        snap.wifi.ssid ?? "nil(redacted)",
        snap.topProcesses.count, snap.isAllUsersProcessList ? "true" : "false", topSummary,
        portsBefore, portsAfter, portsPreLifecycle, portsPostLifecycle
    ))
}
