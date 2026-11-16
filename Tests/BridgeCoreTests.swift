import Darwin
import Foundation

func cString(_ tuple: some Any) -> String {
    withUnsafePointer(to: tuple) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple)) {
            String(cString: $0)
        }
    }
}

private struct MockS0ixGpuEnv {
    var passiveExposed: Bool
    var supportsSetProperties: Bool
    var publishedCurrentMHz: Int64
    var publishedRequestedMHz: Int64
    var setPropsInvocations: Int = 0
}

private let mockReadS0ixInt: XSGpuReadRegIntFn = { userCtx, keyPtr, outVal in
    guard let userCtx, let keyPtr, let outVal else { return false }
    let env = userCtx.assumingMemoryBound(to: MockS0ixGpuEnv.self)
    guard env.pointee.passiveExposed else { return false }
    let key = String(cString: keyPtr)
    if key == "GPU Current Freq MHz" {
        outVal.pointee = env.pointee.publishedCurrentMHz
        return true
    }
    if key == "GPU Requested Freq MHz" {
        outVal.pointee = env.pointee.publishedRequestedMHz
        return true
    }
    return false
}

private let mockTriggerS0ixRefresh: XSGpuTriggerRefreshFn = { userCtx in
    guard let userCtx else { return false }
    let env = userCtx.assumingMemoryBound(to: MockS0ixGpuEnv.self)
    env.pointee.setPropsInvocations += 1
    guard env.pointee.supportsSetProperties else { return false }
    env.pointee.passiveExposed = true
    return true
}

private func runGpuFreqProbeGatingTests() throws {
    // Case A: EFI v2.0.1 starting in RC6 (usage < 0.5%, property not yet published) -> wakes to >= 0.5% -> returns to RC6
    var envA = MockS0ixGpuEnv(
        passiveExposed: false,
        supportsSetProperties: true,
        publishedCurrentMHz: 750,
        publishedRequestedMHz: 800
    )
    var stateA = XSGpuFreqProbeState()
    var gpuA = XSGpuMetrics()

    // Idle tick 1 (0.0%): must NOT call setProperties and must NOT prematurely latch freqProbed=true
    withUnsafeMutablePointer(to: &envA) { ptr in
        xs_step_s0ix_gpu_freq(&stateA, 0.0, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuA)
    }
    try expectEqual(envA.setPropsInvocations, 0, "RC6 idle tick (0.0%) must not invoke refreshGpuFreq")
    try expectEqual(stateA.refreshCallCount, 0, "refreshCallCount stays 0 at 0.0% usage")
    try expectEqual(stateA.freqProbed, false, "freqProbed must not latch while GPU < 0.5%")
    try expectEqual(gpuA.hasFreq, false, "hasFreq false before first active or passive exposure")

    // Idle tick 2 (0.49%): still below 0.5% threshold
    withUnsafeMutablePointer(to: &envA) { ptr in
        xs_step_s0ix_gpu_freq(&stateA, 0.49, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuA)
    }
    try expectEqual(envA.setPropsInvocations, 0, "0.49% usage still below 0.5% gate")
    try expectEqual(stateA.freqProbed, false, "freqProbed still unlatched at 0.49%")

    // Active tick 3 (12.5% >= 0.5%): probes once, discovers support, reads 750 / 800 MHz without double-refresh
    gpuA = XSGpuMetrics()
    gpuA.usagePct = 12.5
    withUnsafeMutablePointer(to: &envA) { ptr in
        xs_step_s0ix_gpu_freq(&stateA, 12.5, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuA)
    }
    try expectEqual(envA.setPropsInvocations, 1, "active >= 0.5% tick triggers exactly 1 refreshGpuFreq")
    try expectEqual(stateA.freqProbed, true, "freqProbed latches true after active probe")
    try expectEqual(stateA.supportsGpuFreq, true, "supportsGpuFreq latches true on EFI v2.0.1")
    try expectEqual(gpuA.hasFreq, true, "hasFreq true once supported")
    try expectEqual(gpuA.currentFreqMHz, 750, "currentFreqMHz read at >= 0.5% usage")
    try expectEqual(gpuA.requestedFreqMHz, 800, "requestedFreqMHz read at >= 0.5% usage")

    // Return to RC6 idle tick 4 (0.1% < 0.5%): zero kernel MMIO refresh, reports hasFreq=true & 0 MHz
    gpuA = XSGpuMetrics()
    gpuA.usagePct = 0.1
    withUnsafeMutablePointer(to: &envA) { ptr in
        xs_step_s0ix_gpu_freq(&stateA, 0.1, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuA)
    }
    try expectEqual(envA.setPropsInvocations, 1, "returning to RC6 (< 0.5%) skips refreshGpuFreq")
    try expectEqual(gpuA.hasFreq, true, "hasFreq stays true in RC6")
    try expectEqual(gpuA.currentFreqMHz, 0, "RC6 idle reports 0 MHz")

    // Case B: Property already passively exposed in IORegistry while idle (0.0%)
    var envB = MockS0ixGpuEnv(
        passiveExposed: true,
        supportsSetProperties: true,
        publishedCurrentMHz: 300,
        publishedRequestedMHz: 300
    )
    var stateB = XSGpuFreqProbeState()
    var gpuB = XSGpuMetrics()
    withUnsafeMutablePointer(to: &envB) { ptr in
        xs_step_s0ix_gpu_freq(&stateB, 0.0, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuB)
    }
    try expectEqual(envB.setPropsInvocations, 0, "passive property detected without setProperties")
    try expectEqual(stateB.freqProbed, true, "passive detection latches freqProbed=true")
    try expectEqual(stateB.supportsGpuFreq, true, "passive detection latches supportsGpuFreq=true")
    try expectEqual(gpuB.hasFreq, true, "passive detection sets hasFreq=true")
    try expectEqual(gpuB.currentFreqMHz, 0, "idle 0.0% reports 0 MHz even when passively exposed")

    // Case C: EFI v2.0 (S0ixStandby without refreshGpuFreq support)
    var envC = MockS0ixGpuEnv(
        passiveExposed: false,
        supportsSetProperties: false,
        publishedCurrentMHz: 0,
        publishedRequestedMHz: 0
    )
    var stateC = XSGpuFreqProbeState()
    var gpuC = XSGpuMetrics()
    withUnsafeMutablePointer(to: &envC) { ptr in
        xs_step_s0ix_gpu_freq(&stateC, 0.0, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuC)
    }
    try expectEqual(envC.setPropsInvocations, 0, "EFI v2.0 idle 0.0% does not call setProperties")
    withUnsafeMutablePointer(to: &envC) { ptr in
        xs_step_s0ix_gpu_freq(&stateC, 4.0, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuC)
    }
    try expectEqual(envC.setPropsInvocations, 1, "EFI v2.0 probes once at >= 0.5% usage")
    try expectEqual(stateC.freqProbed, true, "EFI v2.0 latches freqProbed=true after failed >= 0.5% probe")
    try expectEqual(stateC.supportsGpuFreq, false, "EFI v2.0 latches supportsGpuFreq=false")
    withUnsafeMutablePointer(to: &envC) { ptr in
        xs_step_s0ix_gpu_freq(&stateC, 25.0, mockReadS0ixInt, mockTriggerS0ixRefresh, ptr, &gpuC)
    }
    try expectEqual(envC.setPropsInvocations, 1, "subsequent >= 0.5% ticks do not re-probe unsupported S0ixStandby")
}

private func currentMachPortCount() -> UInt32 {
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

private func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func runBridgeCoreTests() throws {
    // 1. 32-bit RAPL wraparound: (0x0000_0100 - 0xFFFF_FF00) = 512 ticks @ ESU=14, dt=0.5s -> (512 / 16384) / 0.5 = 0.0625 W
    let wrapW = xs_calc_rapl_watts(0xFFFF_FF00, 0x0000_0100, 14, 0.5)
    try expectApprox(wrapW, 0.0625, tol: 1e-6, "32-bit RAPL wraparound")

    // 2. Across-sleep spike guard: dt <= 0 or dt > 10.0s must clamp to 0 W
    try expectEqual(xs_calc_rapl_watts(1000, 500000, 14, 6240.0), 0.0, "sleep jump spike guard")
    try expectEqual(xs_calc_rapl_watts(1000, 2000, 14, 0.0), 0.0, "zero dt guard")
    try expectEqual(xs_calc_rapl_watts(1000, 2000, 14, -1.0), 0.0, "negative dt guard")

    // 2b. APERF/MPERF pure math helper
    try expectEqual(xs_calc_aperf_mhz(5000, 0, 2800.0), 0.0, "zero deltaMcnt fallback")
    try expectApprox(xs_calc_aperf_mhz(3000, 2000, 2800.0), 4200.0, tol: 1e-6, "APERF/MPERF turbo scaling")

    // 3. Two's-complement negative InstantAmperage (-1250 mA as uint64 bit pattern) @ 11600 mV -> -14.5 W
    var signedMA: Int32 = 0
    let battW = xs_calc_battery_watts(11600, UInt64(bitPattern: -1250), &signedMA)
    try expectEqual(signedMA, -1250, "signed mA decode")
    try expectApprox(battW, -14.5, tol: 1e-4, "negative discharge watts")

    var posMA: Int32 = 0
    let chargeW = xs_calc_battery_watts(12000, 1500, &posMA)
    try expectEqual(posMA, 1500, "positive mA decode")
    try expectApprox(chargeW, 18.0, tol: 1e-4, "positive charge watts")

    // 3b. S0ixStandby refreshGpuFreq >= 0.5% gating & latch state machine
    try runGpuFreqProbeGatingTests()

    // 4. Live X-STATION V2 hardware smoke test (2 samples, 0.4s apart)
    let ctx = xs_bridge_create()!
    var cpu = XSCpuMetrics(), gpu = XSGpuMetrics(), mem = XSMemoryMetrics(), pwr = XSPowerMetrics()
    xs_bridge_sample_core(ctx, &cpu, &gpu, &mem, &pwr)
    // Sample 1 has no baseline (gpu.usagePct == 0.0 < 0.5%): must make 0 refreshGpuFreq calls
    try expectEqual(xs_bridge_gpu_freq_refresh_count(ctx), 0, "first baseline sample (0% GPU) makes 0 refreshGpuFreq calls")

    usleep(400_000)
    xs_bridge_sample_core(ctx, &cpu, &gpu, &mem, &pwr)

    try expectTrue(cpu.threadCount == 8, "i7-1165G7 8 threads")
    try expectTrue(cpu.avgFreqMHz >= 300 && cpu.avgFreqMHz <= 4900, "real APERF/MPERF MHz: \(cpu.avgFreqMHz)")
    try expectTrue(cpu.packagePowerW > 0.3 && cpu.packagePowerW < 65.0, "real RAPL package W: \(cpu.packagePowerW)")
    try expectTrue(gpu.usagePct >= 0.0 && gpu.usagePct <= 100.0, "GPU RC0 usage")
    try expectTrue(gpu.gartSizeBytes > 1_000_000_000 && gpu.gartUsedBytes < gpu.gartSizeBytes, "GART sane (no underflow)")
    try expectEqual(mem.totalBytes, 17_179_869_184, "16 GB RAM")
    try expectTrue(mem.usedBytes > 1_000_000_000 && mem.usedBytes < mem.totalBytes, "used RAM sane")
    try expectTrue(pwr.present && pwr.hasS0ix, "Battery + S0ixStandby detected")

    // 5. Baseline reset check: first sample right after xs_bridge_reset_baselines has 0% GPU usage and must emit 0 W & 0 new refreshGpuFreq calls
    let refreshBeforeReset = xs_bridge_gpu_freq_refresh_count(ctx)
    xs_bridge_reset_baselines(ctx)
    var resetCpu = XSCpuMetrics(), resetGpu = XSGpuMetrics(), resetMem = XSMemoryMetrics(), resetPwr = XSPowerMetrics()
    xs_bridge_sample_core(ctx, &resetCpu, &resetGpu, &resetMem, &resetPwr)
    try expectEqual(resetCpu.packagePowerW, 0.0, "first sample after reset emits 0 W")
    try expectEqual(xs_bridge_gpu_freq_refresh_count(ctx), refreshBeforeReset, "post-reset baseline sample (0% GPU) makes 0 refreshGpuFreq calls")

    // 6. Leak & latency check (Mach port-right hygiene, CFRelease/vm_deallocate stability, sub-ms latency)
    for _ in 0..<20 {
        xs_bridge_sample_core(ctx, &resetCpu, &resetGpu, &resetMem, &resetPwr)
    }
    let portsBefore = currentMachPortCount()
    let rssBefore = currentResidentBytes()
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let benchIters = 200
    for _ in 0..<benchIters {
        xs_bridge_sample_core(ctx, &resetCpu, &resetGpu, &resetMem, &resetPwr)
    }
    let elapsedUs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000.0 / Double(benchIters)
    let portsAfterSamples = currentMachPortCount()
    let rssAfterSamples = currentResidentBytes()
    xs_bridge_destroy(ctx)

    // Also verify create/destroy lifecycle leaves zero leaked Mach ports
    let portsPreLifecycle = currentMachPortCount()
    for _ in 0..<5 {
        let tmp = xs_bridge_create()!
        xs_bridge_sample_core(tmp, &resetCpu, &resetGpu, &resetMem, &resetPwr)
        xs_bridge_destroy(tmp)
    }
    let portsPostLifecycle = currentMachPortCount()

    try expectEqual(portsAfterSamples, portsBefore, "zero Mach port leaks across 200 samples")
    try expectEqual(portsPostLifecycle, portsPreLifecycle, "zero Mach port leaks across 5 create/destroy cycles")
    let rssDelta = rssAfterSamples > rssBefore ? (rssAfterSamples - rssBefore) : 0
    try expectTrue(rssDelta < 1_048_576, "RSS growth < 1 MB over 200 samples (actual \(rssDelta) B)")

    print(String(
        format: "[Live X-STATION V2] CPU: %.1f%% (user %.1f%% / sys %.1f%%), avg %.0f MHz, max %.0f MHz, pkg %.2f W, core %.2f W, pkgC %.1f%%, hasTemp=%@ | GPU: %.2f%% busy (RC6 %.2f%%), %.2f W, hasFreq=%@, GART %.1f/%.1f MB, SinkRestore ok=%u retries=%u | RAM: %.2f/%.2f GB (app %.2f, wired %.2f, comp %.2f, cached %.2f GB), pressure=%d | Batt: %.0f%% (%.2f W, %d mV, %d mA, health %.1f%%) | S0ix: sleeps=%u type=%u CC7=%u%% PC8=%u%% DC9=%@ wake='%@' acBlock='%@' battFull='%@' | Perf: %.0f us/sample, ports=%u->%u, rssDelta=%llu B",
        cpu.totalUsage, cpu.userUsage, cpu.sysUsage,
        cpu.avgFreqMHz, cpu.maxFreqMHz,
        cpu.packagePowerW, cpu.corePowerW, cpu.pkgCStatePct,
        cpu.hasTemp ? "true" : "false",
        gpu.usagePct, gpu.rc6Pct, gpu.powerW,
        gpu.hasFreq ? "true" : "false",
        Double(gpu.gartUsedBytes) / 1_048_576.0, Double(gpu.gartSizeBytes) / 1_048_576.0,
        gpu.sinkRestoreOk, gpu.sinkRestoreRetries,
        Double(mem.usedBytes) / 1_073_741_824.0, Double(mem.totalBytes) / 1_073_741_824.0,
        Double(mem.appBytes) / 1_073_741_824.0, Double(mem.wiredBytes) / 1_073_741_824.0,
        Double(mem.compressedBytes) / 1_073_741_824.0, Double(mem.cachedBytes) / 1_073_741_824.0,
        mem.pressureLevel,
        pwr.percentage, pwr.batteryWatts, pwr.voltageMV, pwr.amperageMA, pwr.healthPct,
        pwr.sleepCount, pwr.lastSleepType, pwr.lastCC7Pct, pwr.lastPC8Pct,
        pwr.lastDC9 ? "true" : "false",
        cString(pwr.lastWakeSource), cString(pwr.acEcWakeBlock), cString(pwr.batteryFullState),
        elapsedUs, portsBefore, portsAfterSamples, rssDelta
    ))
}
