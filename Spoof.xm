// CrossFamilySpoof - per-app device spoofing (model, family, iOS, CPU, RAM, GPU).
//
// Injected into every UIKit app, but hooks nothing unless the app is enabled
// under Per-App Spoofing; that's checked once in the constructor. appstored is
// the one non-UIKit process: it gets the App Store entry's values for purchases.
// Values are read from the applied plist at launch, so changes apply on the
// app's next start.
//
//   Model    hw.machine (sysctlbyname, sysctl), uname().machine, UIDevice.model
//   Family   UIDevice.userInterfaceIdiom (+ UIDevice.model if no model is set)
//   iOS      UIDevice.systemVersion, NSProcessInfo version methods,
//            kern.osproductversion
//   CPU      machdep.cpu.brand_string, hw.ncpu and the other counts,
//            NSProcessInfo processor counts, host_info
//   Memory   NSProcessInfo.physicalMemory, hw.memsize / physmem / memsize_usable,
//            host_info
//   GPU      MTLDevice name and recommendedMaxWorkingSetSize
//
// Kept real:
//   - Real memory limits: an app told it has more RAM is still killed at the
//     real one.
//   - GPU feature sets: engines pick shaders from them. Only the name changes.
//   - #available / @available: a newer version there makes apps call APIs this
//     iOS doesn't have.
//   - UITraitCollection idiom: UIKit lays itself out from it.
//   - MobileGestalt, except for the App Store entry (see below).

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

// Shared with the prefs bundle (CFISpoofStore.m).
static NSString *const kCFSAppliedDomain = @"com.soulrune.crossfamilyinstall.spoof.applied";

static NSString *CFSAppliedPath(void) {
    NSString *root = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"] ? @"/var/jb" : @"";
    return [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@.plist", root, kCFSAppliedDomain];
}

// ---------------------------------------------------------------------------
// State, set once in the constructor
// ---------------------------------------------------------------------------

static BOOL gHasModel = NO;
static char gModel[64];

static BOOL gHasFamily = NO;
static UIUserInterfaceIdiom gIdiom = UIUserInterfaceIdiomUnspecified;

static NSString *gDeviceName = nil;           // UIDevice.model

static BOOL gHasOS = NO;
static char gOSC[32];
static NSString *gOSString = nil;
static NSOperatingSystemVersion gOS = {0, 0, 0};

static BOOL gHasMemory = NO;
static uint64_t gMemoryBytes = 0;

static BOOL gHasCPU = NO;
static char gCPU[64];

static BOOL gHasCores = NO;
static uint32_t gCores = 0;

static NSString *gGPUName = nil;
static BOOL gHasGPUMemory = NO;
static uint64_t gGPUMemoryBytes = 0;

// ---------------------------------------------------------------------------
// Parsing. A bad value is logged and ignored.
// ---------------------------------------------------------------------------

static BOOL CFSMatches(NSString *s, NSString *pattern) {
    if (!s.length) return NO;
    return [s rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

// "17", "17.4", "17.4.1"
static BOOL CFSParseVersion(NSString *s, NSOperatingSystemVersion *out) {
    if (!CFSMatches(s, @"^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$")) return NO;
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"."];
    out->majorVersion = parts[0].integerValue;
    out->minorVersion = parts.count > 1 ? parts[1].integerValue : 0;
    out->patchVersion = parts.count > 2 ? parts[2].integerValue : 0;
    return out->majorVersion > 0;
}

// "iPhone15,2", "iPad13,16"
static BOOL CFSValidModel(NSString *s) {
    return s.length < sizeof(gModel) && CFSMatches(s, @"^[A-Za-z]+[0-9]+,[0-9]+$");
}

static NSString *CFSDeviceNameForModel(NSString *model) {
    if ([model hasPrefix:@"iPad"])   return @"iPad";
    if ([model hasPrefix:@"iPhone"]) return @"iPhone";
    if ([model hasPrefix:@"iPod"])   return @"iPod touch";
    return nil;
}

static NSComparisonResult CFSCompareVersions(NSOperatingSystemVersion a, NSOperatingSystemVersion b) {
    if (a.majorVersion != b.majorVersion) return a.majorVersion < b.majorVersion ? NSOrderedAscending : NSOrderedDescending;
    if (a.minorVersion != b.minorVersion) return a.minorVersion < b.minorVersion ? NSOrderedAscending : NSOrderedDescending;
    if (a.patchVersion != b.patchVersion) return a.patchVersion < b.patchVersion ? NSOrderedAscending : NSOrderedDescending;
    return NSOrderedSame;
}

// ---------------------------------------------------------------------------
// sysctl, uname, host_info
// ---------------------------------------------------------------------------

// Size query when oldp is NULL, ENOMEM when the buffer is too small.
static int CFSReturnString(const char *value, void *oldp, size_t *oldlenp) {
    size_t need = strlen(value) + 1;
    if (!oldp) { *oldlenp = need; return 0; }
    if (*oldlenp < need) { *oldlenp = need; errno = ENOMEM; return -1; }
    memcpy(oldp, value, need);
    *oldlenp = need;
    return 0;
}

// `natural` is the kernel's size for the name (8 for hw.memsize, 4 for hw.ncpu).
// A 4-byte buffer gets the value clamped to 32 bits, like the kernel does.
static int CFSReturnInteger(uint64_t value, size_t natural, void *oldp, size_t *oldlenp) {
    if (!oldp) { *oldlenp = natural; return 0; }
    if (*oldlenp >= 8 && natural == 8) {
        memcpy(oldp, &value, 8);
        *oldlenp = 8;
        return 0;
    }
    if (*oldlenp >= 4) {
        uint32_t v32 = value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
        memcpy(oldp, &v32, 4);
        *oldlenp = 4;
        return 0;
    }
    *oldlenp = natural;
    errno = ENOMEM;
    return -1;
}

static BOOL CFSIsMemoryName(const char *name) {
    return strcmp(name, "hw.memsize") == 0 || strcmp(name, "hw.physmem") == 0 ||
           strcmp(name, "hw.memsize_usable") == 0;
}

static BOOL CFSIsCoresName(const char *name) {
    static const char *const names[] = {
        "hw.ncpu", "hw.activecpu", "hw.logicalcpu", "hw.logicalcpu_max",
        "hw.physicalcpu", "hw.physicalcpu_max",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(name, names[i]) == 0) return YES;
    }
    return NO;
}

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && oldlenp && !newp) {
        if (gHasModel && strcmp(name, "hw.machine") == 0)          return CFSReturnString(gModel, oldp, oldlenp);
        if (gHasOS && strcmp(name, "kern.osproductversion") == 0)  return CFSReturnString(gOSC, oldp, oldlenp);
        if (gHasCPU && strcmp(name, "machdep.cpu.brand_string") == 0) return CFSReturnString(gCPU, oldp, oldlenp);
        if (gHasMemory && CFSIsMemoryName(name))                   return CFSReturnInteger(gMemoryBytes, 8, oldp, oldlenp);
        if (gHasCores && CFSIsCoresName(name))                     return CFSReturnInteger(gCores, 4, oldp, oldlenp);
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && namelen == 2 && name[0] == CTL_HW && oldlenp && !newp) {
        if (gHasModel && name[1] == HW_MACHINE) return CFSReturnString(gModel, oldp, oldlenp);
        if (gHasMemory && (name[1] == HW_MEMSIZE || name[1] == HW_PHYSMEM)) {
            return CFSReturnInteger(gMemoryBytes, 8, oldp, oldlenp);
        }
        if (gHasCores && (name[1] == HW_NCPU || name[1] == HW_AVAILCPU)) {
            return CFSReturnInteger(gCores, 4, oldp, oldlenp);
        }
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

// Kernel-only in the SDK: the short layout old callers pass, i.e. the first
// five fields (max_cpus, avail_cpus, memory_size, cpu_type, cpu_subtype).
#ifndef HOST_BASIC_INFO_OLD_COUNT
#define HOST_BASIC_INFO_OLD_COUNT ((mach_msg_type_number_t)5)
#endif

static kern_return_t (*orig_host_info)(host_t, host_flavor_t, host_info_t, mach_msg_type_number_t *);
static kern_return_t hook_host_info(host_t host, host_flavor_t flavor, host_info_t info, mach_msg_type_number_t *count) {
    kern_return_t r = orig_host_info(host, flavor, info, count);
    if (r != KERN_SUCCESS || flavor != HOST_BASIC_INFO || !info || !count || *count < HOST_BASIC_INFO_OLD_COUNT) {
        return r;
    }
    host_basic_info_t basic = (host_basic_info_t)info;
    BOOL full = *count >= HOST_BASIC_INFO_COUNT;
    if (gHasMemory) {
        // The kernel caps this legacy field at 2 GB; max_mem has the full size
        basic->memory_size = (natural_t)MIN(gMemoryBytes, (uint64_t)0x80000000);
        if (full) basic->max_mem = gMemoryBytes;
    }
    if (gHasCores) {
        basic->max_cpus = basic->avail_cpus = (integer_t)gCores;
        if (full) {
            basic->logical_cpu = basic->logical_cpu_max = (integer_t)gCores;
            basic->physical_cpu = basic->physical_cpu_max = (integer_t)gCores;
        }
    }
    return r;
}

static int (*orig_uname)(struct utsname *);
static int hook_uname(struct utsname *u) {
    int r = orig_uname(u);
    if (r == 0 && u && gHasModel) {
        strlcpy(u->machine, gModel, sizeof(u->machine));
    }
    return r;
}

// ---------------------------------------------------------------------------
// Metal. MTLDevice is a protocol, so the methods are hooked on the class of the
// first device MTLCreateSystemDefaultDevice returns. Metal isn't linked.
// ---------------------------------------------------------------------------

static NSString *hook_device_name(id self, SEL _cmd) { return gGPUName; }
static uint64_t hook_device_working_set(id self, SEL _cmd) { return gGPUMemoryBytes; }

static void CFSHookDeviceClass(Class cls) {
    static Class hooked = Nil;
    @synchronized ([NSObject class]) {
        if (!cls || hooked == cls) return;
        hooked = cls;
    }
    if (gGPUName && [cls instancesRespondToSelector:@selector(name)]) {
        MSHookMessageEx(cls, @selector(name), (IMP)hook_device_name, NULL);
    }
    SEL workingSet = NSSelectorFromString(@"recommendedMaxWorkingSetSize");
    if (gHasGPUMemory && [cls instancesRespondToSelector:workingSet]) {
        MSHookMessageEx(cls, workingSet, (IMP)hook_device_working_set, NULL);
    }
}

// Returns a retained device; passed through as is.
static void *(*orig_MTLCreateSystemDefaultDevice)(void);
static void *hook_MTLCreateSystemDefaultDevice(void) {
    void *device = orig_MTLCreateSystemDefaultDevice();
    if (device) CFSHookDeviceClass(object_getClass((__bridge id)device));
    return device;
}

static BOOL CFSHookMetal(void) {
    void *metal = dlopen("/System/Library/Frameworks/Metal.framework/Metal", RTLD_LAZY);
    void *create = metal ? dlsym(metal, "MTLCreateSystemDefaultDevice") : NULL;
    if (!create) return NO;
    MSHookFunction(create, (void *)hook_MTLCreateSystemDefaultDevice, (void **)&orig_MTLCreateSystemDefaultDevice);
    return YES;
}

// ---------------------------------------------------------------------------
// ObjC hooks, each group set up only when its value is set
// ---------------------------------------------------------------------------

%group Memory
%hook NSProcessInfo
- (unsigned long long)physicalMemory { return gMemoryBytes; }
%end
%end

%group Cores
%hook NSProcessInfo
- (NSUInteger)processorCount       { return gCores; }
- (NSUInteger)activeProcessorCount { return gCores; }
%end
%end

%group DeviceName
%hook UIDevice
- (NSString *)model          { return gDeviceName; }
- (NSString *)localizedModel { return gDeviceName; }
%end
%end

%group Family
%hook UIDevice
- (UIUserInterfaceIdiom)userInterfaceIdiom { return gIdiom; }
%end
%end

%group OSVersion
%hook UIDevice
- (NSString *)systemVersion { return gOSString; }
%end

%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion { return gOS; }

- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)version {
    return CFSCompareVersions(gOS, version) != NSOrderedAscending;
}

// "Version 16.7.10 (Build 20H350)" -> "Version 17.0 (Build 20H350)"
- (NSString *)operatingSystemVersionString {
    NSString *o = %orig;
    NSRange r = [o rangeOfString:@" ("];
    return [NSString stringWithFormat:@"Version %@%@", gOSString,
            r.location != NSNotFound ? [o substringFromIndex:r.location] : @""];
}
%end
%end

// ---------------------------------------------------------------------------
// App Store. Apple's servers decide from the User-Agent of store requests
//   "AppStore/3.0 iOS/16.7 model/iPhone10,1 hwp/t8015 build/20H350 ..."
// whether the device may get an app. iOS, model and chip are rewritten in
// requests to apple.com: all of them in the App Store / StoreKit UI apps, only
// the purchase (buyProduct) in appstored, which also updates every other app.
// ---------------------------------------------------------------------------

// @{ @"os", @"model", @"hwp" }, any of them; nil when off. appstored replaces
// it on reload while request threads read it, hence the lock.
static NSDictionary *gStoreUA = nil;

static NSObject *CFSStoreLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSDictionary *CFSGetStoreUA(void) {
    @synchronized (CFSStoreLock()) { return gStoreUA; }
}

static void CFSSetStoreUA(NSDictionary *values) {
    @synchronized (CFSStoreLock()) { gStoreUA = values; }
}

// The hwp/ chip of a known model, or nil.
static NSString *CFSChipForModel(NSString *model) {
    static NSDictionary<NSString *, NSString *> *chips;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        chips = @{
            @"iPhone10,1": @"t8015", @"iPhone10,3": @"t8015",                          // A11
            @"iPhone11,2": @"t8020", @"iPhone11,8": @"t8020",                          // A12
            @"iPhone12,1": @"t8030", @"iPad12,1": @"t8030",                            // A13
            @"iPhone13,2": @"t8101", @"iPad13,18": @"t8101", @"iPad13,1": @"t8101",    // A14
            @"iPhone14,5": @"t8110", @"iPhone14,2": @"t8110", @"iPhone14,7": @"t8110",
            @"iPad14,1": @"t8110",                                                     // A15
            @"iPhone15,2": @"t8120", @"iPhone15,4": @"t8120",                          // A16
            @"iPhone16,1": @"t8130", @"iPhone16,2": @"t8130",                          // A17 Pro
            @"iPhone17,3": @"t8140", @"iPhone17,1": @"t8140", @"iPhone17,2": @"t8140", // A18
            @"iPad13,16": @"t8103", @"iPad13,4": @"t8103",                             // M1
            @"iPad14,3": @"t8112",                                                     // M2
        };
    });
    return model ? chips[model] : nil;
}

static NSDictionary *CFSStoreValues(NSString *os, NSString *model) {
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    if (os.length) v[@"os"] = os;
    if (model.length) {
        v[@"model"] = model;
        NSString *chip = CFSChipForModel(model);
        if (chip) v[@"hwp"] = chip;
    }
    return v.count ? [v copy] : nil;
}

static NSString *CFSReplacing(NSString *s, NSString *pattern, NSString *replacement) {
    return [s stringByReplacingOccurrencesOfString:pattern withString:replacement
                                           options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
}

// Set in appstored: only purchases are rewritten there, so other apps' updates
// keep coming for the real device.
static BOOL gStoreBuyOnly = NO;

static NSString *CFSStoreUserAgent(NSString *ua, NSURL *url) {
    NSDictionary *v = CFSGetStoreUA();
    if (!v || ![ua isKindOfClass:[NSString class]]) return ua;
    NSString *host = url.host.lowercaseString;
    if (!([host isEqualToString:@"apple.com"] || [host hasSuffix:@".apple.com"])) return ua;
    if (gStoreBuyOnly && ![url.path containsString:@"buyProduct"]) return ua;

    NSString *out = ua;
    // "iOS/16.7" (iPads may say "iPadOS/"): only the number changes
    if (v[@"os"])    out = CFSReplacing(out, @"((?:iOS|iPadOS)/)[0-9][0-9.]*", [@"$1" stringByAppendingString:v[@"os"]]);
    // Model and chip too, in the purchase as well: Apple's server checks them
    // there for apps with a hardware gate ("Server canceled the purchase" for an
    // A12 game when the real model went out).
    if (v[@"model"]) out = CFSReplacing(out, @"model/[A-Za-z]+[0-9]+,[0-9]+", [@"model/" stringByAppendingString:v[@"model"]]);
    if (v[@"hwp"])   out = CFSReplacing(out, @"hwp/[A-Za-z0-9]+", [@"hwp/" stringByAppendingString:v[@"hwp"]]);

    static BOOL logged = NO;
    if (!logged && ![out isEqualToString:ua]) {
        logged = YES;
        NSLog(@"[CrossFamilySpoof] %@: User-Agent rewritten for %@: %@",
              [[NSProcessInfo processInfo] processName], host, out);
    }
    return out;
}

%group StoreRequests
%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) value = CFSStoreUserAgent(value, self.URL);
    %orig(value, field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) value = CFSStoreUserAgent(value, self.URL);
    %orig(value, field);
}

- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)fields {
    NSMutableDictionary *copy = nil;
    for (NSString *field in fields) {
        if ([field caseInsensitiveCompare:@"User-Agent"] != NSOrderedSame) continue;
        copy = copy ?: [fields mutableCopy];
        copy[field] = CFSStoreUserAgent(fields[field], self.URL);
    }
    %orig(copy ?: fields);
}
%end
%end

// appstored is sandboxed and can't rely on reading the plist, so Apply mirrors
// the App Store entry into this cfprefsd domain and posts a reload notification.
static CFStringRef const kCFSStoreDomain = CFSTR("com.soulrune.crossfamilyinstall.store");

static void CFSLoadStoreDaemonPrefs(void) {
    CFPreferencesAppSynchronize(kCFSStoreDomain);
    NSNumber *on = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Enabled"), kCFSStoreDomain));
    NSString *os = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("OSVersion"), kCFSStoreDomain));
    NSString *model = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("Model"), kCFSStoreDomain));
    if (![os isKindOfClass:[NSString class]] || !CFSMatches(os, @"^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$")) os = nil;
    if (![model isKindOfClass:[NSString class]] || !CFSValidModel(model)) model = nil;
    NSDictionary *values = [on isKindOfClass:[NSNumber class]] && on.boolValue ? CFSStoreValues(os, model) : nil;
    CFSSetStoreUA(values);
    NSLog(@"[CrossFamilySpoof] appstored: %@", values ?: @"off");
}

static void CFSStoreDaemonReload(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    @autoreleasepool { CFSLoadStoreDaemonPrefs(); }
}

// Logos allows the group to be set up in one place only, so both callers come
// here. Called from the constructor only.
static void CFSInitStoreRequests(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    %init(StoreRequests);
}

// MobileGestalt is the App Store's own gate, checked before any request:
// "iphone-ipad-minimum-performance-a12" is 0 on an A11 device, so A12+ apps show
// as not supported. The performance gates are answered for the chosen chip, and
// the model and chip are reported; everything else keeps its real answer.

// Chip generation: 11 = A11 ... 18 = A18, M-series 100 (passes every A gate),
// 0 = unknown.
static int CFSChipRank(NSString *hwp) {
    static NSDictionary<NSString *, NSNumber *> *ranks;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ranks = @{ @"t8015": @11, @"t8020": @12, @"t8030": @13, @"t8101": @14, @"t8110": @15,
                   @"t8120": @16, @"t8130": @17, @"t8140": @18,
                   @"t8103": @100, @"t8112": @100 };                     // M1, M2
    });
    return hwp ? ranks[hwp].intValue : 0;
}

//   "...minimum-performance-aN"       chip generation >= N
//   "iphone-performance-gaming-tier"  A17 Pro and newer, M-series
// NO when the key isn't a gate or the chip is unknown.
static BOOL CFSGateAnswer(NSString *key, NSString *hwp, BOOL *answer) {
    int rank = CFSChipRank(hwp);
    if (!rank || ![key isKindOfClass:[NSString class]]) return NO;
    NSRange r = [key rangeOfString:@"minimum-performance-a"];
    if (r.location != NSNotFound) {
        int needed = [key substringFromIndex:NSMaxRange(r)].intValue;
        if (needed <= 0) return NO;
        *answer = rank >= needed;
        return YES;
    }
    if ([key containsString:@"performance-gaming-tier"]) {
        *answer = rank >= 17;
        return YES;
    }
    return NO;
}

// Once per key and caller.
static void CFSLogGateOnce(NSString *key, BOOL answer, NSString *via) {
    static NSMutableSet *seen;
    @synchronized ([NSObject class]) {
        if (!seen) seen = [NSMutableSet set];
        NSString *tag = [NSString stringWithFormat:@"%@|%@", via, key];
        if ([seen containsObject:tag]) return;
        [seen addObject:tag];
    }
    NSLog(@"[CrossFamilySpoof] %@: %@ %@ -> %d", [[NSProcessInfo processInfo] processName], via, key, answer);
}

// MGCopyAnswer's worker takes (property, error*); extra arguments pass through.
static CFTypeRef (*orig_MGCopyAnswerInternal)(CFStringRef, void *, void *, void *);
static CFTypeRef hook_MGCopyAnswerInternal(CFStringRef property, void *a1, void *a2, void *a3) {
    NSDictionary *v = CFSGetStoreUA();
    if (v && property && CFGetTypeID(property) == CFStringGetTypeID()) {
        NSString *key = (__bridge NSString *)property;
        BOOL answer = NO;
        if (CFSGateAnswer(key, v[@"hwp"], &answer)) {
            CFSLogGateOnce(key, answer, @"MGCopyAnswer");
            return CFRetain(answer ? kCFBooleanTrue : kCFBooleanFalse);
        }
        if (v[@"model"] && [key isEqualToString:@"ProductType"])     return (__bridge_retained CFTypeRef)[v[@"model"] copy];
        if (v[@"hwp"]   && [key isEqualToString:@"HardwarePlatform"]) return (__bridge_retained CFTypeRef)[v[@"hwp"] copy];
    }
    return orig_MGCopyAnswerInternal(property, a1, a2, a3);
}

// Target of an unconditional B in the first two instructions, or NULL.
static void *CFSStubBranchTarget(void *fn) {
#if __has_feature(ptrauth_calls)
    fn = ptrauth_strip(fn, ptrauth_key_function_pointer);
#endif
    const uint32_t *insn = (const uint32_t *)fn;
    for (int i = 0; i < 2; i++) {
        if ((insn[i] & 0xFC000000u) == 0x14000000u) {                 // B imm26
            int32_t imm = (int32_t)(insn[i] << 6) >> 6;                // sign-extend
            void *target = (void *)((const uint8_t *)&insn[i] + (int64_t)imm * 4);
#if __has_feature(ptrauth_calls)
            target = ptrauth_sign_unauthenticated(target, ptrauth_key_function_pointer, 0);
#endif
            return target;
        }
    }
    return NULL;
}

// A hook overwrites 16 bytes, so none of the first four instructions may leave
// the function (B, BR/BLR/RET and their PAC forms).
static BOOL CFSSafeToPatch(void *fn) {
#if __has_feature(ptrauth_calls)
    fn = ptrauth_strip(fn, ptrauth_key_function_pointer);
#endif
    const uint32_t *insn = (const uint32_t *)fn;
    for (int i = 0; i < 4; i++) {
        if ((insn[i] & 0xFC000000u) == 0x14000000u) return NO;   // B
        if ((insn[i] & 0xFE000000u) == 0xD6000000u) return NO;   // BR / BLR / RET (+ PAC forms)
    }
    return YES;
}

// Follows branch stubs to a function that is safe to patch; NULL if there's
// none, and then nothing is hooked.
static void *CFSPatchableTarget(void *fn) {
    for (int hop = 0; fn && hop < 4; hop++) {
        void *next = CFSStubBranchTarget(fn);
        if (!next) return CFSSafeToPatch(fn) ? fn : NULL;
        fn = next;
    }
    return NULL;
}

// MGCopyAnswer is a two-instruction stub ("mov x1, #0; b <worker>"), too short
// to patch, so the worker it jumps to is hooked instead.
static void CFSInitMobileGestalt(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    void *fn = mg ? dlsym(mg, "MGCopyAnswer") : NULL;
    if (!fn) {
        NSLog(@"[CrossFamilySpoof] MGCopyAnswer not found, App Store gate not spoofed");
        return;
    }
    void *worker = CFSPatchableTarget(fn);
    if (!worker) {
        NSLog(@"[CrossFamilySpoof] %@: MGCopyAnswer has an unknown layout on this iOS, App Store gate not spoofed",
              [[NSProcessInfo processInfo] processName]);
        return;
    }
    MSHookFunction(worker, (void *)hook_MGCopyAnswerInternal, (void **)&orig_MGCopyAnswerInternal);
    NSLog(@"[CrossFamilySpoof] %@: hooked MGCopyAnswer", [[NSProcessInfo processInfo] processName]);
}

// Before a download appstored asks installd over XPC whether the device has the
// app's required capabilities; installd answers with CapabilitiesMatch and
// MismatchedCapabilities. The answer is corrected on the way back, but only if
// every mismatch is a performance gate the chosen chip passes. Anything else,
// and blacklisted apps, keep the refusal.
static NSDictionary *CFSFixCapabilityResult(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) return result;
    if ([result[@"CapabilitiesMatch"] boolValue] || [result[@"AppBlacklisted"] boolValue]) return result;
    NSDictionary *mismatched = result[@"MismatchedCapabilities"];
    if (![mismatched isKindOfClass:[NSDictionary class]] || !mismatched.count) return result;
    NSString *hwp = CFSGetStoreUA()[@"hwp"];
    if (!hwp) return result;   // App Store device not set: the real verdict stays

    for (id key in mismatched) {
        // The value is the device's; the app wants the opposite
        id deviceValue = mismatched[key];
        BOOL wanted = !([deviceValue respondsToSelector:@selector(boolValue)] && [deviceValue boolValue]);
        BOOL answer = NO;
        if (!CFSGateAnswer(key, hwp, &answer) || answer != wanted) {
            CFSLogGateOnce([key description], answer, @"checkCapabilities(kept)");
            return result;
        }
    }
    CFSLogGateOnce([[mismatched.allKeys valueForKey:@"description"] componentsJoinedByString:@","],
                   YES, @"checkCapabilities");
    NSMutableDictionary *fixed = [result mutableCopy];
    fixed[@"CapabilitiesMatch"] = @YES;
    [fixed removeObjectForKey:@"MismatchedCapabilities"];
    return [fixed copy];
}

%group CapabilityCheck
%hook MIInstallerClient
- (void)checkCapabilities:(id)capabilities withOptions:(id)options completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!completion) {
        %orig;
        return;
    }
    // Passed by name: Logos can't take a block literal as an argument here
    void (^original)(NSDictionary *, NSError *) = [completion copy];
    void (^wrapped)(NSDictionary *, NSError *) = ^(NSDictionary *result, NSError *error) {
        original(CFSFixCapabilityResult(result), error);
    };
    %orig(capabilities, options, wrapped);
}
%end
%end

// MobileInstallation may load late in appstored. Retries go to a background
// queue, since a daemon's main queue may never run.
static void CFSInitCapabilityCheck(void) {
    static BOOL done = NO;
    static int tries = 0;
    if (done) return;
    if (!objc_getClass("MIInstallerClient")) {
        dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
    }
    if (!objc_getClass("MIInstallerClient")) {
        if (tries++ >= 120) { NSLog(@"[CrossFamilySpoof] MIInstallerClient never appeared"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ CFSInitCapabilityCheck(); });
        return;
    }
    done = YES;
    if (![objc_getClass("MIInstallerClient") instancesRespondToSelector:
            NSSelectorFromString(@"checkCapabilities:withOptions:completion:")]) {
        NSLog(@"[CrossFamilySpoof] %@: no -[MIInstallerClient checkCapabilities:withOptions:completion:] on this iOS",
              [[NSProcessInfo processInfo] processName]);
        return;
    }
    %init(CapabilityCheck);
    NSLog(@"[CrossFamilySpoof] %@: hooked MIInstallerClient checkCapabilities", [[NSProcessInfo processInfo] processName]);
}

static void CFSStartStoreDaemon(void) {
    gStoreBuyOnly = YES;
    CFSLoadStoreDaemonPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, CFSStoreDaemonReload,
                                    CFSTR("com.soulrune.crossfamilyinstall/store/reload"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFSInitStoreRequests();
    CFSInitCapabilityCheck();
}

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

%ctor {
    @autoreleasepool {
        // The App Store's purchase daemon
        if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"appstored"]) {
            CFSStartStoreDaemon();
            return;
        }

        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;

        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:CFSAppliedPath()];
        if (![prefs[@"Enabled"] boolValue]) return;                                    // master off
        if (![prefs[[@"enabled-" stringByAppendingString:bid]] boolValue]) return;    // not this app

        NSString *(^str)(NSString *) = ^NSString *(NSString *suffix) {
            id v = prefs[[NSString stringWithFormat:@"%@-%@", bid, suffix]];
            return [v isKindOfClass:[NSString class]]
                ? [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                : nil;
        };
        NSString *model  = str(@"Model");
        NSString *family = str(@"Family");
        NSString *os     = str(@"OSVersion");
        NSString *cpu    = str(@"CPU");
        NSString *memory = str(@"Memory");      // MB
        NSString *cores  = str(@"CPUCores");
        NSString *gpu    = str(@"GPU");
        NSString *vram   = str(@"GPUMemory");   // MB

        // Whole numbers in a sane range; anything else is ignored
        uint64_t (^number)(NSString *, uint64_t, uint64_t) = ^uint64_t(NSString *s, uint64_t min, uint64_t max) {
            if (!CFSMatches(s, @"^[0-9]{1,7}$")) return 0;
            uint64_t v = (uint64_t)s.longLongValue;
            return v >= min && v <= max ? v : 0;
        };
        if (memory.length) {
            uint64_t mb = number(memory, 256, 1048576);
            if (mb) { gMemoryBytes = mb * 1024 * 1024; gHasMemory = YES; }
            else NSLog(@"[CrossFamilySpoof] %@: ignoring invalid memory \"%@\"", bid, memory);
        }
        if (cores.length) {
            uint64_t n = number(cores, 1, 64);
            if (n) { gCores = (uint32_t)n; gHasCores = YES; }
            else NSLog(@"[CrossFamilySpoof] %@: ignoring invalid CPU core count \"%@\"", bid, cores);
        }
        if (cpu.length) {
            if (cpu.length < sizeof(gCPU) && CFSMatches(cpu, @"^[ -~]+$")) {
                strlcpy(gCPU, cpu.UTF8String, sizeof(gCPU));
                gHasCPU = YES;
            } else {
                NSLog(@"[CrossFamilySpoof] %@: ignoring invalid CPU name \"%@\"", bid, cpu);
            }
        }
        if (gpu.length) {
            if (gpu.length <= 63 && CFSMatches(gpu, @"^[ -~]+$")) gGPUName = [gpu copy];
            else NSLog(@"[CrossFamilySpoof] %@: ignoring invalid GPU name \"%@\"", bid, gpu);
        }
        if (vram.length) {
            uint64_t mb = number(vram, 64, 1048576);
            if (mb) { gGPUMemoryBytes = mb * 1024 * 1024; gHasGPUMemory = YES; }
            else NSLog(@"[CrossFamilySpoof] %@: ignoring invalid GPU memory \"%@\"", bid, vram);
        }

        if (model.length) {
            if (CFSValidModel(model)) {
                strlcpy(gModel, model.UTF8String, sizeof(gModel));
                gHasModel = YES;
            } else {
                NSLog(@"[CrossFamilySpoof] %@: ignoring invalid model \"%@\"", bid, model);
            }
        }
        if ([family isEqualToString:@"ipad"])   { gIdiom = UIUserInterfaceIdiomPad;   gHasFamily = YES; }
        if ([family isEqualToString:@"iphone"]) { gIdiom = UIUserInterfaceIdiomPhone; gHasFamily = YES; }
        BOOL isStore = [bid isEqualToString:@"com.apple.AppStore"] ||
                       [bid isEqualToString:@"com.apple.ios.StoreKitUIService"];
        if (os.length) {
            if (CFSParseVersion(os, &gOS)) {
                gOSString = [os copy];
                strlcpy(gOSC, os.UTF8String, sizeof(gOSC));
                gHasOS = YES;
                // The store's sign-in token is tied to the real iOS: a lower one
                // gets 403s and endless password prompts. Newer is fine.
                if (isStore && CFSCompareVersions(gOS, [[NSProcessInfo processInfo] operatingSystemVersion]) == NSOrderedAscending) {
                    NSLog(@"[CrossFamilySpoof] %@: iOS %@ is lower than the real one - Apple's store will refuse "
                          @"the sign-in (password prompts, BadPasswordToken)", bid, os);
                }
            } else {
                NSLog(@"[CrossFamilySpoof] %@: ignoring invalid iOS version \"%@\"", bid, os);
            }
        }

        // UIDevice.model: from the family if set, else from the model
        if (gHasFamily) gDeviceName = gIdiom == UIUserInterfaceIdiomPad ? @"iPad" : @"iPhone";
        else if (gHasModel) gDeviceName = CFSDeviceNameForModel(model);

        BOOL hasHardware = gHasCPU || gHasMemory || gHasCores || gGPUName || gHasGPUMemory;
        if (!gHasModel && !gHasFamily && !gHasOS && !hasHardware) {
            NSLog(@"[CrossFamilySpoof] %@: enabled but nothing to spoof", bid);
            return;
        }

        if (gHasModel || gHasOS || gHasCPU || gHasMemory || gHasCores) {
            MSHookFunction((void *)sysctlbyname, (void *)hook_sysctlbyname, (void **)&orig_sysctlbyname);
        }
        if (gHasModel || gHasMemory || gHasCores) {
            MSHookFunction((void *)sysctl, (void *)hook_sysctl, (void **)&orig_sysctl);
        }
        if (gHasModel) {
            MSHookFunction((void *)uname,  (void *)hook_uname,  (void **)&orig_uname);
        }
        if (gHasMemory || gHasCores) {
            MSHookFunction((void *)host_info, (void *)hook_host_info, (void **)&orig_host_info);
        }
        if ((gGPUName || gHasGPUMemory) && !CFSHookMetal()) {
            NSLog(@"[CrossFamilySpoof] %@: Metal not found, GPU values not applied", bid);
        }
        if (gDeviceName) %init(DeviceName);
        if (gHasFamily)  %init(Family);
        if (gHasOS)      %init(OSVersion);
        if (gHasMemory)  %init(Memory);
        if (gHasCores)   %init(Cores);

        // The App Store's own requests carry the device too
        if (isStore) {
            NSDictionary *values = CFSStoreValues(gHasOS ? gOSString : nil, gHasModel ? model : nil);
            if (values) {
                CFSSetStoreUA(values);
                CFSInitStoreRequests();
                CFSInitMobileGestalt();
            }
        }

        NSLog(@"[CrossFamilySpoof] %@: model=%s family=%@ os=%@ deviceName=%@", bid,
              gHasModel ? gModel : "(real)",
              gHasFamily ? family : @"(real)",
              gHasOS ? gOSString : @"(real)",
              gDeviceName ?: @"(real)");
        if (hasHardware) {
            NSLog(@"[CrossFamilySpoof] %@: cpu=%s cores=%@ memory=%@ gpu=%@ gpuMemory=%@", bid,
                  gHasCPU ? gCPU : "(real)",
                  gHasCores ? [NSString stringWithFormat:@"%u", gCores] : @"(real)",
                  gHasMemory ? [NSString stringWithFormat:@"%lluMB", gMemoryBytes >> 20] : @"(real)",
                  gGPUName ?: @"(real)",
                  gHasGPUMemory ? [NSString stringWithFormat:@"%lluMB", gGPUMemoryBytes >> 20] : @"(real)");
        }
    }
}
