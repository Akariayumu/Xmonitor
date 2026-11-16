#include "HardwareBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <Security/SecTask.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <mach/host_info.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <mach/vm_map.h>
#include <math.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <x86intrin.h>
#include <xpc/xpc.h>

/* ========================================================================== *
 * Dynamic libsysmon.dylib types & attribute constants
 * ========================================================================== */

typedef void *xs_sysmon_request_t;
typedef void *xs_sysmon_table_t;
typedef void *xs_sysmon_row_t;
typedef void (^xs_sysmon_table_handler_t)(xs_sysmon_table_t table);
typedef bool (^xs_sysmon_row_applier_t)(xs_sysmon_row_t row);

typedef xs_sysmon_request_t (*fn_sysmon_request_create)(uint64_t type, xs_sysmon_table_handler_t handler);
typedef void (*fn_sysmon_request_add_attribute)(xs_sysmon_request_t req, uint32_t attr);
typedef void (*fn_sysmon_request_execute)(xs_sysmon_request_t req);
typedef void (*fn_sysmon_request_cancel)(xs_sysmon_request_t req);
typedef void (*fn_sysmon_table_apply)(xs_sysmon_table_t table, xs_sysmon_row_applier_t applier);
typedef xpc_object_t (*fn_sysmon_row_get_value)(xs_sysmon_row_t row, uint32_t attr);
typedef void (*fn_sysmon_release)(void *obj);

#define XS_SYSMON_REQ_PROCESS       1ULL
#define XS_SYSMON_ATTR_PID          0x01U
#define XS_SYSMON_ATTR_UID          0x03U
#define XS_SYSMON_ATTR_COMM         0x0cU
#define XS_SYSMON_ATTR_NAME         0x0dU
#define XS_SYSMON_ATTR_START_NS     0x14U
#define XS_SYSMON_ATTR_RESIDENT     0x16U
#define XS_SYSMON_ATTR_USER_NS      0x17U
#define XS_SYSMON_ATTR_SYS_NS       0x18U
#define XS_SYSMON_ATTR_FOOTPRINT    0x42U

typedef struct {
    int32_t pid;
    uint32_t _pad;
    uint64_t startKey;
    uint64_t cpuNs;
} XSProcDeltaSlot;

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint64_t startKey;
    uint64_t cpuNs;
    uint64_t memoryBytes;
    double cpuPct;
    char name[64];
} XSProcRawRow;

/* ========================================================================== *
 * Dynamic libIOReport.dylib types & function pointers
 * ========================================================================== */

typedef struct __IOReportSubscriptionRef *IOReportSubscriptionRef;
typedef int (^IOReportIterationBlock)(CFDictionaryRef channel);

typedef CFDictionaryRef (*fn_IOReportCopyChannelsInGroup)(
    CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
typedef void (*fn_IOReportMergeChannels)(
    CFDictionaryRef into, CFDictionaryRef from, CFTypeRef nil_arg);
typedef IOReportSubscriptionRef (*fn_IOReportCreateSubscription)(
    void *a, CFMutableDictionaryRef desiredChannels,
    CFMutableDictionaryRef *subbedChannelsOut, uint64_t channel_id, CFTypeRef b);
typedef CFDictionaryRef (*fn_IOReportCreateSamples)(
    IOReportSubscriptionRef sub, CFMutableDictionaryRef subbedChannels, CFTypeRef a);
typedef void (*fn_IOReportIterate)(
    CFDictionaryRef samples, IOReportIterationBlock block);
typedef CFStringRef (*fn_IOReportChannelGetGroup)(CFDictionaryRef channel);
typedef CFStringRef (*fn_IOReportChannelGetChannelName)(CFDictionaryRef channel);
typedef int64_t (*fn_IOReportSimpleGetIntegerValue)(CFDictionaryRef channel, int32_t idx);

/* ========================================================================== *
 * AppleSMC UserClient ABI (selector 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9)
 * ========================================================================== */

#define XS_SMC_KERNEL_INDEX 2
#define XS_SMC_CMD_READ_BYTES 5
#define XS_SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} XSSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} XSSMCLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} XSSMCKeyInfo;

typedef struct {
    uint32_t key;
    XSSMCVersion vers;
    XSSMCLimitData pLimitData;
    XSSMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} XSSMCKeyData;

static uint32_t xs_fourcc(const char s[4]) {
    return ((uint32_t)(uint8_t)s[0] << 24) |
           ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  |
           ((uint32_t)(uint8_t)s[3]);
}

/* ========================================================================== *
 * Raw IOReport Snapshot State
 * ========================================================================== */

#define XS_MAX_THREADS 16
#define XS_NUM_PKG_CSTATES 7

typedef struct {
    uint8_t esuBits;
    uint64_t pkgEnergy;
    uint64_t pp0Energy;
    uint64_t pp1Energy;
    uint64_t acnt[XS_MAX_THREADS];
    uint64_t mcnt[XS_MAX_THREADS];
    uint64_t pkgCResidency[XS_NUM_PKG_CSTATES]; /* C2, C3, C6, C7, C8, C9, C10 */
    uint64_t rc0;
    uint64_t rc1;
    uint64_t rc6;
} XSIOReportRawSample;

struct XSBridgeContext {
    mach_port_t hostPort;
    uint64_t totalMemBytes;
    double baseMHz;

    /* libIOReport dynamic symbols & persistent subscription */
    void *ioReportDylib;
    fn_IOReportCopyChannelsInGroup pCopyChannelsInGroup;
    fn_IOReportMergeChannels pMergeChannels;
    fn_IOReportCreateSubscription pCreateSubscription;
    fn_IOReportCreateSamples pCreateSamples;
    fn_IOReportIterate pIterate;
    fn_IOReportChannelGetGroup pChannelGetGroup;
    fn_IOReportChannelGetChannelName pChannelGetChannelName;
    fn_IOReportSimpleGetIntegerValue pSimpleGetIntegerValue;
    IOReportSubscriptionRef ioSub;
    CFMutableDictionaryRef ioSubbedChannels;

    /* Persistent IOKit handles */
    io_connect_t smcConn;
    bool smcProbed;
    bool smcHasTemp;
    uint32_t smcPkgKey;
    XSSMCKeyInfo smcPkgInfo;
    uint32_t smcCoreKeys[8];
    XSSMCKeyInfo smcCoreInfos[8];
    uint32_t smcCoreCount;
    bool smcHasAcin;
    XSSMCKeyInfo smcAcinInfo;
    bool smcHasB0ac;
    XSSMCKeyInfo smcB0acInfo;
    bool smcHasB0av;
    XSSMCKeyInfo smcB0avInfo;

    io_service_t accelService;
    io_service_t batteryService;
    io_service_t s0ixService;
    io_registry_entry_t rootEntry;
    CFDictionaryRef refreshGpuFreqDict;
    XSGpuFreqProbeState gpuFreqState;

    /* Cached S0ixStandby snapshot (refreshed on sleepCount / AC / full-charge change or reset) */
    bool s0ixCacheValid;
    bool cachedPluggedIn;
    bool cachedFullyCharged;
    uint32_t cachedSleepCount;
    uint32_t cachedLastSleepType;
    uint32_t cachedLastCC7Pct;
    uint32_t cachedLastPC8Pct;
    bool cachedLastDC9;
    char cachedLastWakeSource[96];
    char cachedAcEcWakeBlock[96];
    char cachedBatteryFullState[96];
    uint32_t powerSampleCount;
    uint64_t lastPowerSampleNs;
    XSPowerMetrics cachedPowerMetrics;
    bool hasBattRegCache;
    uint64_t lastBattRegSampleNs;
    int64_t cachedDesignCapacity;
    int64_t cachedRegRawRate;
    XSPowerMetrics cachedBattReg;
    XSBatteryDischargeTracker battTracker;
    uint32_t gpuRegSampleCount;
    uint64_t lastGpuRegSampleNs;
    uint64_t cachedGartUsedBytes;
    uint64_t cachedGartSizeBytes;
    uint32_t cachedSinkOk;
    uint32_t cachedSinkRetries;
    bool sinkKnownOnRoot;
    int swapMib[4];
    size_t swapMibLen;
    int pressureMib[4];
    size_t pressureMibLen;

    /* Delta baselines */
    bool hasTelemetryBaseline;
    uint64_t prevMonoNs;
    uint64_t prevTsc;
    XSIOReportRawSample prevIOReport;

    bool hasCpuTickBaseline;
    uint32_t prevCpuCount;
    uint32_t prevUser[XS_MAX_THREADS];
    uint32_t prevSys[XS_MAX_THREADS];
    uint32_t prevNice[XS_MAX_THREADS];
    uint32_t prevIdle[XS_MAX_THREADS];

    mach_timebase_info_data_t timebase;

    /* Storage SMART & IOBlockStorageDriver handles */
    bool storageProbed;
    io_service_t nvmeBlockService;
    io_service_t blockDriverService;
    IOCFPlugInInterface **nvmePlugIn;
    IONVMeSMARTInterface **nvmeSmartIf;
    char nvmeModel[64];
    bool hasSmartCache;
    XSStorageMetrics cachedSmart;

    bool hasDiskBaseline;
    uint64_t prevDiskMonoNs;
    uint64_t prevDiskReadBytes;
    uint64_t prevDiskWriteBytes;
    uint64_t prevDiskReadOps;
    uint64_t prevDiskWriteOps;

    /* Network primary interface & delta baselines */
    char preferredNetIf[16];
    bool hasNetBaseline;
    char prevNetIf[16];
    uint64_t prevNetMonoNs;
    uint64_t prevNetRxBytes;
    uint64_t prevNetTxBytes;

    /* Dual-path Process collector (libsysmon when entitled + libproc fallback) */
    bool sysmonProbed;
    bool hasSysmonEntitlement;
    void *sysmonDylib;
    fn_sysmon_request_create pSysmonReqCreate;
    fn_sysmon_request_add_attribute pSysmonReqAddAttr;
    fn_sysmon_request_execute pSysmonReqExecute;
    fn_sysmon_request_cancel pSysmonReqCancel;
    fn_sysmon_table_apply pSysmonTableApply;
    fn_sysmon_row_get_value pSysmonRowGetValue;
    fn_sysmon_release pSysmonRelease;

    bool hasProcBaseline;
    uint64_t prevProcMonoNs;
    size_t procTableCap; /* power-of-two open-addressed hash table capacity */
    XSProcDeltaSlot *prevProcTable;
    XSProcDeltaSlot *currProcTable;
    int *pidBuf;
    size_t pidBufCap;
    XSProcRawRow *procRowBuf;
    size_t procRowCap;
};

/* ========================================================================== *
 * Pure Math Helpers (Public, Deterministic)
 * ========================================================================== */

double xs_calc_rapl_watts(uint64_t prevRaw, uint64_t currRaw, uint8_t esuBits, double dtSec) {
    if (!(dtSec > 0.0) || dtSec > 10.0 || esuBits > 31) {
        return 0.0;
    }
    uint32_t deltaTicks = (uint32_t)((uint32_t)currRaw - (uint32_t)prevRaw);
    double joules = (double)deltaTicks / (double)(1ULL << esuBits);
    return joules / dtSec;
}

double xs_calc_aperf_mhz(uint64_t deltaAcnt, uint64_t deltaMcnt, double baseMHz) {
    if (deltaMcnt == 0 || !(baseMHz > 0.0)) {
        return 0.0;
    }
    return (baseMHz * (double)deltaAcnt) / (double)deltaMcnt;
}

double xs_calc_battery_watts(int64_t voltageMV, uint64_t rawInstantAmperage, int32_t *outSignedMA) {
    int64_t signedAmp = (int64_t)rawInstantAmperage;
    /* Handle both 64-bit sign-extended and raw 16-bit two's-complement mA */
    if (signedAmp > 32767 && signedAmp <= 65535) {
        signedAmp = (int64_t)(int16_t)(uint16_t)rawInstantAmperage;
    }
    if (signedAmp < INT32_MIN) signedAmp = INT32_MIN;
    if (signedAmp > INT32_MAX) signedAmp = INT32_MAX;
    int32_t ma = (int32_t)signedAmp;
    if (outSignedMA) {
        *outSignedMA = ma;
    }
    if (voltageMV <= 0) {
        return 0.0;
    }
    return ((double)voltageMV * (double)ma) / 1000000.0;
}

double xs_calc_battery_power(int64_t voltageMV, int64_t designCapacity, uint64_t rawRate, int32_t *outSignedMA) {
    int64_t signedRate = (int64_t)rawRate;
    if (signedRate > 32767 && signedRate <= 65535) {
        signedRate = (int64_t)(int16_t)(uint16_t)rawRate;
    }
    if (signedRate < INT32_MIN) signedRate = INT32_MIN;
    if (signedRate > INT32_MAX) signedRate = INT32_MAX;

    /* Detect ACPI mWh/mW batteries where SMCBatteryManager left _BIF/_BST unscaled
     * (e.g. X-STATION V2: DesignCapacity=41349 mWh @ 11550 mV -> 477.6M > 150M mV*mAh). */
    bool rateIsMilliwatts = (designCapacity > 0 &&
                             voltageMV > 5000 &&
                             (designCapacity * voltageMV) > 150000000LL);
    if (rateIsMilliwatts) {
        double watts = (double)signedRate / 1000.0;
        if (outSignedMA) {
            *outSignedMA = (voltageMV > 0)
                ? (int32_t)llround(((double)signedRate * 1000.0) / (double)voltageMV)
                : (int32_t)signedRate;
        }
        return watts;
    }

    return xs_calc_battery_watts(voltageMV, rawRate, outSignedMA);
}

double xs_step_battery_discharge_tracking(
    XSBatteryDischargeTracker *tracker,
    bool isPluggedIn,
    bool isCharging,
    bool isFullyCharged,
    int64_t rawRate,
    double rawBatteryWatts,
    double currentPkgWatts,
    uint64_t nowMonoNs)
{
    if (!tracker) {
        return rawBatteryWatts;
    }

    if (isPluggedIn) {
        memset(tracker, 0, sizeof(*tracker));
        if (isFullyCharged && !isCharging) {
            return 0.0;
        }
        if (!isCharging && rawBatteryWatts < 0.0) {
            return 0.0;
        }
        return rawBatteryWatts;
    }

    /* Pure DC battery discharge: if EC has not yet flipped rate negative at unplug instant,
     * synthesize immediate discharge from live SoC RAPL + baseline platform draw (~3.5 W). */
    if (rawBatteryWatts >= -0.05) {
        double pkg = (currentPkgWatts > 0.2) ? currentPkgWatts : 1.5;
        return -(pkg + 3.5);
    }

    bool freshGauge = !tracker->onBatteryActive || (rawRate != tracker->lastRawRate);
    if (freshGauge) {
        tracker->onBatteryActive = true;
        tracker->lastRawRate = rawRate;
        tracker->anchorWatts = rawBatteryWatts;
        tracker->anchorPkgWatts = (currentPkgWatts > 0.0) ? currentPkgWatts : 0.0;
        tracker->anchorMonoNs = nowMonoNs;
        return rawBatteryWatts;
    }

    if (tracker->anchorPkgWatts <= 0.0 && currentPkgWatts > 0.0) {
        tracker->anchorPkgWatts = currentPkgWatts;
    }

    if (nowMonoNs > tracker->anchorMonoNs &&
        (nowMonoNs - tracker->anchorMonoNs) >= 1500000000ULL &&
        currentPkgWatts > 0.0 &&
        tracker->anchorPkgWatts > 0.0) {
        double deltaPkgW = currentPkgWatts - tracker->anchorPkgWatts;
        double liveWatts = tracker->anchorWatts - deltaPkgW;
        double minDischargeMag = currentPkgWatts + 0.5;
        if (liveWatts > -minDischargeMag) {
            liveWatts = -minDischargeMag;
        }
        return liveWatts;
    }

    return tracker->anchorWatts;
}

/* ========================================================================== *
 * CoreFoundation / IOKit Property Helpers (Zero-Leak)
 * ========================================================================== */

static bool xs_dict_get_int64(CFDictionaryRef dict, CFStringRef key, int64_t *outVal) {
    if (!dict) return false;
    CFTypeRef ref = CFDictionaryGetValue(dict, key);
    if (!ref || CFGetTypeID(ref) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt64Type, outVal);
}

static int64_t xs_dict_int64_or(CFDictionaryRef dict, CFStringRef key, int64_t fallback) {
    int64_t v = fallback;
    return xs_dict_get_int64(dict, key, &v) ? v : fallback;
}

static bool xs_dict_bool_or(CFDictionaryRef dict, CFStringRef key, bool fallback) {
    if (!dict) return fallback;
    CFTypeRef ref = CFDictionaryGetValue(dict, key);
    if (!ref) return fallback;
    if (CFGetTypeID(ref) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)ref);
    }
    if (CFGetTypeID(ref) == CFNumberGetTypeID()) {
        int64_t v = 0;
        if (CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt64Type, &v)) {
            return v != 0;
        }
    }
    return fallback;
}

static void xs_dict_copy_cstr(CFDictionaryRef dict, CFStringRef key, char *dst, size_t dstCap) {
    if (!dst || dstCap == 0) return;
    dst[0] = '\0';
    if (!dict) return;
    CFTypeRef ref = CFDictionaryGetValue(dict, key);
    if (!ref || CFGetTypeID(ref) != CFStringGetTypeID()) return;
    if (!CFStringGetCString((CFStringRef)ref, dst, (CFIndex)dstCap, kCFStringEncodingUTF8)) {
        dst[0] = '\0';
    }
}

static bool xs_reg_get_int64(io_registry_entry_t entry, CFStringRef key, int64_t *outVal) {
    if (entry == IO_OBJECT_NULL) return false;
    CFTypeRef prop = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!prop) return false;
    bool ok = false;
    if (CFGetTypeID(prop) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt64Type, outVal);
    }
    CFRelease(prop);
    return ok;
}

/* ========================================================================== *
 * AppleSMC Helpers
 * ========================================================================== */

static bool xs_smc_get_key_info(io_connect_t conn, uint32_t key, XSSMCKeyInfo *outInfo) {
    if (conn == IO_OBJECT_NULL || !outInfo) return false;
    XSSMCKeyData inData;
    XSSMCKeyData outData;
    memset(&inData, 0, sizeof(inData));
    memset(&outData, 0, sizeof(outData));
    inData.key = key;
    inData.data8 = XS_SMC_CMD_READ_KEYINFO;

    size_t outSize = sizeof(outData);
    kern_return_t kr = IOConnectCallStructMethod(
        conn, XS_SMC_KERNEL_INDEX, &inData, sizeof(inData), &outData, &outSize);
    if (kr != KERN_SUCCESS || outData.result != 0 || outData.keyInfo.dataSize == 0) {
        return false;
    }
    *outInfo = outData.keyInfo;
    return true;
}

static bool xs_smc_read_temp(io_connect_t conn, uint32_t key, const XSSMCKeyInfo *info, double *outTempC) {
    if (conn == IO_OBJECT_NULL || !info || info->dataSize == 0 || !outTempC) return false;
    XSSMCKeyData inData;
    XSSMCKeyData outData;
    memset(&inData, 0, sizeof(inData));
    memset(&outData, 0, sizeof(outData));
    inData.key = key;
    inData.keyInfo.dataSize = info->dataSize;
    inData.data8 = XS_SMC_CMD_READ_BYTES;

    size_t outSize = sizeof(outData);
    kern_return_t kr = IOConnectCallStructMethod(
        conn, XS_SMC_KERNEL_INDEX, &inData, sizeof(inData), &outData, &outSize);
    if (kr != KERN_SUCCESS || outData.result != 0) {
        return false;
    }

    double val = 0.0;
    uint32_t dt = info->dataType;
    if (dt == xs_fourcc("sp78") && info->dataSize >= 2) {
        int16_t raw = (int16_t)(((uint16_t)outData.bytes[0] << 8) | (uint16_t)outData.bytes[1]);
        val = (double)raw / 256.0;
    } else if (dt == xs_fourcc("flt ") && info->dataSize >= 4) {
        float f = 0.0f;
        memcpy(&f, outData.bytes, sizeof(float));
        val = (double)f;
    } else if (dt == xs_fourcc("ui8 ") && info->dataSize >= 1) {
        val = (double)outData.bytes[0];
    } else if (dt == xs_fourcc("ui16") && info->dataSize >= 2) {
        val = (double)(((uint16_t)outData.bytes[0] << 8) | (uint16_t)outData.bytes[1]);
    } else {
        return false;
    }

    if (!(val > 1.0 && val < 125.0)) {
        return false;
    }
    *outTempC = val;
    return true;
}

static bool xs_smc_read_raw_bytes(
    io_connect_t conn,
    uint32_t key,
    const XSSMCKeyInfo *info,
    uint8_t outBytes[32])
{
    if (conn == IO_OBJECT_NULL || !info || info->dataSize == 0 || info->dataSize > 32 || !outBytes) {
        return false;
    }
    XSSMCKeyData inData;
    XSSMCKeyData outData;
    memset(&inData, 0, sizeof(inData));
    memset(&outData, 0, sizeof(outData));
    inData.key = key;
    inData.keyInfo.dataSize = info->dataSize;
    inData.data8 = XS_SMC_CMD_READ_BYTES;

    size_t outSize = sizeof(outData);
    kern_return_t kr = IOConnectCallStructMethod(
        conn, XS_SMC_KERNEL_INDEX, &inData, sizeof(inData), &outData, &outSize);
    if (kr != KERN_SUCCESS || outData.result != 0) {
        return false;
    }
    memcpy(outBytes, outData.bytes, 32);
    return true;
}

static void xs_probe_smc_keys(XSBridgeContext *ctx) {
    ctx->smcProbed = true;
    ctx->smcHasTemp = false;
    ctx->smcPkgKey = 0;
    ctx->smcCoreCount = 0;
    ctx->smcHasAcin = false;
    ctx->smcHasB0ac = false;
    ctx->smcHasB0av = false;

    if (ctx->smcConn == IO_OBJECT_NULL) {
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (svc != IO_OBJECT_NULL) {
            if (IOServiceOpen(svc, mach_task_self(), 0, &ctx->smcConn) != KERN_SUCCESS) {
                ctx->smcConn = IO_OBJECT_NULL;
            }
            IOObjectRelease(svc);
        }
    }
    if (ctx->smcConn == IO_OBJECT_NULL) {
        return;
    }

    static const char *const pkgCandidates[] = { "TC0P", "TC0D", "TC0E", "TC0F" };
    for (size_t i = 0; i < sizeof(pkgCandidates) / sizeof(pkgCandidates[0]); ++i) {
        uint32_t k = xs_fourcc(pkgCandidates[i]);
        XSSMCKeyInfo info;
        double testC = 0.0;
        if (xs_smc_get_key_info(ctx->smcConn, k, &info) &&
            xs_smc_read_temp(ctx->smcConn, k, &info, &testC)) {
            ctx->smcPkgKey = k;
            ctx->smcPkgInfo = info;
            ctx->smcHasTemp = true;
            break;
        }
    }

    static const char *const coreBank0[] = { "TC0C", "TC1C", "TC2C", "TC3C", "TC4C", "TC5C", "TC6C", "TC7C" };
    for (size_t i = 0; i < 8; ++i) {
        uint32_t k = xs_fourcc(coreBank0[i]);
        XSSMCKeyInfo info;
        double testC = 0.0;
        if (xs_smc_get_key_info(ctx->smcConn, k, &info) &&
            xs_smc_read_temp(ctx->smcConn, k, &info, &testC)) {
            ctx->smcCoreKeys[ctx->smcCoreCount] = k;
            ctx->smcCoreInfos[ctx->smcCoreCount] = info;
            ctx->smcCoreCount++;
            ctx->smcHasTemp = true;
        }
    }

    uint8_t testBytes[32];
    XSSMCKeyInfo bInfo;
    if (xs_smc_get_key_info(ctx->smcConn, xs_fourcc("ACIN"), &bInfo) &&
        bInfo.dataSize >= 1 &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("ACIN"), &bInfo, testBytes)) {
        ctx->smcAcinInfo = bInfo;
        ctx->smcHasAcin = true;
    }
    if (xs_smc_get_key_info(ctx->smcConn, xs_fourcc("B0AC"), &bInfo) &&
        bInfo.dataSize >= 2 &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("B0AC"), &bInfo, testBytes)) {
        ctx->smcB0acInfo = bInfo;
        ctx->smcHasB0ac = true;
    }
    if (xs_smc_get_key_info(ctx->smcConn, xs_fourcc("B0AV"), &bInfo) &&
        bInfo.dataSize >= 2 &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("B0AV"), &bInfo, testBytes)) {
        ctx->smcB0avInfo = bInfo;
        ctx->smcHasB0av = true;
    }
}

/* ========================================================================== *
 * libIOReport Initialization & Channel Reading
 * ========================================================================== */

static int64_t xs_ioreport_read_int(const XSBridgeContext *ctx, CFDictionaryRef ch) {
    if (ctx->pSimpleGetIntegerValue) {
        return ctx->pSimpleGetIntegerValue(ch, 0);
    }
    /* Raw 64-byte IOReportElement fallback: integer payload at byte offset +32 */
    CFTypeRef raw = CFDictionaryGetValue(ch, CFSTR("RawElements"));
    if (raw && CFGetTypeID(raw) == CFDataGetTypeID()) {
        CFDataRef data = (CFDataRef)raw;
        if (CFDataGetLength(data) >= 40) {
            int64_t val = 0;
            memcpy(&val, CFDataGetBytePtr(data) + 32, sizeof(int64_t));
            return val;
        }
    }
    return 0;
}

static void xs_init_ioreport(XSBridgeContext *ctx) {
    ctx->ioReportDylib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!ctx->ioReportDylib) {
        return;
    }

    ctx->pCopyChannelsInGroup = (fn_IOReportCopyChannelsInGroup)dlsym(ctx->ioReportDylib, "IOReportCopyChannelsInGroup");
    ctx->pMergeChannels = (fn_IOReportMergeChannels)dlsym(ctx->ioReportDylib, "IOReportMergeChannels");
    ctx->pCreateSubscription = (fn_IOReportCreateSubscription)dlsym(ctx->ioReportDylib, "IOReportCreateSubscription");
    ctx->pCreateSamples = (fn_IOReportCreateSamples)dlsym(ctx->ioReportDylib, "IOReportCreateSamples");
    ctx->pIterate = (fn_IOReportIterate)dlsym(ctx->ioReportDylib, "IOReportIterate");
    ctx->pChannelGetGroup = (fn_IOReportChannelGetGroup)dlsym(ctx->ioReportDylib, "IOReportChannelGetGroup");
    ctx->pChannelGetChannelName = (fn_IOReportChannelGetChannelName)dlsym(ctx->ioReportDylib, "IOReportChannelGetChannelName");
    ctx->pSimpleGetIntegerValue = (fn_IOReportSimpleGetIntegerValue)dlsym(ctx->ioReportDylib, "IOReportSimpleGetIntegerValue");

    if (!ctx->pCopyChannelsInGroup || !ctx->pMergeChannels ||
        !ctx->pCreateSubscription || !ctx->pCreateSamples ||
        !ctx->pIterate || !ctx->pChannelGetGroup || !ctx->pChannelGetChannelName) {
        return;
    }

    /* Subscribe only to subgroup "msr" inside "pmtelemetry_cpu" (skips ~135 unused counter channels),
     * falling back to the full "pmtelemetry_cpu" group if subgroup "msr" is absent. */
    CFDictionaryRef cpuCh = ctx->pCopyChannelsInGroup(CFSTR("pmtelemetry_cpu"), CFSTR("msr"), 0, 0, 0);
    if (!cpuCh) {
        cpuCh = ctx->pCopyChannelsInGroup(CFSTR("pmtelemetry_cpu"), NULL, 0, 0, 0);
    }
    CFDictionaryRef gpuCh = ctx->pCopyChannelsInGroup(CFSTR("GPU C-States"), NULL, 0, 0, 0);

    CFMutableDictionaryRef merged = NULL;
    if (cpuCh) {
        merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, cpuCh);
        CFRelease(cpuCh);
    }
    if (gpuCh) {
        if (merged) {
            ctx->pMergeChannels(merged, gpuCh, NULL);
        } else {
            merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, gpuCh);
        }
        CFRelease(gpuCh);
    }
    if (!merged) {
        return;
    }

    CFMutableDictionaryRef subbed = NULL;
    ctx->ioSub = ctx->pCreateSubscription(NULL, merged, &subbed, 0, NULL);
    ctx->ioSubbedChannels = subbed;
    CFRelease(merged);
}

static bool xs_sample_ioreport_raw(const XSBridgeContext *ctx, XSIOReportRawSample *out) {
    memset(out, 0, sizeof(*out));
    out->esuBits = 14; /* Tiger Lake default 2^-14 J if SKU unit channel missing */

    if (!ctx->ioSub || !ctx->ioSubbedChannels || !ctx->pCreateSamples || !ctx->pIterate) {
        return false;
    }

    CFDictionaryRef samples = ctx->pCreateSamples(ctx->ioSub, ctx->ioSubbedChannels, NULL);
    if (!samples) {
        return false;
    }

    __block XSIOReportRawSample snap = *out;
    ctx->pIterate(samples, ^int(CFDictionaryRef ch) {
        CFStringRef group = ctx->pChannelGetGroup(ch);
        CFStringRef nameRef = ctx->pChannelGetChannelName(ch);
        if (!group || !nameRef) {
            return 0;
        }

        char name[64];
        if (!CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8)) {
            return 0;
        }

        uint64_t uval = (uint64_t)xs_ioreport_read_int(ctx, ch);

        if (CFStringCompare(group, CFSTR("GPU C-States"), 0) == kCFCompareEqualTo) {
            if (strcmp(name, "RC0") == 0) {
                snap.rc0 = uval;
            } else if (strcmp(name, "RC1") == 0) {
                snap.rc1 = uval;
            } else if (strcmp(name, "RC6") == 0) {
                snap.rc6 = uval;
            }
            return 0;
        }

        if (CFStringCompare(group, CFSTR("pmtelemetry_cpu"), 0) == kCFCompareEqualTo) {
            if (strncmp(name, "MSR_IA32_ACNT ", 14) == 0) {
                long idx = strtol(name + 14, NULL, 10);
                if (idx >= 0 && idx < XS_MAX_THREADS) {
                    snap.acnt[idx] = uval;
                }
            } else if (strncmp(name, "MSR_IA32_MCNT ", 14) == 0) {
                long idx = strtol(name + 14, NULL, 10);
                if (idx >= 0 && idx < XS_MAX_THREADS) {
                    snap.mcnt[idx] = uval;
                }
            } else if (strcmp(name, "MSR_IA32_PKG_POWER_SKU_UNIT") == 0) {
                uint8_t esu = (uint8_t)((uval >> 8) & 0x1FU);
                if (esu > 0 && esu <= 31) {
                    snap.esuBits = esu;
                }
            } else if (strcmp(name, "MSR_IA32_PKG_ENERGY_STATUS") == 0) {
                snap.pkgEnergy = uval;
            } else if (strcmp(name, "MSR_IA32_PP0_ENERGY_STATUS") == 0) {
                snap.pp0Energy = uval;
            } else if (strcmp(name, "MSR_IA32_PP1_ENERGY_STATUS") == 0) {
                snap.pp1Energy = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C2_RESIDENCY") == 0) {
                snap.pkgCResidency[0] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C3_RESIDENCY") == 0) {
                snap.pkgCResidency[1] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C6_RESIDENCY") == 0) {
                snap.pkgCResidency[2] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C7_RESIDENCY") == 0) {
                snap.pkgCResidency[3] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C8_RESIDENCY") == 0) {
                snap.pkgCResidency[4] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C9_RESIDENCY") == 0) {
                snap.pkgCResidency[5] = uval;
            } else if (strcmp(name, "MSR_IA32_PKG_C10_RESIDENCY") == 0) {
                snap.pkgCResidency[6] = uval;
            }
        }
        return 0;
    });

    CFRelease(samples);
    *out = snap;
    return true;
}

/* ========================================================================== *
 * Subsystem Collectors
 * ========================================================================== */

static void xs_sample_cpu_mach(XSBridgeContext *ctx, XSCpuMetrics *cpu) {
    natural_t cpuCount = 0;
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t numCpuInfo = 0;

    kern_return_t kr = host_processor_info(
        ctx->hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &numCpuInfo);
    if (kr != KERN_SUCCESS || !cpuInfo) {
        return;
    }

    uint32_t n = (cpuCount > XS_MAX_THREADS) ? XS_MAX_THREADS : (uint32_t)cpuCount;
    cpu->threadCount = n;

    uint64_t sumUser = 0;
    uint64_t sumSys = 0;
    uint64_t sumTotal = 0;

    for (uint32_t i = 0; i < n; ++i) {
        uint32_t u = (uint32_t)cpuInfo[i * CPU_STATE_MAX + CPU_STATE_USER];
        uint32_t s = (uint32_t)cpuInfo[i * CPU_STATE_MAX + CPU_STATE_SYSTEM];
        uint32_t ni = (uint32_t)cpuInfo[i * CPU_STATE_MAX + CPU_STATE_NICE];
        uint32_t id = (uint32_t)cpuInfo[i * CPU_STATE_MAX + CPU_STATE_IDLE];

        if (ctx->hasCpuTickBaseline && i < ctx->prevCpuCount) {
            uint32_t du = u - ctx->prevUser[i];
            uint32_t ds = s - ctx->prevSys[i];
            uint32_t dni = ni - ctx->prevNice[i];
            uint32_t did = id - ctx->prevIdle[i];
            uint64_t dtot = (uint64_t)du + ds + dni + did;
            if (dtot > 0) {
                cpu->threadUsage[i] = ((double)(du + ds + dni) / (double)dtot) * 100.0;
            }
            sumUser += (uint64_t)du + dni;
            sumSys += (uint64_t)ds;
            sumTotal += dtot;
        }

        ctx->prevUser[i] = u;
        ctx->prevSys[i] = s;
        ctx->prevNice[i] = ni;
        ctx->prevIdle[i] = id;
    }

    ctx->prevCpuCount = n;
    ctx->hasCpuTickBaseline = true;

    if (sumTotal > 0) {
        cpu->userUsage = ((double)sumUser / (double)sumTotal) * 100.0;
        cpu->sysUsage = ((double)sumSys / (double)sumTotal) * 100.0;
        cpu->totalUsage = cpu->userUsage + cpu->sysUsage;
    }

    vm_deallocate(mach_task_self(), (vm_address_t)cpuInfo, (vm_size_t)numCpuInfo * sizeof(integer_t));
}

static void xs_sample_cpu_temps(XSBridgeContext *ctx, XSCpuMetrics *cpu) {
    if (!ctx->smcProbed) {
        xs_probe_smc_keys(ctx);
    }
    if (!ctx->smcHasTemp) {
        cpu->hasTemp = false;
        return;
    }

    bool anyRead = false;
    double maxCoreC = 0.0;
    uint32_t outCount = 0;

    for (uint32_t i = 0; i < ctx->smcCoreCount && outCount < 8; ++i) {
        double c = 0.0;
        if (xs_smc_read_temp(ctx->smcConn, ctx->smcCoreKeys[i], &ctx->smcCoreInfos[i], &c)) {
            cpu->coreTempC[outCount++] = c;
            if (c > maxCoreC) maxCoreC = c;
            anyRead = true;
        }
    }
    cpu->coreTempCount = outCount;

    double pkgC = 0.0;
    if (ctx->smcPkgKey != 0 &&
        xs_smc_read_temp(ctx->smcConn, ctx->smcPkgKey, &ctx->smcPkgInfo, &pkgC)) {
        cpu->packageTempC = pkgC;
        anyRead = true;
    } else if (outCount > 0) {
        cpu->packageTempC = maxCoreC;
    }

    cpu->hasTemp = anyRead;
}

static bool xs_iokit_read_s0ix_int(void *userCtx, const char *key, int64_t *outVal) {
    XSBridgeContext *ctx = (XSBridgeContext *)userCtx;
    if (!ctx || ctx->s0ixService == IO_OBJECT_NULL || !key) return false;
    if (strcmp(key, "GPU Current Freq MHz") == 0) {
        return xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Current Freq MHz"), outVal);
    }
    if (strcmp(key, "GPU Requested Freq MHz") == 0) {
        return xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Requested Freq MHz"), outVal);
    }
    CFStringRef cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cfKey) return false;
    bool ok = xs_reg_get_int64(ctx->s0ixService, cfKey, outVal);
    CFRelease(cfKey);
    return ok;
}

static bool xs_iokit_trigger_s0ix_refresh(void *userCtx) {
    XSBridgeContext *ctx = (XSBridgeContext *)userCtx;
    if (!ctx || ctx->s0ixService == IO_OBJECT_NULL || !ctx->refreshGpuFreqDict) return false;
    return IORegistryEntrySetCFProperties(ctx->s0ixService, ctx->refreshGpuFreqDict) == KERN_SUCCESS;
}

void xs_step_s0ix_gpu_freq(
    XSGpuFreqProbeState *state,
    double gpuUsagePct,
    XSGpuReadRegIntFn readInt,
    XSGpuTriggerRefreshFn triggerRefresh,
    void *userCtx,
    XSGpuMetrics *gpu)
{
    if (!state || !readInt || !gpu) return;

    bool refreshedThisTick = false;

    if (!state->freqProbed) {
        int64_t passiveMHz = 0;
        if (readInt(userCtx, "GPU Current Freq MHz", &passiveMHz)) {
            state->freqProbed = true;
            state->supportsGpuFreq = true;
        } else if (gpuUsagePct >= 0.5) {
            state->refreshCallCount++;
            bool setOk = triggerRefresh ? triggerRefresh(userCtx) : false;
            refreshedThisTick = true;
            int64_t probedMHz = 0;
            if (setOk && readInt(userCtx, "GPU Current Freq MHz", &probedMHz)) {
                state->freqProbed = true;
                state->supportsGpuFreq = true;
            } else {
                state->freqProbed = true;
                state->supportsGpuFreq = false;
            }
        }
        /* When gpuUsagePct < 0.5 and passive property is absent:
         * neither invoke triggerRefresh nor latch freqProbed. */
    }

    if (state->supportsGpuFreq) {
        gpu->hasFreq = true;
        if (gpuUsagePct < 0.5) {
            /* Idle in RC6: report 0 MHz directly without entering kernel MMIO */
            gpu->currentFreqMHz = 0;
            gpu->requestedFreqMHz = 0;
        } else {
            if (!refreshedThisTick && triggerRefresh) {
                state->refreshCallCount++;
                (void)triggerRefresh(userCtx);
            }
            int64_t curMHz = 0;
            int64_t reqMHz = 0;
            if (readInt(userCtx, "GPU Current Freq MHz", &curMHz) && curMHz >= 0) {
                gpu->currentFreqMHz = (uint32_t)curMHz;
            }
            if (readInt(userCtx, "GPU Requested Freq MHz", &reqMHz) && reqMHz >= 0) {
                gpu->requestedFreqMHz = (uint32_t)reqMHz;
            }
        }
    } else {
        gpu->hasFreq = false;
        gpu->currentFreqMHz = 0;
        gpu->requestedFreqMHz = 0;
    }
}

uint64_t xs_bridge_gpu_freq_refresh_count(const XSBridgeContext *ctx) {
    return ctx ? ctx->gpuFreqState.refreshCallCount : 0;
}

static void xs_sample_gpu_registry(XSBridgeContext *ctx, uint64_t nowMonoNs, XSGpuMetrics *gpu) {
    bool canReuseIdleGart = (gpu->usagePct < 0.5) &&
                            (ctx->gpuRegSampleCount >= 2) &&
                            (nowMonoNs > ctx->lastGpuRegSampleNs) &&
                            ((nowMonoNs - ctx->lastGpuRegSampleNs) < 5500000000ULL);

    if (canReuseIdleGart) {
        gpu->gartUsedBytes = ctx->cachedGartUsedBytes;
        gpu->gartSizeBytes = ctx->cachedGartSizeBytes;
        gpu->sinkRestoreOk = ctx->cachedSinkOk;
        gpu->sinkRestoreRetries = ctx->cachedSinkRetries;
    } else {
        if (ctx->accelService == IO_OBJECT_NULL) {
            ctx->accelService = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceMatching("IntelAccelerator"));
        }

        if (ctx->accelService != IO_OBJECT_NULL) {
            CFTypeRef perfRef = IORegistryEntryCreateCFProperty(
                ctx->accelService, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (perfRef && CFGetTypeID(perfRef) == CFDictionaryGetTypeID()) {
                CFDictionaryRef perf = (CFDictionaryRef)perfRef;
                /* Read strictly gartUsedBytes / gartSizeBytes; ignore inUseSysMemoryBytes (Gen12 underflow) */
                int64_t gartUsed = xs_dict_int64_or(perf, CFSTR("gartUsedBytes"), 0);
                int64_t gartSize = xs_dict_int64_or(perf, CFSTR("gartSizeBytes"), 0);
                if (gartUsed > 0) gpu->gartUsedBytes = (uint64_t)gartUsed;
                if (gartSize > 0) gpu->gartSizeBytes = (uint64_t)gartSize;
            }
            if (perfRef) {
                CFRelease(perfRef);
            }
        }

        /* TGLSinkRestoreRate: check IntelAccelerator first, then IORegistry Root (WhateverXe telemetry location) */
        int64_t sinkRaw = 0;
        bool gotSink = false;
        if (!ctx->sinkKnownOnRoot) {
            gotSink = xs_reg_get_int64(ctx->accelService, CFSTR("TGLSinkRestoreRate"), &sinkRaw);
        }
        if (!gotSink) {
            if (ctx->rootEntry == IO_OBJECT_NULL) {
                ctx->rootEntry = IORegistryGetRootEntry(kIOMainPortDefault);
            }
            gotSink = xs_reg_get_int64(ctx->rootEntry, CFSTR("TGLSinkRestoreRate"), &sinkRaw);
            if (gotSink) {
                ctx->sinkKnownOnRoot = true;
            }
        }
        if (gotSink && sinkRaw >= 0) {
            uint64_t u = (uint64_t)sinkRaw;
            gpu->sinkRestoreRetries = (uint32_t)(u >> 24);
            gpu->sinkRestoreOk = (uint32_t)(u & 0xFFFFFFU);
        }

        ctx->gpuRegSampleCount++;
        ctx->lastGpuRegSampleNs = nowMonoNs;
        ctx->cachedGartUsedBytes = gpu->gartUsedBytes;
        ctx->cachedGartSizeBytes = gpu->gartSizeBytes;
        ctx->cachedSinkOk = gpu->sinkRestoreOk;
        ctx->cachedSinkRetries = gpu->sinkRestoreRetries;
    }

    /* Optional Gen12 GPU frequency export from S0ixStandby (EFI v2.0.1+) */
    if (ctx->s0ixService == IO_OBJECT_NULL) {
        ctx->s0ixService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("S0ixStandby"));
    }
    if (ctx->s0ixService != IO_OBJECT_NULL) {
        xs_step_s0ix_gpu_freq(
            &ctx->gpuFreqState,
            gpu->usagePct,
            xs_iokit_read_s0ix_int,
            xs_iokit_trigger_s0ix_refresh,
            ctx,
            gpu);
    }
}

static void xs_sample_memory(XSBridgeContext *ctx, XSMemoryMetrics *mem) {
    mem->totalBytes = ctx->totalMemBytes;

    vm_statistics64_data_t vmstat;
    memset(&vmstat, 0, sizeof(vmstat));
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(ctx->hostPort, HOST_VM_INFO64, (host_info64_t)&vmstat, &count) == KERN_SUCCESS) {
        uint64_t pageSize = (vm_kernel_page_size > 0) ? (uint64_t)vm_kernel_page_size : 4096ULL;
        uint64_t internalPages = (vmstat.internal_page_count > vmstat.purgeable_count)
            ? (uint64_t)(vmstat.internal_page_count - vmstat.purgeable_count)
            : 0ULL;
        mem->appBytes = internalPages * pageSize;
        mem->wiredBytes = (uint64_t)vmstat.wire_count * pageSize;
        mem->compressedBytes = (uint64_t)vmstat.compressor_page_count * pageSize;
        mem->usedBytes = mem->appBytes + mem->wiredBytes + mem->compressedBytes;
        if (mem->totalBytes > 0 && mem->usedBytes > mem->totalBytes) {
            mem->usedBytes = mem->totalBytes;
        }
        mem->cachedBytes = ((uint64_t)vmstat.external_page_count + (uint64_t)vmstat.purgeable_count) * pageSize;
    }

    struct xsw_usage swap;
    size_t swapLen = sizeof(swap);
    int swapRc = (ctx->swapMibLen > 0)
        ? sysctl(ctx->swapMib, (u_int)ctx->swapMibLen, &swap, &swapLen, NULL, 0)
        : sysctlbyname("vm.swapusage", &swap, &swapLen, NULL, 0);
    if (swapRc == 0) {
        mem->swapUsedBytes = swap.xsu_used;
        mem->swapTotalBytes = swap.xsu_total;
    }

    int32_t pressure = 1;
    size_t pLen = sizeof(pressure);
    int pressRc = (ctx->pressureMibLen > 0)
        ? sysctl(ctx->pressureMib, (u_int)ctx->pressureMibLen, &pressure, &pLen, NULL, 0)
        : sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pLen, NULL, 0);
    if (pressRc == 0) {
        mem->pressureLevel = pressure;
    } else {
        mem->pressureLevel = 1;
    }
}

static void xs_sample_power_s0ix(
    XSBridgeContext *ctx,
    uint64_t nowMonoNs,
    double currentPkgWatts,
    XSPowerMetrics *pwr)
{
    /* Sub-250ms burst guard for tight benchmark loops; every 1.0s/2.0s/5.0s UI tick executes live */
    if (ctx->powerSampleCount >= 2 &&
        nowMonoNs > ctx->lastPowerSampleNs &&
        (nowMonoNs - ctx->lastPowerSampleNs) < 250000000ULL) {
        *pwr = ctx->cachedPowerMetrics;
        return;
    }

    if (!ctx->smcProbed) {
        xs_probe_smc_keys(ctx);
    }

    /* Read live SMC ACIN / B0AC / B0AV first (bypasses AppleSmartBattery 30-60s IORegistry lag) */
    bool liveSmcAcValid = false;
    bool liveSmcPluggedIn = false;
    bool liveSmcRateValid = false;
    int64_t liveSmcRawRate = 0;
    bool liveSmcVoltValid = false;
    int64_t liveSmcVoltageMV = 0;
    uint8_t smcBuf[32];

    if (ctx->smcHasAcin &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("ACIN"), &ctx->smcAcinInfo, smcBuf)) {
        liveSmcPluggedIn = (smcBuf[0] != 0);
        liveSmcAcValid = true;
    }
    if (ctx->smcHasB0ac &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("B0AC"), &ctx->smcB0acInfo, smcBuf)) {
        int16_t s16 = (int16_t)(((uint16_t)smcBuf[0] << 8) | (uint16_t)smcBuf[1]);
        liveSmcRawRate = (int64_t)s16;
        liveSmcRateValid = true;
    }
    if (ctx->smcHasB0av &&
        xs_smc_read_raw_bytes(ctx->smcConn, xs_fourcc("B0AV"), &ctx->smcB0avInfo, smcBuf)) {
        uint16_t u16 = (uint16_t)(((uint16_t)smcBuf[0] << 8) | (uint16_t)smcBuf[1]);
        if (u16 > 3000) {
            liveSmcVoltageMV = (int64_t)u16;
            liveSmcVoltValid = true;
        }
    }

    /* 1. AppleSmartBattery IORegistry (refreshed every 1.5s or immediately on AC state flip) */
    if (ctx->batteryService == IO_OBJECT_NULL) {
        ctx->batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    }
    if (ctx->batteryService != IO_OBJECT_NULL) {
        bool acFlipped = liveSmcAcValid &&
                         ctx->hasBattRegCache &&
                         (liveSmcPluggedIn != ctx->cachedBattReg.isPluggedIn);
        bool regExpired = !ctx->hasBattRegCache ||
                          nowMonoNs <= ctx->lastBattRegSampleNs ||
                          (nowMonoNs - ctx->lastBattRegSampleNs) >= 1500000000ULL;

        if (acFlipped || regExpired) {
            CFMutableDictionaryRef battProps = NULL;
            if (IORegistryEntryCreateCFProperties(ctx->batteryService, &battProps, kCFAllocatorDefault, 0) == KERN_SUCCESS &&
                battProps != NULL) {
                XSPowerMetrics regSnap;
                memset(&regSnap, 0, sizeof(regSnap));
                regSnap.present = true;
                regSnap.isPluggedIn = xs_dict_bool_or(battProps, CFSTR("ExternalConnected"), false);
                regSnap.isCharging = xs_dict_bool_or(battProps, CFSTR("IsCharging"), false);
                regSnap.isFullyCharged = xs_dict_bool_or(battProps, CFSTR("FullyCharged"), false);

                int64_t curCap = xs_dict_int64_or(battProps, CFSTR("CurrentCapacity"), 0);
                int64_t maxCap = xs_dict_int64_or(battProps, CFSTR("MaxCapacity"), 0);
                if (maxCap > 0 && curCap >= 0) {
                    double pct = ((double)curCap / (double)maxCap) * 100.0;
                    if (pct > 100.0) pct = 100.0;
                    regSnap.percentage = pct;
                }

                int64_t rawMax = xs_dict_int64_or(battProps, CFSTR("AppleRawMaxCapacity"), maxCap);
                int64_t designCap = xs_dict_int64_or(battProps, CFSTR("DesignCapacity"), 0);
                if (designCap > 0 && rawMax > 0) {
                    regSnap.healthPct = ((double)rawMax / (double)designCap) * 100.0;
                }

                int64_t voltageMV = xs_dict_int64_or(battProps, CFSTR("Voltage"), 0);
                regSnap.voltageMV = (int32_t)voltageMV;

                int64_t rawAmp = 0;
                if (!xs_dict_get_int64(battProps, CFSTR("InstantAmperage"), &rawAmp)) {
                    (void)xs_dict_get_int64(battProps, CFSTR("Amperage"), &rawAmp);
                }
                regSnap.cycleCount = (int32_t)xs_dict_int64_or(battProps, CFSTR("CycleCount"), 0);

                ctx->cachedBattReg = regSnap;
                ctx->cachedDesignCapacity = designCap;
                ctx->cachedRegRawRate = rawAmp;
                ctx->hasBattRegCache = true;
                ctx->lastBattRegSampleNs = nowMonoNs;

                CFRelease(battProps);
            }
        }

        if (ctx->hasBattRegCache) {
            *pwr = ctx->cachedBattReg;
            if (liveSmcAcValid) {
                pwr->isPluggedIn = liveSmcPluggedIn;
                if (!liveSmcPluggedIn) {
                    pwr->isCharging = false;
                }
            }
            int64_t voltageMV = liveSmcVoltValid ? liveSmcVoltageMV : (int64_t)pwr->voltageMV;
            pwr->voltageMV = (int32_t)voltageMV;

            int64_t rawRate = liveSmcRateValid ? liveSmcRawRate : ctx->cachedRegRawRate;
            double rawBattWatts = xs_calc_battery_power(
                voltageMV, ctx->cachedDesignCapacity, (uint64_t)rawRate, &pwr->amperageMA);

            pwr->batteryWatts = xs_step_battery_discharge_tracking(
                &ctx->battTracker,
                pwr->isPluggedIn,
                pwr->isCharging,
                pwr->isFullyCharged,
                rawRate,
                rawBattWatts,
                currentPkgWatts,
                nowMonoNs);

            if (!pwr->isPluggedIn && voltageMV > 0) {
                pwr->amperageMA = (int32_t)llround((pwr->batteryWatts * 1000000.0) / (double)voltageMV);
            } else if (pwr->isPluggedIn && fabs(pwr->batteryWatts) < 1e-6) {
                pwr->amperageMA = 0;
            }
        }
    }

    /* 2. S0ixStandby */
    if (ctx->s0ixService == IO_OBJECT_NULL) {
        ctx->s0ixService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("S0ixStandby"));
    }
    if (ctx->s0ixService != IO_OBJECT_NULL) {
        int64_t liveSleepCount = 0;
        bool hasSleepProp = xs_reg_get_int64(ctx->s0ixService, CFSTR("Sleep count"), &liveSleepCount);
        uint32_t curSleepCount = (hasSleepProp && liveSleepCount > 0) ? (uint32_t)liveSleepCount : 0;

        bool needRefresh = !ctx->s0ixCacheValid ||
                           curSleepCount != ctx->cachedSleepCount ||
                           pwr->isPluggedIn != ctx->cachedPluggedIn ||
                           pwr->isFullyCharged != ctx->cachedFullyCharged;

        if (needRefresh) {
            CFMutableDictionaryRef s0ixProps = NULL;
            if (IORegistryEntryCreateCFProperties(ctx->s0ixService, &s0ixProps, kCFAllocatorDefault, 0) == KERN_SUCCESS &&
                s0ixProps != NULL) {
                ctx->s0ixCacheValid = true;
                ctx->cachedPluggedIn = pwr->isPluggedIn;
                ctx->cachedFullyCharged = pwr->isFullyCharged;

                int64_t sleepCount = xs_dict_int64_or(s0ixProps, CFSTR("Sleep count"), 0);
                int64_t lastSleepType = xs_dict_int64_or(s0ixProps, CFSTR("Last sleep type"), 0);
                ctx->cachedSleepCount = (sleepCount > 0) ? (uint32_t)sleepCount : 0;
                ctx->cachedLastSleepType = (lastSleepType > 0) ? (uint32_t)lastSleepType : 0;
                ctx->cachedLastCC7Pct = 0;
                ctx->cachedLastPC8Pct = 0;

                CFTypeRef haltC = CFDictionaryGetValue(s0ixProps, CFSTR("Last halt C-state percent"));
                if (haltC && CFGetTypeID(haltC) == CFDictionaryGetTypeID()) {
                    CFDictionaryRef cdict = (CFDictionaryRef)haltC;
                    int64_t cc7 = -1;
                    if (!xs_dict_get_int64(cdict, CFSTR("CC7 (boot core)"), &cc7)) {
                        (void)xs_dict_get_int64(cdict, CFSTR("CC7"), &cc7);
                    }
                    int64_t pc8 = xs_dict_int64_or(cdict, CFSTR("PC8"), -1);
                    if (cc7 >= 0) ctx->cachedLastCC7Pct = (uint32_t)cc7;
                    if (pc8 >= 0) ctx->cachedLastPC8Pct = (uint32_t)pc8;
                } else {
                    CFTypeRef lastC = CFDictionaryGetValue(s0ixProps, CFSTR("Last C-state percent"));
                    if (lastC && CFGetTypeID(lastC) == CFDictionaryGetTypeID()) {
                        int64_t pc8 = xs_dict_int64_or((CFDictionaryRef)lastC, CFSTR("PC8"), -1);
                        if (pc8 >= 0) ctx->cachedLastPC8Pct = (uint32_t)pc8;
                    }
                }

                char dispWake[256];
                xs_dict_copy_cstr(s0ixProps, CFSTR("Display power at wake"), dispWake, sizeof(dispWake));
                if (dispWake[0] == '\0') {
                    xs_dict_copy_cstr(s0ixProps, CFSTR("Display power at sleep"), dispWake, sizeof(dispWake));
                }
                ctx->cachedLastDC9 = (strstr(dispWake, "DC9") != NULL);

                xs_dict_copy_cstr(s0ixProps, CFSTR("Last wake source"), ctx->cachedLastWakeSource, sizeof(ctx->cachedLastWakeSource));
                xs_dict_copy_cstr(s0ixProps, CFSTR("AC EC wake block"), ctx->cachedAcEcWakeBlock, sizeof(ctx->cachedAcEcWakeBlock));
                xs_dict_copy_cstr(s0ixProps, CFSTR("Battery full state"), ctx->cachedBatteryFullState, sizeof(ctx->cachedBatteryFullState));

                CFRelease(s0ixProps);
            }
        }

        if (ctx->s0ixCacheValid) {
            pwr->hasS0ix = true;
            pwr->sleepCount = ctx->cachedSleepCount;
            pwr->lastSleepType = ctx->cachedLastSleepType;
            pwr->lastCC7Pct = ctx->cachedLastCC7Pct;
            pwr->lastPC8Pct = ctx->cachedLastPC8Pct;
            pwr->lastDC9 = ctx->cachedLastDC9;
            memcpy(pwr->lastWakeSource, ctx->cachedLastWakeSource, sizeof(pwr->lastWakeSource));
            memcpy(pwr->acEcWakeBlock, ctx->cachedAcEcWakeBlock, sizeof(pwr->acEcWakeBlock));
            memcpy(pwr->batteryFullState, ctx->cachedBatteryFullState, sizeof(pwr->batteryFullState));
        }
    }

    ctx->powerSampleCount++;
    ctx->lastPowerSampleNs = nowMonoNs;
    ctx->cachedPowerMetrics = *pwr;
}

/* ========================================================================== *
 * Storage (NVMe SMART + IOBlockStorageDriver) & Network (getifaddrs)
 * ========================================================================== */

static void xs_trim_copy_cstr(const char *src, size_t maxSrcLen, char *dst, size_t dstCap) {
    if (!dst || dstCap == 0) return;
    dst[0] = '\0';
    if (!src) return;

    size_t len = 0;
    while (len < maxSrcLen && src[len] != '\0') {
        len++;
    }
    size_t start = 0;
    while (start < len && isspace((unsigned char)src[start])) {
        start++;
    }
    while (len > start && isspace((unsigned char)src[len - 1])) {
        len--;
    }
    size_t copyLen = len - start;
    if (copyLen >= dstCap) {
        copyLen = dstCap - 1;
    }
    if (copyLen > 0) {
        memcpy(dst, src + start, copyLen);
    }
    dst[copyLen] = '\0';
}

static uint16_t xs_read_u16_le(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint64_t xs_read_u64_le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) {
        v |= ((uint64_t)p[i]) << (i * 8);
    }
    return v;
}

static void xs_init_storage_handles(XSBridgeContext *ctx) {
    if (ctx->storageProbed) {
        return;
    }
    ctx->storageProbed = true;

    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IONVMeBlockStorageDevice"),
            &iter) == KERN_SUCCESS &&
        iter != IO_OBJECT_NULL) {
        io_service_t best = IO_OBJECT_NULL;
        io_service_t obj = IO_OBJECT_NULL;
        while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
            bool isInternal = false;
            CFTypeRef protoRef = IORegistryEntryCreateCFProperty(
                obj, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
            if (protoRef && CFGetTypeID(protoRef) == CFDictionaryGetTypeID()) {
                char loc[32];
                xs_dict_copy_cstr(
                    (CFDictionaryRef)protoRef,
                    CFSTR("Physical Interconnect Location"),
                    loc,
                    sizeof(loc));
                if (strcmp(loc, "Internal") == 0) {
                    isInternal = true;
                }
            }
            if (protoRef) {
                CFRelease(protoRef);
            }

            if (best == IO_OBJECT_NULL) {
                best = obj;
                if (isInternal) {
                    break;
                }
            } else if (isInternal) {
                IOObjectRelease(best);
                best = obj;
                break;
            } else {
                IOObjectRelease(obj);
            }
        }
        IOObjectRelease(iter);
        ctx->nvmeBlockService = best;
    }

    if (ctx->nvmeBlockService != IO_OBJECT_NULL) {
        /* 1. Extract NVMe model string from Device Characteristics -> Product Name (or parent controller) */
        CFTypeRef devChars = IORegistryEntryCreateCFProperty(
            ctx->nvmeBlockService, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
        if (devChars && CFGetTypeID(devChars) == CFDictionaryGetTypeID()) {
            char rawModel[64];
            xs_dict_copy_cstr(
                (CFDictionaryRef)devChars, CFSTR("Product Name"), rawModel, sizeof(rawModel));
            xs_trim_copy_cstr(rawModel, sizeof(rawModel), ctx->nvmeModel, sizeof(ctx->nvmeModel));
        }
        if (devChars) {
            CFRelease(devChars);
        }

        if (ctx->nvmeModel[0] == '\0') {
            io_registry_entry_t parentCtrl = IO_OBJECT_NULL;
            if (IORegistryEntryGetParentEntry(
                    ctx->nvmeBlockService, kIOServicePlane, &parentCtrl) == KERN_SUCCESS &&
                parentCtrl != IO_OBJECT_NULL) {
                CFTypeRef modelRef = IORegistryEntryCreateCFProperty(
                    parentCtrl, CFSTR("Model Number"), kCFAllocatorDefault, 0);
                if (modelRef && CFGetTypeID(modelRef) == CFStringGetTypeID()) {
                    char rawModel[64];
                    if (CFStringGetCString(
                            (CFStringRef)modelRef, rawModel, sizeof(rawModel), kCFStringEncodingUTF8)) {
                        xs_trim_copy_cstr(rawModel, sizeof(rawModel), ctx->nvmeModel, sizeof(ctx->nvmeModel));
                    }
                }
                if (modelRef) {
                    CFRelease(modelRef);
                }
                IOObjectRelease(parentCtrl);
            }
        }

        /* 2. Locate child IOBlockStorageDriver specifically bound to this internal NVMe device */
        io_iterator_t childIter = IO_OBJECT_NULL;
        if (IORegistryEntryGetChildIterator(
                ctx->nvmeBlockService, kIOServicePlane, &childIter) == KERN_SUCCESS &&
            childIter != IO_OBJECT_NULL) {
            io_service_t child = IO_OBJECT_NULL;
            while ((child = IOIteratorNext(childIter)) != IO_OBJECT_NULL) {
                if (IOObjectConformsTo(child, "IOBlockStorageDriver")) {
                    ctx->blockDriverService = child;
                    break;
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(childIter);
        }
    }

    if (ctx->blockDriverService == IO_OBJECT_NULL) {
        ctx->blockDriverService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"));
    }
}

static void xs_sample_storage(XSBridgeContext *ctx, bool refreshSmart, XSStorageMetrics *sto) {
    xs_init_storage_handles(ctx);

    if (ctx->nvmeModel[0] != '\0') {
        memcpy(sto->model, ctx->nvmeModel, sizeof(sto->model));
        sto->model[sizeof(sto->model) - 1] = '\0';
    }

    /* 1. NVMe SMART Log Page 0x02 (512 bytes) — open/close transiently every 30s
     * so IONVMeSMARTUserClient is never held exclusively across idle/sleep or external tools. */
    if ((refreshSmart || !ctx->hasSmartCache) && ctx->nvmeBlockService != IO_OBJECT_NULL) {
        IOCFPlugInInterface **plugIn = NULL;
        IONVMeSMARTInterface **smartIf = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(
                ctx->nvmeBlockService,
                kIONVMeSMARTUserClientTypeID,
                kIOCFPlugInInterfaceID,
                &plugIn,
                &score) == KERN_SUCCESS &&
            plugIn != NULL) {
            HRESULT hr = (*plugIn)->QueryInterface(
                plugIn,
                CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                (LPVOID *)&smartIf);
            if (hr != S_OK || smartIf == NULL) {
                smartIf = NULL;
                IODestroyPlugInInterface(plugIn);
                plugIn = NULL;
            }
        }

        if (smartIf != NULL) {
            NVMeSMARTData smartData;
            memset(&smartData, 0, sizeof(smartData));

            IOReturn kr = kIOReturnError;
            if ((*smartIf)->SMARTReadData != NULL) {
                kr = (*smartIf)->SMARTReadData(smartIf, &smartData);
            }
            if (kr != kIOReturnSuccess && (*smartIf)->GetLogPage != NULL) {
                kr = (*smartIf)->GetLogPage(
                    smartIf,
                    &smartData,
                    0x02U,
                    (uint32_t)(sizeof(NVMeSMARTData) / 4U) - 1U);
            }

            if (kr == kIOReturnSuccess) {
                const uint8_t *buf = (const uint8_t *)&smartData;
                uint16_t tempK = xs_read_u16_le(buf + 1);
                XSStorageMetrics cached;
                memset(&cached, 0, sizeof(cached));
                cached.hasSmart = (tempK > 0);
                cached.tempC = (tempK > 0) ? ((int32_t)tempK - 273) : 0;
                cached.availableSparePct = (int32_t)buf[3];
                cached.lifeUsedPct = (int32_t)buf[5];
                cached.dataReadTB = ((double)xs_read_u64_le(buf + 32) * 512000.0) / 1e12;
                cached.dataWrittenTB = ((double)xs_read_u64_le(buf + 48) * 512000.0) / 1e12;
                cached.powerCycles = xs_read_u64_le(buf + 112);
                cached.powerOnHours = xs_read_u64_le(buf + 128);
                cached.unsafeShutdowns = xs_read_u64_le(buf + 144);

                if (ctx->nvmeModel[0] == '\0' && (*smartIf)->GetIdentifyData != NULL) {
                    NVMeIdentifyControllerStruct idCtrl;
                    memset(&idCtrl, 0, sizeof(idCtrl));
                    if ((*smartIf)->GetIdentifyData(smartIf, &idCtrl, 0) == kIOReturnSuccess) {
                        xs_trim_copy_cstr(
                            (const char *)idCtrl.MODEL_NUMBER,
                            sizeof(idCtrl.MODEL_NUMBER),
                            ctx->nvmeModel,
                            sizeof(ctx->nvmeModel));
                    }
                }
                memcpy(cached.model, ctx->nvmeModel, sizeof(cached.model));
                cached.model[sizeof(cached.model) - 1] = '\0';

                ctx->cachedSmart = cached;
                ctx->hasSmartCache = cached.hasSmart;
            }

            (*smartIf)->Release(smartIf);
        }
        if (plugIn != NULL) {
            IODestroyPlugInInterface(plugIn);
        }
    }

    if (ctx->hasSmartCache) {
        sto->hasSmart = ctx->cachedSmart.hasSmart;
        sto->tempC = ctx->cachedSmart.tempC;
        sto->lifeUsedPct = ctx->cachedSmart.lifeUsedPct;
        sto->availableSparePct = ctx->cachedSmart.availableSparePct;
        sto->dataReadTB = ctx->cachedSmart.dataReadTB;
        sto->dataWrittenTB = ctx->cachedSmart.dataWrittenTB;
        sto->powerOnHours = ctx->cachedSmart.powerOnHours;
        sto->powerCycles = ctx->cachedSmart.powerCycles;
        sto->unsafeShutdowns = ctx->cachedSmart.unsafeShutdowns;
        if (ctx->cachedSmart.model[0] != '\0') {
            memcpy(sto->model, ctx->cachedSmart.model, sizeof(sto->model));
        }
    }

    /* 2. IOBlockStorageDriver Statistics delta */
    if (ctx->blockDriverService != IO_OBJECT_NULL) {
        CFTypeRef statsRef = IORegistryEntryCreateCFProperty(
            ctx->blockDriverService, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (statsRef && CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
            CFDictionaryRef stats = (CFDictionaryRef)statsRef;
            uint64_t rBytes = (uint64_t)xs_dict_int64_or(stats, CFSTR("Bytes (Read)"), 0);
            uint64_t wBytes = (uint64_t)xs_dict_int64_or(stats, CFSTR("Bytes (Write)"), 0);
            uint64_t rOps = (uint64_t)xs_dict_int64_or(stats, CFSTR("Operations (Read)"), 0);
            uint64_t wOps = (uint64_t)xs_dict_int64_or(stats, CFSTR("Operations (Write)"), 0);

            uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            if (ctx->hasDiskBaseline) {
                double dtSec = (nowNs > ctx->prevDiskMonoNs)
                    ? ((double)(nowNs - ctx->prevDiskMonoNs) / 1e9)
                    : 0.0;
                if (dtSec >= 0.05 && dtSec <= 10.0) {
                    if (rBytes >= ctx->prevDiskReadBytes) {
                        sto->readBytesPerSec = (uint64_t)((double)(rBytes - ctx->prevDiskReadBytes) / dtSec);
                    }
                    if (wBytes >= ctx->prevDiskWriteBytes) {
                        sto->writeBytesPerSec = (uint64_t)((double)(wBytes - ctx->prevDiskWriteBytes) / dtSec);
                    }
                    if (rOps >= ctx->prevDiskReadOps) {
                        sto->readIOPS = (double)(rOps - ctx->prevDiskReadOps) / dtSec;
                    }
                    if (wOps >= ctx->prevDiskWriteOps) {
                        sto->writeIOPS = (double)(wOps - ctx->prevDiskWriteOps) / dtSec;
                    }
                    ctx->prevDiskMonoNs = nowNs;
                    ctx->prevDiskReadBytes = rBytes;
                    ctx->prevDiskWriteBytes = wBytes;
                    ctx->prevDiskReadOps = rOps;
                    ctx->prevDiskWriteOps = wOps;
                } else if (dtSec > 10.0 || dtSec <= 0.0) {
                    ctx->prevDiskMonoNs = nowNs;
                    ctx->prevDiskReadBytes = rBytes;
                    ctx->prevDiskWriteBytes = wBytes;
                    ctx->prevDiskReadOps = rOps;
                    ctx->prevDiskWriteOps = wOps;
                }
            } else {
                ctx->hasDiskBaseline = true;
                ctx->prevDiskMonoNs = nowNs;
                ctx->prevDiskReadBytes = rBytes;
                ctx->prevDiskWriteBytes = wBytes;
                ctx->prevDiskReadOps = rOps;
                ctx->prevDiskWriteOps = wOps;
            }
        }
        if (statsRef) {
            CFRelease(statsRef);
        }
    }
}

typedef struct {
    char name[16];
    bool seenLink;
    bool linkUp;
    bool hasIPv4;
    bool hasIPv6;
    bool hasGlobalIPv6;
    uint64_t rxBytes;
    uint64_t txBytes;
    char ipv4[46];
    char ipv6[64];
} XSIfCandidate;

static bool xs_is_ignored_net_if(const char *name) {
    if (!name || name[0] == '\0') return true;
    return strncmp(name, "lo", 2) == 0 ||
           strncmp(name, "utun", 4) == 0 ||
           strncmp(name, "gif", 3) == 0 ||
           strncmp(name, "stf", 3) == 0 ||
           strncmp(name, "XHC", 3) == 0 ||
           strncmp(name, "awdl", 4) == 0 ||
           strncmp(name, "llw", 3) == 0 ||
           strncmp(name, "ap", 2) == 0 ||
           strncmp(name, "anpi", 4) == 0 ||
           strncmp(name, "bridge", 6) == 0;
}

static void xs_sample_network(XSBridgeContext *ctx, XSNetworkMetrics *net) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0 || !ifap) {
        return;
    }

    XSIfCandidate cands[16];
    size_t candCount = 0;
    memset(cands, 0, sizeof(cands));

    for (struct ifaddrs *ifa = ifap; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr) continue;
        if ((ifa->ifa_flags & IFF_LOOPBACK) != 0) continue;
        if ((ifa->ifa_flags & IFF_UP) == 0) continue;
        if (xs_is_ignored_net_if(ifa->ifa_name)) continue;

        XSIfCandidate *slot = NULL;
        for (size_t i = 0; i < candCount; ++i) {
            if (strcmp(cands[i].name, ifa->ifa_name) == 0) {
                slot = &cands[i];
                break;
            }
        }
        if (!slot) {
            if (candCount >= sizeof(cands) / sizeof(cands[0])) continue;
            slot = &cands[candCount++];
            strncpy(slot->name, ifa->ifa_name, sizeof(slot->name) - 1);
            slot->name[sizeof(slot->name) - 1] = '\0';
        }

        sa_family_t fam = ifa->ifa_addr->sa_family;
        if (fam == AF_LINK && ifa->ifa_data != NULL) {
            const struct if_data *ifd = (const struct if_data *)ifa->ifa_data;
            slot->seenLink = true;
            slot->rxBytes = (uint64_t)ifd->ifi_ibytes;
            slot->txBytes = (uint64_t)ifd->ifi_obytes;
#ifdef LINK_STATE_UP
            slot->linkUp = (ifd->ifi_link_state == LINK_STATE_UP);
#else
            slot->linkUp = ((ifa->ifa_flags & IFF_RUNNING) != 0);
#endif
        } else if (fam == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, slot->ipv4, sizeof(slot->ipv4)) != NULL) {
                slot->hasIPv4 = true;
            }
        } else if (fam == AF_INET6) {
            struct sockaddr_in6 sin6;
            memcpy(&sin6, ifa->ifa_addr, sizeof(sin6));
            bool isLinkLocal = IN6_IS_ADDR_LINKLOCAL(&sin6.sin6_addr) ||
                               IN6_IS_ADDR_MC_LINKLOCAL(&sin6.sin6_addr);
            if (isLinkLocal) {
                /* Strip XNU kernel embedded scope ID from link-local IPv6 word 1 */
                sin6.sin6_addr.__u6_addr.__u6_addr16[1] = 0;
            }
            if (!slot->hasIPv6 || (!isLinkLocal && !slot->hasGlobalIPv6)) {
                if (inet_ntop(AF_INET6, &sin6.sin6_addr, slot->ipv6, sizeof(slot->ipv6)) != NULL) {
                    slot->hasIPv6 = true;
                    if (!isLinkLocal) {
                        slot->hasGlobalIPv6 = true;
                    }
                }
            }
        }
    }

    freeifaddrs(ifap);

    if (candCount == 0) {
        return;
    }

    const char *pref = (ctx->preferredNetIf[0] != '\0') ? ctx->preferredNetIf : "en1";
    const XSIfCandidate *best = NULL;
    int bestScore = -1;

    for (size_t i = 0; i < candCount; ++i) {
        const XSIfCandidate *c = &cands[i];
        int score = 0;
        bool isPref = (strcmp(c->name, pref) == 0);
        bool isEn = (strncmp(c->name, "en", 2) == 0);
        if (c->hasIPv4) score += 100;
        if (c->hasGlobalIPv6) score += 40;
        else if (c->hasIPv6) score += 20;
        if (c->linkUp) score += 30;
        if (isPref && (c->hasIPv4 || c->hasIPv6 || c->linkUp)) score += 80;
        else if (isPref) score += 10;
        if (isEn) score += 15;
        if (c->seenLink) score += 5;

        if (score > bestScore) {
            bestScore = score;
            best = c;
        }
    }

    if (!best) {
        return;
    }

    memcpy(net->primaryIf, best->name, sizeof(net->primaryIf));
    net->primaryIf[sizeof(net->primaryIf) - 1] = '\0';
    memcpy(net->ipv4, best->ipv4, sizeof(net->ipv4));
    net->ipv4[sizeof(net->ipv4) - 1] = '\0';
    memcpy(net->ipv6, best->ipv6, sizeof(net->ipv6));
    net->ipv6[sizeof(net->ipv6) - 1] = '\0';

    if (best->seenLink) {
        uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        bool sameIf = (strcmp(ctx->prevNetIf, best->name) == 0);
        if (ctx->hasNetBaseline && sameIf) {
            double dtSec = (nowNs > ctx->prevNetMonoNs)
                ? ((double)(nowNs - ctx->prevNetMonoNs) / 1e9)
                : 0.0;
            if (dtSec >= 0.05 && dtSec <= 10.0) {
                if (best->rxBytes >= ctx->prevNetRxBytes) {
                    net->rxBytesPerSec = (uint64_t)((double)(best->rxBytes - ctx->prevNetRxBytes) / dtSec);
                }
                if (best->txBytes >= ctx->prevNetTxBytes) {
                    net->txBytesPerSec = (uint64_t)((double)(best->txBytes - ctx->prevNetTxBytes) / dtSec);
                }
                ctx->prevNetMonoNs = nowNs;
                ctx->prevNetRxBytes = best->rxBytes;
                ctx->prevNetTxBytes = best->txBytes;
            } else if (dtSec > 10.0 || dtSec <= 0.0) {
                ctx->prevNetMonoNs = nowNs;
                ctx->prevNetRxBytes = best->rxBytes;
                ctx->prevNetTxBytes = best->txBytes;
            }
        } else {
            ctx->hasNetBaseline = true;
            memcpy(ctx->prevNetIf, best->name, sizeof(ctx->prevNetIf));
            ctx->prevNetMonoNs = nowNs;
            ctx->prevNetRxBytes = best->rxBytes;
            ctx->prevNetTxBytes = best->txBytes;
        }
    }
}

/* ========================================================================== *
 * Dual-Path Process Collector (libsysmon when entitled + libproc fallback)
 * ========================================================================== */

static uint64_t xs_mach_abs_to_ns(const XSBridgeContext *ctx, uint64_t machTicks) {
    uint32_t numer = ctx->timebase.numer ? ctx->timebase.numer : 1U;
    uint32_t denom = ctx->timebase.denom ? ctx->timebase.denom : 1U;
    if (numer == denom) {
        return machTicks;
    }
    return (uint64_t)(((__uint128_t)machTicks * (__uint128_t)numer) / (__uint128_t)denom);
}

static bool xs_ensure_proc_buffers(XSBridgeContext *ctx, size_t neededRows) {
    if (neededRows < 256) {
        neededRows = 256;
    }
    if (neededRows > ctx->procRowCap) {
        size_t newRowCap = ctx->procRowCap ? ctx->procRowCap : 512;
        while (newRowCap < neededRows) {
            newRowCap *= 2;
        }
        XSProcRawRow *newRows = (XSProcRawRow *)realloc(ctx->procRowBuf, newRowCap * sizeof(XSProcRawRow));
        if (!newRows) return false;
        ctx->procRowBuf = newRows;
        ctx->procRowCap = newRowCap;
    }

    size_t minHashCap = 1024;
    while (minHashCap < neededRows * 2) {
        minHashCap *= 2;
    }
    if (minHashCap > ctx->procTableCap) {
        XSProcDeltaSlot *newPrev = (XSProcDeltaSlot *)calloc(minHashCap, sizeof(XSProcDeltaSlot));
        XSProcDeltaSlot *newCurr = (XSProcDeltaSlot *)calloc(minHashCap, sizeof(XSProcDeltaSlot));
        if (!newPrev || !newCurr) {
            free(newPrev);
            free(newCurr);
            return false;
        }
        /* Rehash existing prevProcTable so resizing never drops active delta baselines */
        if (ctx->prevProcTable && ctx->procTableCap > 0) {
            size_t mask = minHashCap - 1;
            for (size_t i = 0; i < ctx->procTableCap; ++i) {
                if (ctx->prevProcTable[i].pid > 0) {
                    size_t idx = ((uint32_t)ctx->prevProcTable[i].pid * 2654435761U) & mask;
                    while (newPrev[idx].pid != 0) {
                        idx = (idx + 1) & mask;
                    }
                    newPrev[idx] = ctx->prevProcTable[i];
                }
            }
        }
        free(ctx->prevProcTable);
        free(ctx->currProcTable);
        ctx->prevProcTable = newPrev;
        ctx->currProcTable = newCurr;
        ctx->procTableCap = minHashCap;
    }
    return true;
}

static bool xs_proc_hash_lookup(
    const XSProcDeltaSlot *table,
    size_t cap,
    int32_t pid,
    uint64_t startKey,
    uint64_t *outCpuNs)
{
    if (!table || cap == 0 || pid <= 0) return false;
    size_t mask = cap - 1;
    size_t idx = ((uint32_t)pid * 2654435761U) & mask;
    for (size_t step = 0; step < cap; ++step) {
        const XSProcDeltaSlot *s = &table[idx];
        if (s->pid == 0) {
            return false;
        }
        if (s->pid == pid) {
            if (s->startKey == startKey) {
                *outCpuNs = s->cpuNs;
                return true;
            }
            return false;
        }
        idx = (idx + 1) & mask;
    }
    return false;
}

static bool xs_proc_hash_insert_unique(
    XSProcDeltaSlot *table,
    size_t cap,
    int32_t pid,
    uint64_t startKey,
    uint64_t cpuNs)
{
    if (!table || cap == 0 || pid <= 0) return false;
    size_t mask = cap - 1;
    size_t idx = ((uint32_t)pid * 2654435761U) & mask;
    for (size_t step = 0; step < cap; ++step) {
        XSProcDeltaSlot *s = &table[idx];
        if (s->pid == 0) {
            s->pid = pid;
            s->startKey = startKey;
            s->cpuNs = cpuNs;
            return true;
        }
        if (s->pid == pid) {
            return false; /* Duplicate PID in snapshot */
        }
        idx = (idx + 1) & mask;
    }
    return false;
}

static int xs_compare_proc_rows(const void *a, const void *b) {
    const XSProcRawRow *pa = (const XSProcRawRow *)a;
    const XSProcRawRow *pb = (const XSProcRawRow *)b;
    if (pa->cpuPct > pb->cpuPct) return -1;
    if (pa->cpuPct < pb->cpuPct) return 1;
    if (pa->memoryBytes > pb->memoryBytes) return -1;
    if (pa->memoryBytes < pb->memoryBytes) return 1;
    if (pa->pid < pb->pid) return -1;
    if (pa->pid > pb->pid) return 1;
    return 0;
}

static void xs_probe_sysmon(XSBridgeContext *ctx) {
    if (ctx->sysmonProbed) {
        return;
    }
    ctx->sysmonProbed = true;
    ctx->hasSysmonEntitlement = false;

    /* Check SecTaskCopyValueForEntitlement BEFORE touching libsysmon XPC */
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        return;
    }
    CFTypeRef ent = SecTaskCopyValueForEntitlement(
        task, CFSTR("com.apple.private.sysmond.client"), NULL);
    if (ent) {
        if (CFGetTypeID(ent) == CFBooleanGetTypeID() &&
            CFBooleanGetValue((CFBooleanRef)ent)) {
            ctx->hasSysmonEntitlement = true;
        }
        CFRelease(ent);
    }
    CFRelease(task);

    if (!ctx->hasSysmonEntitlement) {
        return;
    }

    ctx->sysmonDylib = dlopen("/usr/lib/libsysmon.dylib", RTLD_LAZY);
    if (!ctx->sysmonDylib) {
        ctx->hasSysmonEntitlement = false;
        return;
    }

    ctx->pSysmonReqCreate = (fn_sysmon_request_create)dlsym(ctx->sysmonDylib, "sysmon_request_create");
    ctx->pSysmonReqAddAttr = (fn_sysmon_request_add_attribute)dlsym(ctx->sysmonDylib, "sysmon_request_add_attribute");
    ctx->pSysmonReqExecute = (fn_sysmon_request_execute)dlsym(ctx->sysmonDylib, "sysmon_request_execute");
    ctx->pSysmonReqCancel = (fn_sysmon_request_cancel)dlsym(ctx->sysmonDylib, "sysmon_request_cancel");
    ctx->pSysmonTableApply = (fn_sysmon_table_apply)dlsym(ctx->sysmonDylib, "sysmon_table_apply");
    ctx->pSysmonRowGetValue = (fn_sysmon_row_get_value)dlsym(ctx->sysmonDylib, "sysmon_row_get_value");
    ctx->pSysmonRelease = (fn_sysmon_release)dlsym(ctx->sysmonDylib, "sysmon_release");

    if (!ctx->pSysmonReqCreate || !ctx->pSysmonReqAddAttr || !ctx->pSysmonReqExecute ||
        !ctx->pSysmonTableApply || !ctx->pSysmonRowGetValue || !ctx->pSysmonRelease) {
        dlclose(ctx->sysmonDylib);
        ctx->sysmonDylib = NULL;
        ctx->hasSysmonEntitlement = false;
    }
}

typedef struct {
    os_unfair_lock lock;
    int refCount;
    bool abandoned;
    dispatch_semaphore_t sem;
    XSProcRawRow *rows;
    size_t count;
    size_t cap;
} XSSysmonBatchState;

static void xs_sysmon_batch_release(XSSysmonBatchState *st) {
    os_unfair_lock_lock(&st->lock);
    int rem = --st->refCount;
    os_unfair_lock_unlock(&st->lock);
    if (rem == 0) {
        if (st->sem) {
            dispatch_release(st->sem);
        }
        free(st->rows);
        free(st);
    }
}

static uint64_t xs_xpc_u64_or(xpc_object_t obj, uint64_t fallback) {
    if (!obj) return fallback;
    xpc_type_t t = xpc_get_type(obj);
    if (t == XPC_TYPE_UINT64) return xpc_uint64_get_value(obj);
    if (t == XPC_TYPE_INT64) {
        int64_t v = xpc_int64_get_value(obj);
        return (v > 0) ? (uint64_t)v : 0ULL;
    }
    return fallback;
}

static size_t xs_collect_rows_sysmon(XSBridgeContext *ctx) {
    if (!ctx->hasSysmonEntitlement || !ctx->sysmonDylib) {
        return 0;
    }

    XSSysmonBatchState *st = (XSSysmonBatchState *)calloc(1, sizeof(XSSysmonBatchState));
    if (!st) return 0;
    st->lock = OS_UNFAIR_LOCK_INIT;
    st->refCount = 2; /* 1 caller + 1 callback */
    st->sem = dispatch_semaphore_create(0);
    if (!st->sem) {
        free(st);
        return 0;
    }

    fn_sysmon_table_apply pTableApply = ctx->pSysmonTableApply;
    fn_sysmon_row_get_value pRowGetVal = ctx->pSysmonRowGetValue;

    xs_sysmon_request_t req = ctx->pSysmonReqCreate(XS_SYSMON_REQ_PROCESS, ^(xs_sysmon_table_t table) {
        os_unfair_lock_lock(&st->lock);
        bool skip = st->abandoned;
        os_unfair_lock_unlock(&st->lock);

        if (!skip && table != NULL) {
            pTableApply(table, ^bool(xs_sysmon_row_t row) {
                uint64_t pidU = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_PID), 0);
                if (pidU == 0) return true;

                XSProcRawRow r;
                memset(&r, 0, sizeof(r));
                r.pid = (int32_t)pidU;
                r.uid = (uint32_t)xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_UID), 0);
                r.startKey = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_START_NS), pidU);
                uint64_t userNs = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_USER_NS), 0);
                uint64_t sysNs = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_SYS_NS), 0);
                r.cpuNs = userNs + sysNs;
                uint64_t fp = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_FOOTPRINT), 0);
                if (fp == 0) {
                    fp = xs_xpc_u64_or(pRowGetVal(row, XS_SYSMON_ATTR_RESIDENT), 0);
                }
                r.memoryBytes = fp;

                xpc_object_t nameObj = pRowGetVal(row, XS_SYSMON_ATTR_NAME);
                const char *s = (nameObj && xpc_get_type(nameObj) == XPC_TYPE_STRING)
                    ? xpc_string_get_string_ptr(nameObj)
                    : NULL;
                if (!s || s[0] == '\0') {
                    xpc_object_t commObj = pRowGetVal(row, XS_SYSMON_ATTR_COMM);
                    s = (commObj && xpc_get_type(commObj) == XPC_TYPE_STRING)
                        ? xpc_string_get_string_ptr(commObj)
                        : NULL;
                }
                if (s && s[0] != '\0') {
                    strncpy(r.name, s, sizeof(r.name) - 1);
                    r.name[sizeof(r.name) - 1] = '\0';
                }

                os_unfair_lock_lock(&st->lock);
                if (!st->abandoned) {
                    if (st->count >= st->cap) {
                        size_t newCap = st->cap ? (st->cap * 2) : 512;
                        XSProcRawRow *nr = (XSProcRawRow *)realloc(st->rows, newCap * sizeof(XSProcRawRow));
                        if (nr) {
                            st->rows = nr;
                            st->cap = newCap;
                        }
                    }
                    if (st->count < st->cap) {
                        st->rows[st->count++] = r;
                    }
                }
                os_unfair_lock_unlock(&st->lock);
                return true;
            });
        }

        dispatch_semaphore_signal(st->sem);
        xs_sysmon_batch_release(st);
    });

    if (!req) {
        st->refCount = 1;
        xs_sysmon_batch_release(st);
        return 0;
    }

    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_PID);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_UID);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_COMM);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_NAME);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_START_NS);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_USER_NS);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_SYS_NS);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_FOOTPRINT);
    ctx->pSysmonReqAddAttr(req, XS_SYSMON_ATTR_RESIDENT);

    ctx->pSysmonReqExecute(req);
    long waitRes = dispatch_semaphore_wait(
        st->sem, dispatch_time(DISPATCH_TIME_NOW, 300LL * (int64_t)NSEC_PER_MSEC));

    size_t copied = 0;
    os_unfair_lock_lock(&st->lock);
    if (waitRes != 0) {
        st->abandoned = true;
    } else if (st->count > 0 && xs_ensure_proc_buffers(ctx, st->count)) {
        memcpy(ctx->procRowBuf, st->rows, st->count * sizeof(XSProcRawRow));
        copied = st->count;
    }
    os_unfair_lock_unlock(&st->lock);

    if (waitRes != 0 && ctx->pSysmonReqCancel) {
        ctx->pSysmonReqCancel(req);
    }
    ctx->pSysmonRelease(req);
    xs_sysmon_batch_release(st);
    return copied;
}

static size_t xs_collect_rows_libproc(XSBridgeContext *ctx) {
    /* Note: proc_listallpids() takes buffer size in bytes, and returns the NUMBER of PIDs. */
    int estPids = proc_listallpids(NULL, 0);
    if (estPids <= 0) {
        return 0;
    }
    size_t needPids = (size_t)estPids + 256;
    if (needPids > ctx->pidBufCap) {
        int *newBuf = (int *)realloc(ctx->pidBuf, needPids * sizeof(int));
        if (!newBuf) return 0;
        ctx->pidBuf = newBuf;
        ctx->pidBufCap = needPids;
    }

    int actualPids = proc_listallpids(ctx->pidBuf, (int)(ctx->pidBufCap * sizeof(int)));
    if (actualPids <= 0) {
        return 0;
    }
    size_t pidCount = ((size_t)actualPids <= ctx->pidBufCap) ? (size_t)actualPids : ctx->pidBufCap;
    if (!xs_ensure_proc_buffers(ctx, pidCount)) {
        return 0;
    }

    size_t outCount = 0;
    for (size_t i = 0; i < pidCount; ++i) {
        int pid = ctx->pidBuf[i];
        if (pid <= 0) continue;

        struct proc_bsdinfo bsd;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd)) != (int)sizeof(bsd)) {
            continue;
        }

        struct rusage_info_v4 ru;
        memset(&ru, 0, sizeof(ru));
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ru) != 0) {
            continue;
        }

        XSProcRawRow *r = &ctx->procRowBuf[outCount++];
        memset(r, 0, sizeof(*r));
        r->pid = (int32_t)pid;
        r->uid = (uint32_t)bsd.pbi_uid;
        r->startKey = ((uint64_t)bsd.pbi_start_tvsec << 20) ^
                      ((uint64_t)bsd.pbi_start_tvusec & 0xFFFFFULL);
        r->cpuNs = xs_mach_abs_to_ns(ctx, ru.ri_user_time + ru.ri_system_time);
        r->memoryBytes = (ru.ri_phys_footprint > 0) ? ru.ri_phys_footprint : ru.ri_resident_size;

        const char *rawName = (bsd.pbi_name[0] != '\0') ? bsd.pbi_name : bsd.pbi_comm;
        strncpy(r->name, rawName, sizeof(r->name) - 1);
        r->name[sizeof(r->name) - 1] = '\0';
    }
    return outCount;
}

/* ========================================================================== *
 * Public Lifecycle & Core Sampling Entry Points
 * ========================================================================== */

XSBridgeContext *xs_bridge_create(void) {
    XSBridgeContext *ctx = (XSBridgeContext *)calloc(1, sizeof(XSBridgeContext));
    if (!ctx) {
        return NULL;
    }

    ctx->hostPort = mach_host_self();
    (void)mach_timebase_info(&ctx->timebase);
    if (ctx->timebase.numer == 0 || ctx->timebase.denom == 0) {
        ctx->timebase.numer = 1;
        ctx->timebase.denom = 1;
    }
    memcpy(ctx->preferredNetIf, "en1", 4);

    uint64_t memsize = 0;
    size_t memLen = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &memLen, NULL, 0) == 0 && memsize > 0) {
        ctx->totalMemBytes = memsize;
    }

    uint64_t cpuFreqHz = 0;
    size_t freqLen = sizeof(cpuFreqHz);
    if (sysctlbyname("hw.cpufrequency", &cpuFreqHz, &freqLen, NULL, 0) == 0 && cpuFreqHz > 0) {
        ctx->baseMHz = (double)cpuFreqHz / 1000000.0;
    } else {
        ctx->baseMHz = 2800.0;
    }

    size_t smLen = 4;
    if (sysctlnametomib("vm.swapusage", ctx->swapMib, &smLen) == 0) {
        ctx->swapMibLen = smLen;
    }
    size_t pmLen = 4;
    if (sysctlnametomib("kern.memorystatus_vm_pressure_level", ctx->pressureMib, &pmLen) == 0) {
        ctx->pressureMibLen = pmLen;
    }

    const void *keys[1] = { CFSTR("refreshGpuFreq") };
    const void *vals[1] = { kCFBooleanTrue };
    ctx->refreshGpuFreqDict = CFDictionaryCreate(
        kCFAllocatorDefault, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    xs_init_ioreport(ctx);
    xs_probe_smc_keys(ctx);

    return ctx;
}

void xs_bridge_reset_baselines(XSBridgeContext *ctx) {
    if (!ctx) {
        return;
    }
    ctx->hasTelemetryBaseline = false;
    ctx->hasCpuTickBaseline = false;
    ctx->smcProbed = false;
    ctx->gpuFreqState.freqProbed = false;
    ctx->gpuFreqState.supportsGpuFreq = false;
    ctx->s0ixCacheValid = false;
    ctx->powerSampleCount = 0;
    ctx->lastPowerSampleNs = 0;
    ctx->hasBattRegCache = false;
    ctx->lastBattRegSampleNs = 0;
    memset(&ctx->battTracker, 0, sizeof(ctx->battTracker));
    ctx->gpuRegSampleCount = 0;
    ctx->lastGpuRegSampleNs = 0;
    ctx->sinkKnownOnRoot = false;
    ctx->hasDiskBaseline = false;
    ctx->hasNetBaseline = false;
    ctx->hasProcBaseline = false;
    if (ctx->prevProcTable && ctx->procTableCap > 0) {
        memset(ctx->prevProcTable, 0, ctx->procTableCap * sizeof(XSProcDeltaSlot));
    }
}

void xs_bridge_set_preferred_net_if(XSBridgeContext *ctx, const char *ifName) {
    if (!ctx) {
        return;
    }
    if (!ifName || ifName[0] == '\0') {
        memcpy(ctx->preferredNetIf, "en1", 4);
        return;
    }
    strncpy(ctx->preferredNetIf, ifName, sizeof(ctx->preferredNetIf) - 1);
    ctx->preferredNetIf[sizeof(ctx->preferredNetIf) - 1] = '\0';
}

void xs_bridge_sample_core(
    XSBridgeContext *ctx,
    XSCpuMetrics *cpu,
    XSGpuMetrics *gpu,
    XSMemoryMetrics *mem,
    XSPowerMetrics *pwr)
{
    XSCpuMetrics localCpu;
    XSGpuMetrics localGpu;
    XSMemoryMetrics localMem;
    XSPowerMetrics localPwr;

    memset(&localCpu, 0, sizeof(localCpu));
    memset(&localGpu, 0, sizeof(localGpu));
    memset(&localMem, 0, sizeof(localMem));
    memset(&localPwr, 0, sizeof(localPwr));

    if (!ctx) {
        if (cpu) *cpu = localCpu;
        if (gpu) *gpu = localGpu;
        if (mem) *mem = localMem;
        if (pwr) *pwr = localPwr;
        return;
    }

    uint64_t nowMonoNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (ctx->hasTelemetryBaseline) {
        double checkDt = (nowMonoNs > ctx->prevMonoNs)
            ? ((double)(nowMonoNs - ctx->prevMonoNs) / 1000000000.0)
            : 0.0;
        if (checkDt > 10.0 || checkDt <= 0.0) {
            /* Across-sleep jump: also reset CPU tick baseline so usage doesn't average across sleep */
            ctx->hasCpuTickBaseline = false;
        }
    }

    /* 1. CPU Mach tick load + loadavg + optional SMC temperatures */
    xs_sample_cpu_mach(ctx, &localCpu);
    (void)getloadavg(localCpu.loadAvg, 3);
    xs_sample_cpu_temps(ctx, &localCpu);

    /* 2. libIOReport CPU MSRs + GPU RC0/RC1/RC6 */
    uint64_t nowTsc = __rdtsc();
    XSIOReportRawSample currIO;
    bool gotIO = xs_sample_ioreport_raw(ctx, &currIO);

    if (gotIO) {
        if (ctx->hasTelemetryBaseline) {
            double dtSec = (nowMonoNs > ctx->prevMonoNs)
                ? ((double)(nowMonoNs - ctx->prevMonoNs) / 1000000000.0)
                : 0.0;

            if (dtSec >= 0.05 && dtSec <= 10.0) {
                /* RAPL power (PKG, PP0 Core, PP1 GT) */
                localCpu.packagePowerW = xs_calc_rapl_watts(
                    ctx->prevIOReport.pkgEnergy, currIO.pkgEnergy, currIO.esuBits, dtSec);
                localCpu.corePowerW = xs_calc_rapl_watts(
                    ctx->prevIOReport.pp0Energy, currIO.pp0Energy, currIO.esuBits, dtSec);
                localGpu.powerW = xs_calc_rapl_watts(
                    ctx->prevIOReport.pp1Energy, currIO.pp1Energy, currIO.esuBits, dtSec);

                /* Per-thread APERF/MPERF MHz */
                uint32_t tCount = (localCpu.threadCount > 0) ? localCpu.threadCount : 8;
                if (tCount > XS_MAX_THREADS) tCount = XS_MAX_THREADS;
                uint64_t totalDAcnt = 0;
                uint64_t totalDMcnt = 0;
                double maxMHz = 0.0;
                double sumMHz = 0.0;
                uint32_t activeThreads = 0;

                for (uint32_t i = 0; i < tCount; ++i) {
                    uint64_t dA = (currIO.acnt[i] >= ctx->prevIOReport.acnt[i])
                        ? (currIO.acnt[i] - ctx->prevIOReport.acnt[i]) : 0ULL;
                    uint64_t dM = (currIO.mcnt[i] >= ctx->prevIOReport.mcnt[i])
                        ? (currIO.mcnt[i] - ctx->prevIOReport.mcnt[i]) : 0ULL;
                    double mhz = xs_calc_aperf_mhz(dA, dM, ctx->baseMHz);
                    localCpu.threadFreqMHz[i] = mhz;
                    if (mhz > maxMHz) maxMHz = mhz;
                    if (mhz > 0.0) {
                        sumMHz += mhz;
                        activeThreads++;
                    }
                    totalDAcnt += dA;
                    totalDMcnt += dM;
                }
                localCpu.maxFreqMHz = maxMHz;
                if (totalDMcnt > 0) {
                    localCpu.avgFreqMHz = xs_calc_aperf_mhz(totalDAcnt, totalDMcnt, ctx->baseMHz);
                } else if (activeThreads > 0) {
                    localCpu.avgFreqMHz = sumMHz / (double)activeThreads;
                }

                /* Package C2..C10 residency % against invariant TSC */
                uint64_t dTsc = (nowTsc > ctx->prevTsc) ? (nowTsc - ctx->prevTsc) : 0ULL;
                if (dTsc > 0) {
                    uint64_t sumC = 0;
                    for (size_t c = 0; c < XS_NUM_PKG_CSTATES; ++c) {
                        if (currIO.pkgCResidency[c] >= ctx->prevIOReport.pkgCResidency[c]) {
                            sumC += (currIO.pkgCResidency[c] - ctx->prevIOReport.pkgCResidency[c]);
                        }
                    }
                    double cPct = ((double)sumC / (double)dTsc) * 100.0;
                    if (cPct < 0.0) cPct = 0.0;
                    if (cPct > 100.0) cPct = 100.0;
                    localCpu.pkgCStatePct = cPct;
                }

                /* GPU RC0 / RC1 / RC6 residency % */
                uint64_t dRc0 = (currIO.rc0 >= ctx->prevIOReport.rc0) ? (currIO.rc0 - ctx->prevIOReport.rc0) : 0ULL;
                uint64_t dRc1 = (currIO.rc1 >= ctx->prevIOReport.rc1) ? (currIO.rc1 - ctx->prevIOReport.rc1) : 0ULL;
                uint64_t dRc6 = (currIO.rc6 >= ctx->prevIOReport.rc6) ? (currIO.rc6 - ctx->prevIOReport.rc6) : 0ULL;
                uint64_t totRc = dRc0 + dRc1 + dRc6;
                if (totRc > 0) {
                    localGpu.usagePct = ((double)(dRc0 + dRc1) / (double)totRc) * 100.0;
                    localGpu.rc6Pct = ((double)dRc6 / (double)totRc) * 100.0;
                    if (localGpu.usagePct > 100.0) localGpu.usagePct = 100.0;
                    if (localGpu.rc6Pct > 100.0) localGpu.rc6Pct = 100.0;
                }

                ctx->prevMonoNs = nowMonoNs;
                ctx->prevTsc = nowTsc;
                ctx->prevIOReport = currIO;
            } else if (dtSec > 10.0 || dtSec <= 0.0) {
                /* Across-sleep jump: clamp rates to 0 and re-anchor baseline */
                ctx->prevMonoNs = nowMonoNs;
                ctx->prevTsc = nowTsc;
                ctx->prevIOReport = currIO;
            }
            /* If 0 < dtSec < 0.05s, emit 0 rates and retain previous baseline so next tick has >=50ms window */
        } else {
            ctx->hasTelemetryBaseline = true;
            ctx->prevMonoNs = nowMonoNs;
            ctx->prevTsc = nowTsc;
            ctx->prevIOReport = currIO;
        }
    }

    /* 3. GPU GART / TGLSinkRestoreRate / optional S0ixStandby GPU MHz */
    xs_sample_gpu_registry(ctx, nowMonoNs, &localGpu);

    /* 4. Memory & Swap & VM Pressure */
    xs_sample_memory(ctx, &localMem);

    /* 5. SmartBattery & S0ixStandby */
    xs_sample_power_s0ix(ctx, nowMonoNs, localCpu.packagePowerW, &localPwr);

    if (cpu) *cpu = localCpu;
    if (gpu) *gpu = localGpu;
    if (mem) *mem = localMem;
    if (pwr) *pwr = localPwr;
}

void xs_bridge_sample_io_net(
    XSBridgeContext *ctx,
    bool refreshSmart,
    XSStorageMetrics *sto,
    XSNetworkMetrics *net)
{
    XSStorageMetrics localSto;
    XSNetworkMetrics localNet;
    memset(&localSto, 0, sizeof(localSto));
    memset(&localNet, 0, sizeof(localNet));

    if (!ctx) {
        if (sto) *sto = localSto;
        if (net) *net = localNet;
        return;
    }

    xs_sample_storage(ctx, refreshSmart, &localSto);
    xs_sample_network(ctx, &localNet);

    if (sto) *sto = localSto;
    if (net) *net = localNet;
}

uint32_t xs_bridge_sample_processes(
    XSBridgeContext *ctx,
    XSProcessEntry *outEntries,
    uint32_t maxEntries,
    bool *outAllUsers)
{
    if (outAllUsers) {
        *outAllUsers = false;
    }
    if (!ctx || !outEntries || maxEntries == 0) {
        return 0;
    }

    xs_probe_sysmon(ctx);

    uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    size_t rawCount = 0;
    bool allUsers = false;

    if (ctx->hasSysmonEntitlement) {
        rawCount = xs_collect_rows_sysmon(ctx);
        if (rawCount > 0) {
            allUsers = true;
        }
    }
    if (rawCount == 0) {
        rawCount = xs_collect_rows_libproc(ctx);
        allUsers = false;
    }
    if (outAllUsers) {
        *outAllUsers = allUsers;
    }
    if (rawCount == 0 || !ctx->currProcTable || ctx->procTableCap == 0) {
        return 0;
    }

    memset(ctx->currProcTable, 0, ctx->procTableCap * sizeof(XSProcDeltaSlot));

    uint64_t dtNs = (ctx->hasProcBaseline && nowNs > ctx->prevProcMonoNs)
        ? (nowNs - ctx->prevProcMonoNs)
        : 0ULL;
    bool validDeltaWindow = ctx->hasProcBaseline &&
                            dtNs >= 20000000ULL &&
                            dtNs <= 10000000000ULL;

    size_t uniqueCount = 0;
    for (size_t i = 0; i < rawCount; ++i) {
        XSProcRawRow r = ctx->procRowBuf[i];
        if (r.pid <= 0) continue;

        if (!xs_proc_hash_insert_unique(
                ctx->currProcTable, ctx->procTableCap, r.pid, r.startKey, r.cpuNs)) {
            continue;
        }

        double cpuPct = 0.0;
        if (validDeltaWindow) {
            uint64_t prevCpuNs = 0;
            if (xs_proc_hash_lookup(
                    ctx->prevProcTable, ctx->procTableCap, r.pid, r.startKey, &prevCpuNs) &&
                r.cpuNs >= prevCpuNs) {
                cpuPct = ((double)(r.cpuNs - prevCpuNs) / (double)dtNs) * 100.0;
                if (cpuPct < 0.0) cpuPct = 0.0;
                if (cpuPct > 1600.0) cpuPct = 1600.0;
            }
        }
        r.cpuPct = cpuPct;
        ctx->procRowBuf[uniqueCount++] = r;
    }

    /* Swap double-buffered PID tables so dead PIDs are evicted in O(1) with zero leaks */
    if (!ctx->hasProcBaseline || dtNs >= 20000000ULL || dtNs > 10000000000ULL) {
        XSProcDeltaSlot *tmp = ctx->prevProcTable;
        ctx->prevProcTable = ctx->currProcTable;
        ctx->currProcTable = tmp;
        ctx->prevProcMonoNs = nowNs;
        ctx->hasProcBaseline = true;
    }

    if (uniqueCount > 1) {
        qsort(ctx->procRowBuf, uniqueCount, sizeof(XSProcRawRow), xs_compare_proc_rows);
    }

    uint32_t outCount = (uniqueCount < (size_t)maxEntries) ? (uint32_t)uniqueCount : maxEntries;
    for (uint32_t i = 0; i < outCount; ++i) {
        const XSProcRawRow *src = &ctx->procRowBuf[i];
        XSProcessEntry dst;
        memset(&dst, 0, sizeof(dst));
        dst.pid = src->pid;
        dst.uid = src->uid;
        dst.cpuPct = src->cpuPct;
        dst.memoryBytes = src->memoryBytes;

        memcpy(dst.name, src->name, sizeof(dst.name));
        dst.name[sizeof(dst.name) - 1] = '\0';

        /* If pbi_name was empty or truncated near 2*MAXCOMLEN-1, try executable basename */
        if (dst.name[0] == '\0' || strlen(dst.name) >= 31) {
            char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
            int pathLen = proc_pidpath(src->pid, pathBuf, sizeof(pathBuf));
            if (pathLen > 0) {
                pathBuf[sizeof(pathBuf) - 1] = '\0';
                const char *slash = strrchr(pathBuf, '/');
                const char *base = slash ? (slash + 1) : pathBuf;
                if (base[0] != '\0') {
                    strncpy(dst.name, base, sizeof(dst.name) - 1);
                    dst.name[sizeof(dst.name) - 1] = '\0';
                }
            }
        }
        if (dst.name[0] == '\0') {
            memcpy(dst.name, "unknown", 8);
        }

        outEntries[i] = dst;
    }

    return outCount;
}

void xs_bridge_destroy(XSBridgeContext *ctx) {
    if (!ctx) {
        return;
    }

    if (ctx->nvmeSmartIf) {
        (*ctx->nvmeSmartIf)->Release(ctx->nvmeSmartIf);
        ctx->nvmeSmartIf = NULL;
    }
    if (ctx->nvmePlugIn) {
        IODestroyPlugInInterface(ctx->nvmePlugIn);
        ctx->nvmePlugIn = NULL;
    }
    if (ctx->blockDriverService != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->blockDriverService);
        ctx->blockDriverService = IO_OBJECT_NULL;
    }
    if (ctx->nvmeBlockService != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->nvmeBlockService);
        ctx->nvmeBlockService = IO_OBJECT_NULL;
    }

    if (ctx->ioSub) {
        CFRelease((CFTypeRef)ctx->ioSub);
        ctx->ioSub = NULL;
    }
    if (ctx->ioSubbedChannels) {
        CFRelease(ctx->ioSubbedChannels);
        ctx->ioSubbedChannels = NULL;
    }
    if (ctx->refreshGpuFreqDict) {
        CFRelease(ctx->refreshGpuFreqDict);
        ctx->refreshGpuFreqDict = NULL;
    }
    if (ctx->smcConn != IO_OBJECT_NULL) {
        IOServiceClose(ctx->smcConn);
        ctx->smcConn = IO_OBJECT_NULL;
    }
    if (ctx->accelService != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->accelService);
        ctx->accelService = IO_OBJECT_NULL;
    }
    if (ctx->batteryService != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->batteryService);
        ctx->batteryService = IO_OBJECT_NULL;
    }
    if (ctx->s0ixService != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->s0ixService);
        ctx->s0ixService = IO_OBJECT_NULL;
    }
    if (ctx->rootEntry != IO_OBJECT_NULL) {
        IOObjectRelease(ctx->rootEntry);
        ctx->rootEntry = IO_OBJECT_NULL;
    }
    if (ctx->hostPort != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), ctx->hostPort);
        ctx->hostPort = MACH_PORT_NULL;
    }
    if (ctx->ioReportDylib) {
        dlclose(ctx->ioReportDylib);
        ctx->ioReportDylib = NULL;
    }
    if (ctx->sysmonDylib) {
        dlclose(ctx->sysmonDylib);
        ctx->sysmonDylib = NULL;
    }

    free(ctx->prevProcTable);
    free(ctx->currProcTable);
    free(ctx->pidBuf);
    free(ctx->procRowBuf);

    free(ctx);
}
