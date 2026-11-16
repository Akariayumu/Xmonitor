#ifndef HARDWARE_BRIDGE_H
#define HARDWARE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct XSBridgeContext XSBridgeContext;

typedef struct {
    double totalUsage, userUsage, sysUsage;
    double threadUsage[16];
    double threadFreqMHz[16];
    uint32_t threadCount;
    double avgFreqMHz, maxFreqMHz;
    double packagePowerW, corePowerW;
    double pkgCStatePct;
    bool hasTemp;
    double packageTempC;
    double coreTempC[8];
    uint32_t coreTempCount;
    double loadAvg[3];
} XSCpuMetrics;

typedef struct {
    double usagePct, rc6Pct, powerW;
    bool hasFreq;
    uint32_t currentFreqMHz, requestedFreqMHz;
    uint64_t gartUsedBytes, gartSizeBytes;
    uint32_t sinkRestoreOk, sinkRestoreRetries;
} XSGpuMetrics;

typedef struct {
    uint64_t totalBytes, usedBytes, appBytes, wiredBytes, compressedBytes, cachedBytes, swapUsedBytes, swapTotalBytes;
    int32_t pressureLevel;
} XSMemoryMetrics;

typedef struct {
    bool present, isPluggedIn, isCharging, isFullyCharged;
    double percentage, batteryWatts, healthPct;
    int32_t voltageMV, amperageMA, cycleCount;
    bool hasS0ix;
    uint32_t sleepCount, lastSleepType, lastCC7Pct, lastPC8Pct;
    bool lastDC9;
    char lastWakeSource[96];
    char acEcWakeBlock[96];
    char batteryFullState[96];
} XSPowerMetrics;

typedef struct {
    uint64_t readBytesPerSec, writeBytesPerSec;
    double readIOPS, writeIOPS;
    bool hasSmart;
    int32_t tempC, lifeUsedPct, availableSparePct;
    double dataReadTB, dataWrittenTB;
    uint64_t powerOnHours, powerCycles, unsafeShutdowns;
    char model[64];
} XSStorageMetrics;

typedef struct {
    char primaryIf[16];
    char ipv4[46];
    char ipv6[64];
    uint64_t rxBytesPerSec, txBytesPerSec;
} XSNetworkMetrics;

typedef struct {
    int32_t pid;
    uint32_t uid;
    double cpuPct;
    uint64_t memoryBytes;
    char name[64];
} XSProcessEntry;

double xs_calc_rapl_watts(uint64_t prevRaw, uint64_t currRaw, uint8_t esuBits, double dtSec);
double xs_calc_aperf_mhz(uint64_t deltaAcnt, uint64_t deltaMcnt, double baseMHz);
double xs_calc_battery_watts(int64_t voltageMV, uint64_t rawInstantAmperage, int32_t *outSignedMA);

typedef struct {
    bool freqProbed;
    bool supportsGpuFreq;
    uint64_t refreshCallCount;
} XSGpuFreqProbeState;

typedef bool (*XSGpuReadRegIntFn)(void *userCtx, const char *key, int64_t *outVal);
typedef bool (*XSGpuTriggerRefreshFn)(void *userCtx);

void xs_step_s0ix_gpu_freq(
    XSGpuFreqProbeState *state,
    double gpuUsagePct,
    XSGpuReadRegIntFn readInt,
    XSGpuTriggerRefreshFn triggerRefresh,
    void *userCtx,
    XSGpuMetrics *gpu);

uint64_t xs_bridge_gpu_freq_refresh_count(const XSBridgeContext *ctx);

XSBridgeContext *xs_bridge_create(void);
void xs_bridge_reset_baselines(XSBridgeContext *ctx);
void xs_bridge_set_preferred_net_if(XSBridgeContext *ctx, const char *ifName);
void xs_bridge_sample_core(XSBridgeContext *ctx, XSCpuMetrics *cpu, XSGpuMetrics *gpu, XSMemoryMetrics *mem, XSPowerMetrics *pwr);
void xs_bridge_sample_io_net(XSBridgeContext *ctx, bool refreshSmart, XSStorageMetrics *sto, XSNetworkMetrics *net);
uint32_t xs_bridge_sample_processes(XSBridgeContext *ctx, XSProcessEntry *outEntries, uint32_t maxEntries, bool *outAllUsers);
void xs_bridge_destroy(XSBridgeContext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* HARDWARE_BRIDGE_H */
