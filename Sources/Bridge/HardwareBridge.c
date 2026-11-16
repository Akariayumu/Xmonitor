#include "HardwareBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/host_info.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_map.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <x86intrin.h>

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

    io_service_t accelService;
    io_service_t batteryService;
    io_service_t s0ixService;
    io_registry_entry_t rootEntry;
    CFDictionaryRef refreshGpuFreqDict;
    bool s0ixFreqProbed;
    bool s0ixSupportsGpuFreq;

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

static void xs_probe_smc_keys(XSBridgeContext *ctx) {
    ctx->smcProbed = true;
    ctx->smcHasTemp = false;
    ctx->smcPkgKey = 0;
    ctx->smcCoreCount = 0;

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

static void xs_sample_gpu_registry(XSBridgeContext *ctx, XSGpuMetrics *gpu) {
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
    bool gotSink = xs_reg_get_int64(ctx->accelService, CFSTR("TGLSinkRestoreRate"), &sinkRaw);
    if (!gotSink) {
        if (ctx->rootEntry == IO_OBJECT_NULL) {
            ctx->rootEntry = IORegistryGetRootEntry(kIOMainPortDefault);
        }
        gotSink = xs_reg_get_int64(ctx->rootEntry, CFSTR("TGLSinkRestoreRate"), &sinkRaw);
    }
    if (gotSink && sinkRaw >= 0) {
        uint64_t u = (uint64_t)sinkRaw;
        gpu->sinkRestoreRetries = (uint32_t)(u >> 24);
        gpu->sinkRestoreOk = (uint32_t)(u & 0xFFFFFFU);
    }

    /* Optional Gen12 GPU frequency export from S0ixStandby (EFI v2.0.1+) */
    if (ctx->s0ixService == IO_OBJECT_NULL) {
        ctx->s0ixService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("S0ixStandby"));
    }
    if (ctx->s0ixService != IO_OBJECT_NULL) {
        if (!ctx->s0ixFreqProbed) {
            ctx->s0ixFreqProbed = true;
            int64_t curMHz = 0;
            if (xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Current Freq MHz"), &curMHz)) {
                ctx->s0ixSupportsGpuFreq = true;
            } else if (ctx->refreshGpuFreqDict &&
                       IORegistryEntrySetCFProperties(ctx->s0ixService, ctx->refreshGpuFreqDict) == KERN_SUCCESS &&
                       xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Current Freq MHz"), &curMHz)) {
                ctx->s0ixSupportsGpuFreq = true;
            } else {
                ctx->s0ixSupportsGpuFreq = false;
            }
        }

        if (ctx->s0ixSupportsGpuFreq) {
            gpu->hasFreq = true;
            if (gpu->usagePct < 0.5) {
                /* Idle in RC6: report 0 MHz directly without entering kernel MMIO */
                gpu->currentFreqMHz = 0;
                gpu->requestedFreqMHz = 0;
            } else {
                if (ctx->refreshGpuFreqDict) {
                    (void)IORegistryEntrySetCFProperties(ctx->s0ixService, ctx->refreshGpuFreqDict);
                }
                int64_t curMHz = 0;
                int64_t reqMHz = 0;
                if (xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Current Freq MHz"), &curMHz) && curMHz >= 0) {
                    gpu->currentFreqMHz = (uint32_t)curMHz;
                }
                if (xs_reg_get_int64(ctx->s0ixService, CFSTR("GPU Requested Freq MHz"), &reqMHz) && reqMHz >= 0) {
                    gpu->requestedFreqMHz = (uint32_t)reqMHz;
                }
            }
        }
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
    if (sysctlbyname("vm.swapusage", &swap, &swapLen, NULL, 0) == 0) {
        mem->swapUsedBytes = swap.xsu_used;
        mem->swapTotalBytes = swap.xsu_total;
    }

    int32_t pressure = 1;
    size_t pLen = sizeof(pressure);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pLen, NULL, 0) == 0) {
        mem->pressureLevel = pressure;
    } else {
        mem->pressureLevel = 1;
    }
}

static void xs_sample_power_s0ix(XSBridgeContext *ctx, XSPowerMetrics *pwr) {
    /* 1. AppleSmartBattery */
    if (ctx->batteryService == IO_OBJECT_NULL) {
        ctx->batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    }
    if (ctx->batteryService != IO_OBJECT_NULL) {
        CFMutableDictionaryRef battProps = NULL;
        if (IORegistryEntryCreateCFProperties(ctx->batteryService, &battProps, kCFAllocatorDefault, 0) == KERN_SUCCESS &&
            battProps != NULL) {
            pwr->present = true;
            pwr->isPluggedIn = xs_dict_bool_or(battProps, CFSTR("ExternalConnected"), false);
            pwr->isCharging = xs_dict_bool_or(battProps, CFSTR("IsCharging"), false);
            pwr->isFullyCharged = xs_dict_bool_or(battProps, CFSTR("FullyCharged"), false);

            int64_t curCap = xs_dict_int64_or(battProps, CFSTR("CurrentCapacity"), 0);
            int64_t maxCap = xs_dict_int64_or(battProps, CFSTR("MaxCapacity"), 0);
            if (maxCap > 0 && curCap >= 0) {
                double pct = ((double)curCap / (double)maxCap) * 100.0;
                if (pct > 100.0) pct = 100.0;
                pwr->percentage = pct;
            }

            int64_t rawMax = xs_dict_int64_or(battProps, CFSTR("AppleRawMaxCapacity"), maxCap);
            int64_t designCap = xs_dict_int64_or(battProps, CFSTR("DesignCapacity"), 0);
            if (designCap > 0 && rawMax > 0) {
                pwr->healthPct = ((double)rawMax / (double)designCap) * 100.0;
            }

            int64_t voltageMV = xs_dict_int64_or(battProps, CFSTR("Voltage"), 0);
            pwr->voltageMV = (int32_t)voltageMV;

            int64_t rawAmp = 0;
            if (!xs_dict_get_int64(battProps, CFSTR("InstantAmperage"), &rawAmp)) {
                (void)xs_dict_get_int64(battProps, CFSTR("Amperage"), &rawAmp);
            }
            pwr->batteryWatts = xs_calc_battery_watts(voltageMV, (uint64_t)rawAmp, &pwr->amperageMA);
            pwr->cycleCount = (int32_t)xs_dict_int64_or(battProps, CFSTR("CycleCount"), 0);

            CFRelease(battProps);
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
    ctx->s0ixFreqProbed = false;
    ctx->s0ixCacheValid = false;
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
    xs_sample_gpu_registry(ctx, &localGpu);

    /* 4. Memory & Swap & VM Pressure */
    xs_sample_memory(ctx, &localMem);

    /* 5. SmartBattery & S0ixStandby */
    xs_sample_power_s0ix(ctx, &localPwr);

    if (cpu) *cpu = localCpu;
    if (gpu) *gpu = localGpu;
    if (mem) *mem = localMem;
    if (pwr) *pwr = localPwr;
}

void xs_bridge_destroy(XSBridgeContext *ctx) {
    if (!ctx) {
        return;
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

    free(ctx);
}
